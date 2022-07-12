#!/bin/bash
set -exuo pipefail

BASE_DIR=$(dirname $0)
source ${BASE_DIR}/constants.sh

# Create user and group for PingFederate
groupadd ${PF_GROUP}
adduser -g ${PF_GROUP} ${PF_USER}

cd /tmp

# Install PingFederate
mkdir ${PF_DIR}
mkdir "${PF_DIR}/logs"

curl https://michaelhuang-test.s3.ap-southeast-2.amazonaws.com/pingfederate-${PingFedVersion}.zip -o /data/pingfederate-${PingFedVersion}.zip
unzip /data/pingfederate-${PingFedVersion}.zip -d ${PF_DIR}
export PF_HOME="${PF_DIR}/pingfederate-${PingFedVersion}/pingfederate"
# Hardcode a temporary PingFederate license for demo purposes. (Expiry date: 20 July 2022)
curl https://michaelhuang-test.s3.ap-southeast-2.amazonaws.com/pingfederate-10.3-dev.lic -o ${PF_HOME}/server/default/conf/pingfederate.lic
curl https://jdbc.postgresql.org/download/postgresql-42.2.5.jar -o ${PF_HOME}/server/default/lib/postgresql-42.2.5.jar

# Setup default configs
# unzip "${PingfedConfigLocalPath}" -d /data/
# copy the default nginx config
cp -f /data/openid-configuration.template.json ${PF_HOME}/server/default/conf/template/openid-configuration.template.json
cp -f /data/log4j2.xml ${PF_HOME}/server/default/conf/log4j2.xml
rm /data/log4j2.xml
rm /data/openid-configuration.template.json

# Setup PingFederate service
str="
pf.log.dir=${PF_DIR}/logs"

sed -i "/http.nonProxyHosts/r /dev/stdin" ${PF_HOME}/bin/run.properties <<< "$str"
amazon-linux-extras install -y java-openjdk11
export PF_JAVA_HOME="$(dirname $(dirname $(readlink -f $(which java))))"
envsubst < ${PF_HOME}/sbin/linux/pingfederate.service > /tmp/pingfederate.service
cp /tmp/pingfederate.service ${PF_HOME}/sbin/linux/pingfederate.service
#set up pf.secondary.https.port
sed -i "s/pf.secondary.https.port=-1/pf.secondary.https.port=9032/g" ${PF_HOME}/bin/run.properties
#mitigate log4j2 CVE-2021-44228
echo -e "\n#log4j2 mitigation" >> ${PF_HOME}/bin/run.properties
echo "log4j2.formatMsgNoLookups=true" >> ${PF_HOME}/bin/run.properties
# TTL to enforce DNS lookup refresh in PingFed datastore connection after PD B/G deployment
echo "#TTL to enforce DNS lookup refresh in PingFed datastore connection after PD B/G deployment" >> ${PF_HOME}/bin/run.properties
echo "networkaddress.cache.ttl=60" >> ${PF_HOME}/bin/run.properties
chown -R ${PF_USER}:${PF_GROUP} ${PF_DIR}
chmod -R 750 ${PF_DIR}
cp ${PF_HOME}/sbin/linux/pingfederate.service /etc/systemd/system/
chmod 664 /etc/systemd/system/pingfederate.service
systemctl daemon-reload
systemctl enable pingfederate