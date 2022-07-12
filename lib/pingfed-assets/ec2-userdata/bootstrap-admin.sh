#!/bin/bash
set -exo pipefail
exec 1> >(tee /dev/console)
exec 2>&1

export AWS_DEFAULT_REGION=$1
export DeployID=$2
export RuntimeBucket=$3
export RdsEndpoint=$4

BASE_DIR=$(dirname $0)
source ${BASE_DIR}/constants.sh

wait_for_pingfed_admin_ready() {
    check_if_admin_healthy() {
        local output=$(curl -k -s -S --connect-timeout 5 --max-time 10 \
            https://localhost:9999/pf-admin-api/v1/version \
            -H "X-XSRF-Header: PingFederate" -H "Authorization: Basic ${pingfed_auth_string}" \
            2> /dev/null | jq -r ".version")

        if [ -n "${output}" ]; then
            return 0
        else
            return 1
        fi
    }

    RETRY_TIMEOUT_SEC=120
    RETRY_INTERVAL=3
    RETRY_ELAPSED=0
    until check_if_admin_healthy
    do
        if [ ${RETRY_ELAPSED} -eq ${RETRY_TIMEOUT_SEC} ]; then
            echo "[ERROR] PingFed admin service is not ready in at least ${RETRY_TIMEOUT_SEC} seconds. Please check 'server.log' for details."
            exit 1
        fi

        sleep ${RETRY_INTERVAL}
        RETRY_ELAPSED=$(( ${RETRY_ELAPSED}+${RETRY_INTERVAL} ))
    done
}

wait_for_postgresql_ready() {
  # make sure postgresql server is ready to accept connections
  RETRY_TIMEOUT_SEC=60
  RETRY_INTERVAL=1
  RETRY_ELAPSED=0
  until pg_isready -h ${RdsEndpoint} 2>&1
  do
      if [ ${RETRY_ELAPSED} -eq ${RETRY_TIMEOUT_SEC} ]; then
          echo "[ERROR] cannot connect postgresql server in at least ${RETRY_TIMEOUT_SEC} seconds."
          exit 1
      fi

      sleep ${RETRY_INTERVAL}
      RETRY_ELAPSED=$(( ${RETRY_ELAPSED}+${RETRY_INTERVAL} ))
  done
}

create_datastore_post_body() {
    # Hardcode the RDS username and password just for demo purposes.
    # Use something similar to the following when developing in your actual environments.
    #
    # local rds_username=$(aws secretsmanager get-secret-value \
    #     --secret-id ${RdsCredentialName} --query SecretString --output text --region ${AWS_DEFAULT_REGION} | jq -r '.username')
    # local rds_password=$(aws secretsmanager get-secret-value \
    #     --secret-id ${RdsCredentialName} --query SecretString --output text --region ${AWS_DEFAULT_REGION} | jq -r '.password')
    local rds_username="postgres"
    local rds_password="rdspassword"

    cat <<EOF
        {
            "type": "JDBC",
            "id": "JDBC-${datastore_name}",
            "maskAttributeValues": false,
            "connectionUrl": "jdbc:postgresql://${RdsEndpoint}/pingfed",
            "driverClass": "org.postgresql.Driver",
            "userName": "${rds_username}",
            "password": "${rds_password}",
            "validateConnectionSql": "select 1",
            "allowMultiValueAttributes": true,
            "name": "${datastore_name}",
            "connectionUrlTags": [
                {
                    "connectionUrl": "jdbc:postgresql://${RdsEndpoint}/pingfed",
                    "defaultSource": true
                }
            ],
            "minPoolSize": 10,
            "maxPoolSize": 50,
            "blockingTimeout": 5000,
            "idleTimeout": 5
        }
EOF
}

static_settings() {
    # The following config changes must apply everytime when a new instance starts.
    # (i.e. no matter it's deploying a new cluster, auto-scaling event, or recovery by ASG/ELB health check)

    # Setup PingFed cluster basics
    yum install -y xmlstarlet nc

    sed -i "s/pf.cluster.node.index=/pf.cluster.node.index=100/g" ${PF_HOME}/bin/run.properties
    sed -i "s/pf.operational.mode=STANDALONE/pf.operational.mode=CLUSTERED_CONSOLE/g" ${PF_HOME}/bin/run.properties
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
    wait_for_pingfed_admin_ready
}

cluster_encryption_setup() {
    local is_recovery="$1"
    sed -i "s/pf.cluster.encrypt=false/pf.cluster.encrypt=true/g" ${PF_HOME}/bin/run.properties
    sed -i "s/pf.cluster.encryption.keysize=128/pf.cluster.encryption.keysize=256/g" ${PF_HOME}/bin/run.properties
    if [ "x${is_recovery}" = "xrecovery"  ]; then
        pfcluster_auth_passwd_obf=$(cat /tmp/startup/${DeployID} | grep OBF)
        sed -i "s/pf.cluster.auth.pwd=.*/pf.cluster.auth.pwd=${pfcluster_auth_passwd_obf}/g" ${PF_HOME}/bin/run.properties
    else
        #pfcluster_auth_passwd=$(aws secretsmanager get-secret-value --secret-id /idp/pingfed/cluster-password --query SecretString --output text --region ap-southeast-2 | jq -r '.password')
        pfcluster_auth_passwd="mhtest"
        pfcluster_auth_passwd_obf=$(${PF_HOME}/bin/obfuscate.sh "${pfcluster_auth_passwd}" | grep OBF)
        sed -i "s/pf.cluster.auth.pwd=/pf.cluster.auth.pwd=${pfcluster_auth_passwd_obf}/g" ${PF_HOME}/bin/run.properties
        echo "${pfcluster_auth_passwd_obf}" > /tmp/${DeployID}
    fi
}

runtime_settings() {
    # The following config changes will only apply once, when deploying the cluster.
    # Then these changes will be packed as a config archive, and send to a S3 bucket.
    # Later in a auto-scaling event, or recovery by ASG/ELB health check, the new instance
    # will only pull that config archive and set itself up.

    cp /data/com.pingidentity.page.Login.xml ${PF_HOME}/server/default/data/config-store/com.pingidentity.page.Login.xml
    cp /data/pingfederate-admin-user.xml ${PF_HOME}/server/default/data/pingfederate-admin-user.xml
    rm /data/com.pingidentity.page.Login.xml
    rm /data/pingfederate-admin-user.xml
    chown -R ${PF_USER}:${PF_GROUP} ${PF_HOME}
    systemctl restart pingfederate
    wait_for_pingfed_admin_ready

    # Install postgresql packages and setup the datastore for PingFed
    amazon-linux-extras install -y postgresql10

    wait_for_postgresql_ready

    datastore_name="Datastore-AuroraPostgreSQL"
    current_datastores=$(curl --insecure -X GET -H "X-XSRF-HEADER: pingfederate" \
        -H "Authorization: Basic ${pingfed_auth_string}" \
        "https://localhost:9999/pf-admin-api/v1/dataStores")
    if [ -z "$(echo ${current_datastores} | grep ${datastore_name})" ]; then
        http_code=$(curl --insecure -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "X-XSRF-HEADER: pingfederate" \
            -H "Authorization: Basic ${pingfed_auth_string}" \
            "https://localhost:9999/pf-admin-api/v1/dataStores" \
            --data "$(create_datastore_post_body)")

        if [[ "${http_code}" != "2"* ]]; then
            echo "[ERROR] Fail to create a new datastore!"
            exit 1
        fi
    else
        echo "[Info] There already exists an expected datastore."
    fi
}

insert_init_complete_prop() {
    post_body() {
        cat <<EOF
        {
            "items": [
                {
                "name": "ServiceInitCompleted",
                "description": "",
                "multiValued": "false"
                }
            ]
        }
EOF
    }

    local http_code=$(curl -k -X PUT -s -S -o /tmp/curl-response -w "%{http_code}" \
        https://localhost:9999/pf-admin-api/v1/extendedProperties \
        -H "X-XSRF-Header: PingFederate" -H "Authorization: Basic ${pingfed_auth_string}" \
        -H "Content-Type: application/json" --data "$(post_body)")

    if [ "${http_code}" != "200" ]; then
        echo "[ERROR] $(cat /tmp/curl-response)"
        exit 1
    fi
}

wait_for_init_to_complete() {
    check_if_init_complete() {
        local init_complete_prop_name=$(curl -k -X GET -s -S https://localhost:9999/pf-admin-api/v1/extendedProperties \
            -H "X-XSRF-Header: PingFederate" -H "Authorization: Basic ${pingfed_auth_string}" \
            | jq -r ".items[]? | select(.name == \"ServiceInitCompleted\") | .name")

        if [ -n "${init_complete_prop_name}" ]; then
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

PF_HOME="/opt/ping/pingfederate-${PingFedVersion}/pingfederate"

# Here we put a plaintext credential pair for demo purposes.
# Consider the following when developing in your actual environments.
#
#pingfed_username=$(aws secretsmanager get-secret-value \
#    --secret-id ${PingFedCredentialName} --query SecretString --output text --region ${AWS_DEFAULT_REGION} | jq -r '.username')
#pingfed_password=$(aws secretsmanager get-secret-value \
#    --secret-id ${PingFedCredentialName} --query SecretString --output text --region ${AWS_DEFAULT_REGION} | jq -r '.password')
#
pingfed_username="administrator"
pingfed_password="2Federate"

pingfed_auth_string=$(echo -n "${pingfed_username}:${pingfed_password}" | base64)

amazon-linux-extras install -y epel
yum install -y jq
static_settings

aws s3 sync s3://${RuntimeBucket}/runtime/PingFed-config-archive-${DeployID} /tmp/startup
if [ ! -f /tmp/startup/data.zip ]; then
    cluster_encryption_setup "non-recovery"
    runtime_settings
    insert_init_complete_prop

    curl --insecure -X GET -H "X-XSRF-HEADER: pingfederate" \
        -H "Authorization: Basic ${pingfed_auth_string}" \
        "https://localhost:9999/pf-admin-api/v1/configArchive/export" --output /tmp/startup/data.zip

    aws s3 cp /tmp/${DeployID} s3://${RuntimeBucket}/runtime/PingFed-config-archive-${DeployID}/${DeployID}
    aws s3 cp /tmp/startup/data.zip s3://${RuntimeBucket}/runtime/PingFed-config-archive-${DeployID}/data.zip
    rm -f /tmp/${DeployID}
else
    chown ${PF_USER}:${PF_GROUP} /tmp/startup/data.zip
    cp -rp /tmp/startup/data.zip ${PF_HOME}/server/default/data/drop-in-deployer/data.zip
    wait_for_init_to_complete

    cluster_encryption_setup "recovery"
    #xmlstarlet ed -L -u "module/service-point[@id='ClientManager' and @interface='org.sourceid.oauth20.domain.ClientManager']
    #    /invoke-factory/construct[@class='org.sourceid.oauth20.domain.ClientManagerXmlFileImpl']/@class" \
    #    -v "org.sourceid.oauth20.domain.ClientManagerLdapImpl" ${PF_HOME}/server/default/conf/META-INF/hivemodule.xml
    sleep 1
    systemctl restart pingfederate
    wait_for_pingfed_admin_ready
fi

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
asg_name=$(aws autoscaling describe-auto-scaling-groups --region ${AWS_DEFAULT_REGION} | \
    jq -r ".AutoScalingGroups[]? | select(.Instances[]?.InstanceId == \"${INSTANCE_ID}\") | .AutoScalingGroupName")
aws autoscaling complete-lifecycle-action --lifecycle-action-result CONTINUE --instance-id ${INSTANCE_ID} \
    --lifecycle-hook-name "service-init-hook" --auto-scaling-group-name "${asg_name}" --region ${AWS_DEFAULT_REGION} || \
    aws autoscaling complete-lifecycle-action --lifecycle-action-result ABANDON --instance-id ${INSTANCE_ID} \
    --lifecycle-hook-name "service-init-hook" --auto-scaling-group-name "${asg_name}" --region ${AWS_DEFAULT_REGION}