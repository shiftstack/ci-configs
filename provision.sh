#!/bin/bash
# -*- coding: utf-8 -*-
# Copyright 2021 Red Hat, Inc.
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#
#
# This script will provision an OpenStack cluster against an OpenStack cloud
# (defaults to our CI account on VEXXHOST)
# Usage:
# ./provision <config-name>
# The config has to exist in ./configs
#

set -eu
DEBUG=${DEBUG:-}
if [ -n "$DEBUG" ]; then
    set -x
fi

##########################
# Github Actions Secrets #
##########################
# IS_CI must be set to True when the script is run by Github Actions so
# we will get secrets from Github Action secrets instead of decrypting
# the secret directory of this repository.
IS_CI=${IS_CI:-}
VEXXHOST_ENDPOINT=${VEXXHOST_ENDPOINT:-}
VEXXHOST_SHIFTSTACK_BM_CI_PASSWORD=${VEXXHOST_SHIFTSTACK_BM_CI_PASSWORD:-}
VEXXHOST_SHIFTSTACK_BM_CI_SSH_PRIVATE_KEY=${VEXXHOST_SHIFTSTACK_BM_CI_SSH_PRIVATE_KEY:-}
OPENSHIFT_TENANT_PASSWORD=${OPENSHIFT_TENANT_PASSWORD:-}
SSL_CA_CERT=${SSL_CA_CERT:-}
SSL_CA_KEY=${SSL_CA_KEY:-}
REDHAT_REGISTRY_CREDENTIALS=${REDHAT_REGISTRY_CREDENTIALS:-}
REDHAT_RHSM_ORG=${REDHAT_RHSM_ORG:-}
REDHAT_RHSM_ACTIVATION_KEY=${REDHAT_RHSM_ACTIVATION_KEY:-}

######################
# PLATFORM VARIABLES #
######################
# Note that defaults are set to use our VEXXHOST cloud
# but they can be overriden to deploy somewhere else (e.g. PSI)
IMAGE_NAME=${IMAGE_NAME:-rhel-84-shiftstack-ci}
FLAVOR_NAME=${FLAVOR_NAME:-b1-standard-96}
NETWORK_NAME=${NETWORK_NAME:-public}
KEYPAIR_NAME=${KEYPAIR_NAME:-shiftstack-ci}
SERVER_USER=${SERVER_USER:-cloud-user}
OVERRIDE_OS_CLOUD=${OVERRIDE_OS_CLOUD:-}

######################
# VEXXHOST VARIABLES #
######################
export OS_CLOUD=${OVERRIDE_OS_CLOUD:-shiftstack-bm}
VEXXHOST_USERNAME=${VEXXHOST_USERNAME:-shiftstack-bm-ci}
VEXXHOST_PROJECT_NAME=${VEXXHOST_PROJECT_NAME:-shiftstack-bm}

SCRIPT_NAME=`basename "$0"`
[[ "$#" -ne 1 ]] && echo "Missing argument, usage: ./$SCRIPT_NAME <config-name>" && exit 1
ROOT_DIR=$PWD
WORK_DIR=${WORK_DIR:-$(mktemp -d -t shiftstack-ci-XXXXXXXXXX)}
CLUSTER_NAME=$1
SERVER_CREATE_CMD="openstack server create --wait --key-name $KEYPAIR_NAME --network $NETWORK_NAME --flavor $FLAVOR_NAME --image $IMAGE_NAME $CLUSTER_NAME"
SERVER_DELETE_CMD="openstack server delete --wait $CLUSTER_NAME"

# Function to run a command with a retry.
# You can specify the number of total retries in $1
# and the sleep time (in seconds) between retries.
function retry {
    local retries=$1
    local time=$2
    shift 2

    local count=0
    until "$@"; do
      exit=$?
      count=$(($count + 1))
      if [ $count -lt $retries ]; then
        sleep $time
      else
        return $exit
      fi
    done
    return 0
}

function create_server {
    if openstack server show $CLUSTER_NAME &>/dev/null; then
        echo "DEBUG: Cluster $CLUSTER_NAME was already running, removing it..."
        eval $SERVER_DELETE_CMD
    fi
    echo "DEBUG: Creating server for $CLUSTER_NAME..."
    set +e
    SERVER_CREATE=$(eval $SERVER_CREATE_CMD)
    RC=$?
    if [[ $SERVER_CREATE == *"Quota exceeded"* ]]; then
        echo "ERROR: Not enough quotas available to create $CLUSTER_NAME"
        exit 1
    fi
    # If the server goes into ERROR status immediately, openstackclient returns 0
    # so we need to force RC to 1 so we can retry later.
    SERVER_STATUS=$(openstack server show -c status -f shell $CLUSTER_NAME)
    if [[ $SERVER_STATUS == *"ERROR"* ]]; then
        RC=1
    fi
    set -e
    return $RC
}

if [ ! -f "$ROOT_DIR/configs/$CLUSTER_NAME.yaml" ]; then
    echo "ERROR: No config was found for $CLUSTER_NAME in $ROOT_DIR/configs"
    exit 1
fi

# Sanity check for CI jobs and locally
if [ -n "IS_CI" ]; then
    for i in REDHAT_REGISTRY_CREDENTIALS SSL_CA_CERT SSL_CA_KEY VEXXHOST_SHIFTSTACK_BM_CI_PASSWORD VEXXHOST_SHIFTSTACK_BM_CI_SSH_PRIVATE_KEY VEXXHOST_ENDPOINT OPENSHIFT_TENANT_PASSWORD; do
       if [ -z "$i" ]; then
           echo "ERROR:$ $i is not set and is required when this script runs in CI"
           exit 1
       fi
    done
else
   if ! grep -q clouds $ROOT_DIR/secrets/clouds.yaml; then
      echo "ERROR: ./secrets directory is not decrypted, please check the README"
      exit 1
   fi
fi

if [[ $CLUSTER_NAME == *"az"* ]]; then
    if [ -z "$CENTRAL_NAME" ]; then
        echo "CENTRAL_NAME has to be defined when deploying additional nodes in a specific AZ"
        exit 1
    fi
fi

# Initialize secrets
# All variables are defined in Github Actions secrets
if [ -n "$VEXXHOST_SHIFTSTACK_BM_CI_PASSWORD" ]; then
    cat << EOF > $WORK_DIR/clouds.yaml
clouds:
  $OS_CLOUD:
    auth:
      auth_url: "$VEXXHOST_ENDPOINT"
      username: "$VEXXHOST_USERNAME"
      password: "$VEXXHOST_SHIFTSTACK_BM_CI_PASSWORD"
      project_name: "$VEXXHOST_PROJECT_NAME"
    identity_api_version: 3
EOF

else
  # When OVERRIDE_OS_CLOUD is set, we want to use our own clouds.yaml
  if [ -z "$OVERRIDE_OS_CLOUD" ]; then
    cp $ROOT_DIR/secrets/clouds.yaml $WORK_DIR/clouds.yaml
  fi
fi

if [ -n "$VEXXHOST_SHIFTSTACK_BM_CI_SSH_PRIVATE_KEY" ]; then
    cat << EOF > $WORK_DIR/ssh-private.key
-----BEGIN RSA PRIVATE KEY-----
${VEXXHOST_SHIFTSTACK_BM_CI_SSH_PRIVATE_KEY}
-----END RSA PRIVATE KEY-----
EOF

else
    cp $ROOT_DIR/secrets/vexxhost-ssh-private.key $WORK_DIR/ssh-private.key
fi
chmod 400 $WORK_DIR/ssh-private.key

if [ -n "$SSL_CA_CERT" ]; then
    cat << EOF > $WORK_DIR/shiftstack-ci-ca.crt
${SSL_CA_CERT}
EOF

else
    cp $ROOT_DIR/secrets/ssl/shiftstack-ci-ca.crt $WORK_DIR/shiftstack-ci-ca.crt
fi
if [ -n "$SSL_CA_KEY" ]; then
    cat << EOF > $WORK_DIR/shiftstack-ci-ca.key
${SSL_CA_KEY}
EOF

else
    cp $ROOT_DIR/secrets/ssl/shiftstack-ci-ca.key $WORK_DIR/shiftstack-ci-ca.key
fi
chmod 400 $WORK_DIR/shiftstack-ci-ca.crt $WORK_DIR/shiftstack-ci-ca.key

# OPENSHIFT_TENANT_PASSWORD is defined in Github Actions secrets
if [ -z "$OPENSHIFT_TENANT_PASSWORD" ]; then
    source $ROOT_DIR/secrets/passwords.rc
fi

# REDHAT_REGISTRY_CREDENTIALS is defined in Github Actions secrets
if [ -z "$REDHAT_REGISTRY_CREDENTIALS" ]; then
    source $ROOT_DIR/secrets/redhat-credentials.rc
fi

if ! [[ -d "$WORK_DIR/dev-install" ]]; then
	  git clone -q https://github.com/shiftstack/dev-install $WORK_DIR/dev-install
fi

pushd $WORK_DIR &>/dev/null

if ! openstack keypair show $KEYPAIR_NAME &>/dev/null; then
    echo "ERROR: No keypair was found with $KEYPAIR_NAME name"
    exit 1
fi

# Here we'll have to deal with the fact that a node being removed from Nova
# will have its disk erased by Ironic, and takes a bit of time because it can
# be reprovisioned. Which means that if didn't have a node available before the
# cluster removal, there is a big chance that the redeploy will fail since Nova
# Resources periodic tracker needs a bit of time to catch up on the node status.
# Try to create the server during 15 min max:
if ! retry 30 30 create_server; then
    echo "ERROR: Server for $CLUSTER_NAME was not able to be created"
    exit 1
fi
PUBLIC_IP=$(openstack server show $CLUSTER_NAME -c addresses -f json | grep -Pom 1 '[0-9.]{7,15}')
SSH_ARGS="-o ConnectTimeout=10 -o "StrictHostKeyChecking=no" -i $WORK_DIR/ssh-private.key"
SSH_CMD="ssh $SSH_ARGS $SERVER_USER@$PUBLIC_IP"
SCP_CMD="scp -r $SSH_ARGS"
# When a node is deployed with Ironic, OpenSSH is open for a few seconds then the node becomes unreachable until the
# OS starts properly, so let's run SSH with a timeout of 10 seconds, sleep 10 seconds between retries and repeat
# 90 times, which should give a total timeout of 30 min.
echo "DEBUG: Trying to SSH $CLUSTER_NAME via $SERVER_USER@$PUBLIC_IP"
if ! retry 90 10 $SSH_CMD uname -a; then
    echo "ERROR: Server for $CLUSTER_NAME ($PUBLIC_IP) was not reachable..."
    exit 1
fi
echo "DEBUG: Server was successfuly deployed and its IP is $PUBLIC_IP"

cd dev-install
export ansible_args="--private-key=$WORK_DIR/ssh-private.key"
echo "DEBUG: Configure dev-install to deploy OpenStack on $CLUSTER_NAME"
make config host=$PUBLIC_IP user=$SERVER_USER &>/dev/null
cat $ROOT_DIR/configs/$CLUSTER_NAME.yaml >> local-overrides.yaml
INDENTED_SSL_CA_CERT=$(cat $WORK_DIR/shiftstack-ci-ca.crt | sed 's/^/  /')
INDENTED_SSL_CA_KEY=$(cat $WORK_DIR/shiftstack-ci-ca.key | sed 's/^/  /')
cat << EOF >> local-overrides.yaml
openshift_password: "${OPENSHIFT_TENANT_PASSWORD}"
ssl_enabled: true
ssl_ca_cert: |
$INDENTED_SSL_CA_CERT
ssl_ca_key: |
$INDENTED_SSL_CA_KEY
authorized_keys:
  - https://github.com/EmilienM.keys
  - https://github.com/MaysaMacedo.keys
  - https://github.com/mandre.keys
  - https://github.com/mdbooth.keys
  - https://github.com/pierreprinetti.keys
  - https://github.com/stephenfin.keys
create_rhcos_image: false
hostname: $CLUSTER_NAME
local_cloudname: $CLUSTER_NAME
EOF

# If the host is RHEL we'll need credentials to pull images
# from Red Hat Container Image Registry
if $SSH_CMD grep -q "Red\ Hat" /etc/redhat-release; then
    cat << EOF >> local-overrides.yaml
rhsm_ephemeral: false
redhat_registry_credentials: "${REDHAT_REGISTRY_CREDENTIALS}"
rhsm_org_id: "${REDHAT_RHSM_ORG}"
rhsm_activation_key: "${REDHAT_RHSM_ACTIVATION_KEY}"
EOF
fi

if [[ $CLUSTER_NAME == *"az"* ]]; then
    echo "DEBUG: AZ node detected, copying central config into /opt/exported-data"
    # TODO(Emilien): We need to make it discoverable and not hard-code it but for our current CI this is fine.
    $SCP_CMD $ROOT_DIR/secrets/osp-ci/exported-data/$CENTRAL_NAME $SERVER_USER@$PUBLIC_IP:/tmp/exported-data
    $SSH_CMD "bash -c 'sudo mv /tmp/exported-data /opt'"
fi

# Workaround, it doesn't seem to work fine for now when running
# the Ansible task that does it in dev-install from Github CI
echo "DEBUG: Upgrading the server to CentOS Stream..."
$SSH_CMD "if test -f /etc/centos-release; then rpm --query centos-stream-release || bash -c 'sudo dnf -y swap centos-linux-repos centos-stream-repos && sudo dnf -y distro-sync'; fi"
echo "DEBUG: Run dev-install to deploy OpenStack on $CLUSTER_NAME..."
MAKE_TARGETS="local_requirements prepare_host network install_stack"
if [[ $CLUSTER_NAME != *"az"* ]]; then
    MAKE_TARGETS="${MAKE_TARGETS} prepare_stack local_os_client"
fi
make $MAKE_TARGETS

if [[ $CLUSTER_NAME == *"nfv"* ]] || [[ $CLUSTER_NAME == *"hwoffload"* ]]; then
    echo "DEBUG: NFV node detected, copying squid config"
    $SCP_CMD $ROOT_DIR/secrets/squid stack@$PUBLIC_IP: &>/dev/null
fi
    
make post_install

if [[ $CLUSTER_NAME == *"central"* ]]; then
    echo "DEBUG: DCN central node detected, collecting central config into secrets"
    mkdir -p $ROOT_DIR/secrets/osp-ci/exported-data/
    rm -rf $ROOT_DIR/secrets/osp-ci/exported-data/$CLUSTER_NAME
    $SCP_CMD stack@$PUBLIC_IP:/home/stack/exported-data $ROOT_DIR/secrets/osp-ci/exported-data/$CLUSTER_NAME &>/dev/null
fi

echo "DEBUG: Cluster $CLUSTER_NAME was successfuly deployed !"
cd ..

if [[ $CLUSTER_NAME == *"az"* ]]; then
    echo "DEBUG: AZ node detected, you'll need to update OVS tunnels on central node"
    echo "ssh stack@<node>"
    echo "<your favorite text editor> dev-install_net_config.yaml and add the block for OVS tunnels"
    echo "sudo os-net-config -c dev-install_net_config.yaml"
fi

if [ -n "$IS_CI" ]; then
    echo "DEBUG: Destruction of $CLUSTER_NAME..."
    eval $SERVER_DELETE_CMD
fi
