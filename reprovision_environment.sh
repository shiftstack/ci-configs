#!/bin/bash
set -eu

SCRIPT_NAME=`basename "$0"`
[[ "$#" -ne 1 ]] && echo "Missing argument, usage: ./$SCRIPT_NAME <config-name>" && exit 1

# IS_CI must be set to True when the script is run by Github Actions so
# we will get secrets from Github Action secrets instead of decrypting
# the secret directory of this repository.
IS_CI=${IS_CI:-}
CLOUDS_YAML=${CLOUDS_YAML:-}
OPENSHIFT_TENANT_PASSWORD=${OPENSHIFT_TENANT_PASSWORD:-}
ROOT_DIR=$PWD
WORK_DIR=$(mktemp -d -t shiftstack-ci-XXXXXXXXXX)
CLUSTER_NAME=$1
export OS_CLOUD=shiftstack-bm

if [ ! -f "$ROOT_DIR/configs/$CLUSTER_NAME.yaml" ]; then
    echo "ERROR: No config was found for $CLUSTER_NAME in $ROOT_DIR/configs"
    exit 1
fi
# Initialize secrets
# CLOUDS_YAML is defined in Github Actions secrets
if [ -n "$CLOUDS_YAML" ]; then
    #TODO(Verify that this can't be leaked by something like `cat $WORK_DIR/clouds.yaml`
    echo $CLOUDS_YAML > $WORK_DIR/clouds.yaml
else
    cp $ROOT_DIR/secrets/clouds.yaml $WORK_DIR/clouds.yaml
fi
# OPENSHIFT_TENANT_PASSWORD is defined in Github Actions secrets
if [ ! -n "$OPENSHIFT_TENANT_PASSWORD" ]; then
    source $ROOT_DIR/secrets/passwords.rc
fi

git clone -q https://github.com/shiftstack/dev-install $WORK_DIR/dev-install

pushd $WORK_DIR &>/dev/null

if ! openstack keypair show shiftstack-ci &>/dev/null; then
    echo "ERROR: No keypair was found for shiftstack-ci"
    exit 1
fi

if openstack server show $CLUSTER_NAME &>/dev/null; then
    echo "DEBUG: Cluster $CLUSTER_NAME was already running, removing it..."
    openstack server delete --wait $CLUSTER_NAME
    # Here we'll have to deal with the fact that a node being removed from Nova
    # will have its disk erased by Ironic, and takes a bit of time because it can
    # be reprovisioned. Which means that if didn't have a node available before the
    # cluster removal, there is a big chance that the redeploy will fail since Nova
    # Resources periodic tracker needs a bit of time to catch up on the node status.
fi
echo "DEBUG: Creating server for $CLUSTER_NAME..."
set +e
openstack server create --wait --key-name shiftstack-ci --network public --flavor b1-standard-96 --image centos-8-baremetal $CLUSTER_NAME
RC=$?
set -e
if [ $RC != 0 ]; then
    echo "ERROR: An error occured when creating $CLUSTER_NAME, running: 'openstack server show ${CLUSTER_NAME}'"
    openstack server show $CLUSTER_NAME
fi

PUBLIC_IP=$(openstack server show $CLUSTER_NAME -c addresses -f json | grep -Pom 1 '[0-9.]{7,15}')
if ! ssh -o ConnectTimeout=1200 -i $ROOT_DIR/secrets/vexxhost-ssh-private.key centos@$PUBLIC_IP; then
    echo "ERROR: Server for $CLUSTER_NAME ($PUBLIC_IP) was not reachable after 20 minutes"
    exit 1
fi
echo "DEBUG: Server was successfuly deployed and its IP is $PUBLIC_IP"

cd dev-install
export ansible_args="--private-key=$ROOT_DIR/secrets/vexxhost-ssh-private.key"
echo "DEBUG: Configure dev-install to deploy OpenStack on $CLUSTER_NAME"
make config host=$PUBLIC_IP user=centos &>/dev/null
cat $ROOT_DIR/configs/$CLUSTER_NAME.yaml >> local-overrides.yaml

echo "DEBUG: Run dev-install to deploy OpenStack on $CLUSTER_NAME..."
make osp_full
