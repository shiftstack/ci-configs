[![Deploy a cluster with defaults](https://github.com/shiftstack/ci-configs/actions/workflows/deploy-default-cloud.yaml/badge.svg)](https://github.com/shiftstack/ci-configs/actions/workflows/deploy-default-cloud.yaml)

# CI Configs

This repository is used to provision our OpenStack clusters so we can run our OpenShift CI jobs
against them.

## How to use

```
./provision.sh <cluster-name>
```

The cluster name has to be a valid config in  [`configs`](./configs) (e.g. default-cloud).

## configs

The files in [`configs`](./configs) directory are [`dev-install`](https://github.com/shiftstack/dev-install) overrides,
where we define a specific configuration for each cluster.

## secrets

This directory is encrypted and is used to store `clouds.yaml`, passwords and the SSH private key.

Usage:
Install [git-crypt](https://github.com/AGWA/git-crypt):
```
sudo dnf install git-crypt
```

After cloning this repository, run:
```
git-crypt unlock
```

To add a new collaborator:
```
git-crypt add-gpg-user USER_ID
```

Note: Before commiting anything, inspect the status with `git-crypt status`.
