#!/bin/bash
set -exuo pipefail

RuntimeBucket=$1
export PingfedConfigLocalPath=$2
export OperationalMode=$3
export AWS_DEFAULT_REGION=$4
export DeployID=$5
export RdsEndpoint=$6

BASE_DIR=$(dirname $0)

unzip "${PingfedConfigLocalPath}" -d /data/
chmod u+x ${BASE_DIR}/pingfed-install.sh
${BASE_DIR}/pingfed-install.sh
chmod u+x ${BASE_DIR}/bootstrap-${OperationalMode}.sh
${BASE_DIR}/bootstrap-${OperationalMode}.sh ${AWS_DEFAULT_REGION} ${DeployID} ${RuntimeBucket} ${RdsEndpoint}