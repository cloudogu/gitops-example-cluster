#!/usr/bin/env bash

# set -o errexit -o nounset -o pipefail
# set -x

# See https://github.com/rancher/k3d/releases
K3D_VERSION=4.4.4
K3D_CLUSTER_NAME=gitops-playground
K3D_SUBNET=192.168.192.0/20
CLUSTER_NAME=${K3D_CLUSTER_NAME}

BIND_LOCALHOST=true

BASEDIR=$(dirname $0)
ABSOLUTE_BASEDIR="$(cd ${BASEDIR} && pwd)"
source ${ABSOLUTE_BASEDIR}/utils.sh

function main() {
  CLUSTER_NAME="$1"
  BIND_LOCALHOST="$2"
  SKIP_KUBECTL="$3"

  checkDockerAccessible

  # Install k3d if necessary
  if ! command -v k3d >/dev/null 2>&1; then
    installK3d
  else
    ACTUAL_K3D_VERSION="$(k3d --version | grep k3d | sed 's/k3d version v\(.*\)/\1/')"
    echo "k3d ${ACTUAL_K3D_VERSION} already installed"
    if [[ "${K3D_VERSION}" != "${ACTUAL_K3D_VERSION}" ]]; then
      msg="Up-/downgrade from ${ACTUAL_K3D_VERSION} to ${K3D_VERSION}?"
      confirm "$msg" ' [y/n]' &&
        installK3d
    fi
  fi

  createCluster
}

function installK3d() {
  curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v${K3D_VERSION} bash
}

function checkDockerAccessible() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not installed"
    exit 1
  fi
}

function createCluster() {
  if k3d cluster list | grep ${CLUSTER_NAME} >/dev/null; then
    if confirm "Cluster '${CLUSTER_NAME}' already exists. Do you want to delete the cluster?" ' [y/N]'; then
      k3d cluster delete ${CLUSTER_NAME}
      docker network rm ${CLUSTER_NAME} >/dev/null || true
    else
      echo "Not reinstalled."
      exit 0
    fi
    if ! confirm "Do you want to re-create the cluster now?" ' [y/N]'; then
      echo "Abort. No installation requested."
      exit 0
    fi
  fi

  # if local setup is not disabled via env_var it is set to bind to localhost
  K3D_ARGS=(
    '--k3s-server-arg=--kube-apiserver-arg=service-node-port-range=8010-32767'
    '-v /var/run/docker.sock:/var/run/docker.sock'
    '-v /tmp:/tmp'
    '-v /usr/bin/docker:/usr/bin/docker'
    '--k3s-server-arg=--no-deploy=metrics-server'
    '--k3s-server-arg=--no-deploy=traefik'
    '--no-hostip'
  )

  if [[ ${BIND_LOCALHOST} == 'true' ]]; then
    K3D_ARGS+=(
      '--network=host'
    )
  fi

  k3d cluster create ${CLUSTER_NAME} ${K3D_ARGS[*]}

  echo "Adding k3d cluster to ~/.kube/config"
  k3d kubeconfig merge ${CLUSTER_NAME} --kubeconfig-switch-context > /dev/null
}

function printParameters() {
  echo "The following parameters are valid:"
  echo
  echo " -h | --help     >> Help screen"
  echo
  echo "Set your prefered cluster name to install k3d. Defaults to 'k8s-gitops-playground'."
  echo "    | --cluster-name=VALUE   >> Sets the cluster name."
}

COMMANDS=$(getopt \
  -o h \
  --long help,cluster-name:,bind-localhost: \
  -- "$@")

eval set -- "$COMMANDS"

while true; do
  case "$1" in
    -h | --help   )   printParameters; exit 0 ;;
    --cluster-name)   CLUSTER_NAME="$2"; shift 2 ;;
    --bind-localhost) BIND_LOCALHOST="$2"; shift 2 ;;
    --) shift; break ;;
  *) break ;;
  esac
done

confirm "Run k3d-cluster initialization for cluster-name: '${CLUSTER_NAME}'." 'Continue? y/n [n]' ||
  exit 0

main "$CLUSTER_NAME" "$BIND_LOCALHOST" "$SKIP_KUBECTL"
