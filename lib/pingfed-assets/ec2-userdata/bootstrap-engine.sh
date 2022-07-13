#!/bin/bash
set -exo pipefail
exec 1> >(tee /dev/console)
exec 2>&1

export AWS_DEFAULT_REGION=$1
export DeployID=$2
export RuntimeBucket=$3

BASE_DIR=$(dirname $0)
source ${BASE_DIR}/constants.sh

wait_for_init_to_complete() {
    check_if_init_complete() {
        local init_complete_prop=$(grep "ServiceInitCompleted" ${PF_HOME}/server/default/data/oauth-client-settings.xml)

        if [ -n "${init_complete_prop}" ]; then
            return 0
        else
            return 1
        fi
    }

    RETRY_TIMEOUT_SEC=60
    RETRY_INTERVAL=3
    RETRY_ELAPSED=0
    until check_if_init_complete
    do
        if [ ${RETRY_ELAPSED} -eq ${RETRY_TIMEOUT_SEC} ]; then
            echo "[ERROR] PingFed didn't finish the initialization process"
            echo "        (maybe didn't apply the config archive (${PF_HOME}/server/default/data/drop-in-deployer/data.zip)"
            echo "        in at least ${RETRY_TIMEOUT_SEC} seconds."
            exit 1
        fi

        sleep ${RETRY_INTERVAL}
        RETRY_ELAPSED=$(( ${RETRY_ELAPSED}+${RETRY_INTERVAL} ))
    done
}

wait_for_pingfed_engine_ready() {
    check_if_engine_healthy() {
        local output=$(curl -k -s -S --connect-timeout 5 --max-time 10 \
            https://localhost:9031/pf/heartbeat.ping 2>/dev/null | grep "OK")

        if [ -n "${output}" ]; then
            return 0
        else
            return 1
        fi
    }

    RETRY_TIMEOUT_SEC=120
    RETRY_INTERVAL=3
    RETRY_ELAPSED=0
    until check_if_engine_healthy
    do
        if [ ${RETRY_ELAPSED} -eq ${RETRY_TIMEOUT_SEC} ]; then
            echo "[ERROR] PingFed engine service is not ready in at least ${RETRY_TIMEOUT_SEC} seconds. Please check 'server.log' for details."
            exit 1
        fi

        sleep ${RETRY_INTERVAL}
        RETRY_ELAPSED=$(( ${RETRY_ELAPSED}+${RETRY_INTERVAL} ))
    done
}

amazon-linux-extras install -y epel
yum install -y xmlstarlet nc jq
PF_HOME="/opt/ping/pingfederate-${PingFedVersion}/pingfederate"

cp /data/com.pingidentity.page.Login.xml ${PF_HOME}/server/default/data/config-store/com.pingidentity.page.Login.xml
cp /data/pingfederate-admin-user.xml ${PF_HOME}/server/default/data/pingfederate-admin-user.xml
rm /data/com.pingidentity.page.Login.xml
rm /data/pingfederate-admin-user.xml
chown -R ${PF_USER}:${PF_GROUP} ${PF_HOME}

# Setup AWS_PING dynamic discovery fo clustering
sed -i "s/pf.operational.mode=STANDALONE/pf.operational.mode=CLUSTERED_ENGINE/g" ${PF_HOME}/bin/run.properties
sed -i "s/<TCPPING/<\!-- &/g" ${PF_HOME}/server/default/conf/tcp.xml
sed -i "s/port_range=\"0\"\/>/ & -->/g" ${PF_HOME}/server/default/conf/tcp.xml
xmlstarlet ed -L -a "//config/TCP_NIO2" -t elem -n "com.pingidentity.aws.AWS_PING" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "port_number" -v "\${pf.cluster.bind.port}" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "port_range" -v "0" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "regions" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "tags" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "filters" -v "tag:PFClusterID=PFC-${DeployID}" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "access_key" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "secret_key" \
    -i "//config/com.pingidentity.aws.AWS_PING" -t attr -n "log_aws_error_messages" -v "true" ${PF_HOME}/server/default/conf/tcp.xml

systemctl restart pingfederate
wait_for_pingfed_engine_ready

trap "rm -rf /tmp/startup" INT TERM EXIT
# Wait until admin instance successfully initialised
aws s3 sync s3://${RuntimeBucket}/runtime/PingFed-config-archive-${DeployID} /tmp/startup

until [ -f /tmp/startup/data.zip ]; do
  sleep 2
  aws s3 sync s3://${RuntimeBucket}/runtime/PingFed-config-archive-${DeployID} /tmp/startup
done

chown ${PF_USER}:${PF_GROUP} /tmp/startup/data.zip
cp -rp /tmp/startup/data.zip ${PF_HOME}/server/default/data/drop-in-deployer/data.zip
wait_for_init_to_complete

# Set up Cluster Encryption
sed -i "s/pf.cluster.encrypt=false/pf.cluster.encrypt=true/g" ${PF_HOME}/bin/run.properties
sed -i "s/pf.cluster.encryption.keysize=128/pf.cluster.encryption.keysize=256/g" ${PF_HOME}/bin/run.properties
pfcluster_auth_passwd_obf=$(cat /tmp/startup/${DeployID} | grep OBF)
sed -i "s/pf.cluster.auth.pwd=/pf.cluster.auth.pwd=${pfcluster_auth_passwd_obf}/g" ${PF_HOME}/bin/run.properties

systemctl restart pingfederate
wait_for_pingfed_engine_ready
echo "PingFed Engine started successfully"

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
asg_name=$(aws autoscaling describe-auto-scaling-groups --region ${AWS_DEFAULT_REGION} | \
    jq -r ".AutoScalingGroups[]? | select(.Instances[]?.InstanceId == \"${INSTANCE_ID}\") | .AutoScalingGroupName")
aws autoscaling complete-lifecycle-action --lifecycle-action-result CONTINUE --instance-id ${INSTANCE_ID} \
    --lifecycle-hook-name "service-init-hook" --auto-scaling-group-name "${asg_name}" --region ${AWS_DEFAULT_REGION} || \
    aws autoscaling complete-lifecycle-action --lifecycle-action-result ABANDON --instance-id ${INSTANCE_ID} \
    --lifecycle-hook-name "service-init-hook" --auto-scaling-group-name "${asg_name}" --region ${AWS_DEFAULT_REGION}