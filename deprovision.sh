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
# This script will deprovision an OpenStack cluster against an OpenStack cloud
# (defaults to our CI account on VEXXHOST)
# Usage:
# ./deprovision <config-name>
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

######################
# PLATFORM VARIABLES #
######################
# Note that defaults are set to use our VEXXHOST cloud
# but they can be overriden to deploy somewhere else (e.g. PSI)
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
SERVER_DELETE_CMD="openstack server delete --wait $CLUSTER_NAME"

if [ ! -f "$ROOT_DIR/configs/$CLUSTER_NAME.yaml" ]; then
    echo "ERROR: No config was found for $CLUSTER_NAME in $ROOT_DIR/configs"
    exit 1
fi

# Sanity check for CI jobs and locally
if [ -n "$IS_CI" ]; then
    for i in VEXXHOST_SHIFTSTACK_BM_CI_PASSWORD VEXXHOST_SHIFTSTACK_BM_CI_SSH_PRIVATE_KEY VEXXHOST_ENDPOINT; do
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

pushd $WORK_DIR &>/dev/null

PUBLIC_IP=$(openstack server show $CLUSTER_NAME -c addresses -f json | grep -Pom 1 '[0-9.]{7,15}')
SSH_ARGS="-o ConnectTimeout=10 -o "StrictHostKeyChecking=no" -i $WORK_DIR/ssh-private.key"
SSH_CMD="ssh $SSH_ARGS $SERVER_USER@$PUBLIC_IP"

if $SSH_CMD grep -q "Red\ Hat" /etc/redhat-release; then
    $SSH_CMD sudo subscription-manager remove --all
fi
$SERVER_DELETE_CMD
rm -rf $ROOT_DIR/secrets/osp-ci/exported-data/$CLUSTER_NAME $ROOT_DIR/configs/$CLUSTER_NAME.yaml

echo "DEBUG: Cluster $CLUSTER_NAME was successfuly destroyed !"
echo "DEBUG: You can now run 'git commit' in your ci-configs directory and push the changes."
