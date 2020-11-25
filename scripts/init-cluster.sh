#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
#set -x

# TODO replace apply.sh with k3d or provide both options?
K3D_VERSION=3.3.0
K3D_CLUSTER_NAME=k8s-gitops-playground
# See https://github.com/rancher/k3s/releases
K3S_VERSION=1.19.3-k3s3
HELM_VERSION=3.4.1
KUBECTL_VERSION=1.19.3

BASEDIR=$(dirname $0)
ABSOLUTE_BASEDIR="$(cd ${BASEDIR} && pwd)"
source ${ABSOLUTE_BASEDIR}/utils.sh

function main() {
  checkDockerAccessible

  # Install kubectl if necessary
  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl already installed"
  else
    msg="Install kubectl ${KUBECTL_VERSION}?"
    confirm "$msg" ' [y/n]' &&
      installKubectl
  fi

  # Install helm if necessary
  if ! command -v helm >/dev/null 2>&1; then
    installHelm
  else
    ACTUAL_HELM_VERSION=$(helm version --template="{{ .Version }}")
    echo "helm ${ACTUAL_HELM_VERSION} already installed"
    if [[ "$ACTUAL_HELM_VERSION" != "v$HELM_VERSION" ]]; then
      msg="Up-/downgrade from ${ACTUAL_HELM_VERSION} to ${HELM_VERSION}?"
      confirm "$msg" ' [y/n]' &&
        installHelm
    fi
  fi

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

function checkDockerAccessible() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not installed"
    exit 1
  fi
}

function installKubectl() {
  curl -LO https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
  echo "kubectl installed"
}

function installHelm() {
  # curls helm install script and installs/updates it if necessary
  curl -s get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 |
    bash -s -- --version v$HELM_VERSION
}

function installK3d() {
  curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v${K3D_VERSION} bash
}

function createCluster() {
  # More info:
  # * On Commands: https://k3s.io/usage/commands/
  # * On exposing services: https://github.com/rancher/k3s/blob/v3.0.1/docs/usage/guides/exposing_services.md
  K3S_ARGS=(
    "--image docker.io/rancher/k3s:v${K3S_VERSION}"
    # Save some resources
    '--k3s-server-arg=--no-deploy=metrics-server'
    # TODO traefik seems to run anyway!?
    '--k3s-server-arg=--no-deploy=traefik"'
    # TODO do we need the service LB or switch to nodePorts in order to avoid binding to external Host IP?
    #'--k3s-server-arg=--no-deploy=servicelb"'
    # Allow for using node ports with "smaller numbers"
    '--k3s-server-arg=--kube-apiserver-arg=service-node-port-range=8010-32767'
    '-v /var/run/docker.sock:/var/run/docker.sock'
    '-v /tmp/k8s-gitops-playground-jenkins-agent:/tmp/k8s-gitops-playground-jenkins-agent'
    '-v /usr/bin/docker:/usr/bin/docker'
    # Bind to host directly. Works only on linux, alternative: '--port' every single port we need, or via serviceLB
    '--network=host'
    # no hostip avoids the error bellow:
    # But: Is it the reason why the serviceLB binds to external-ip only and not to localhost?
    # INFO[0006] (Optional) Trying to get IP of the docker host and inject it into the cluster as 'host.k3d.internal' for easy access
    #panic: runtime error: index out of range [0] with length 0
    #
    #goroutine 1 [running]:
    #github.com/rancher/k3d/v3/pkg/runtimes/docker.GetGatewayIP(0x11ca660, 0xc0000b8000, 0xc0003a1c40, 0x40, 0x0, 0xc0004611e8, 0x46f3d2, 0x2, 0xfdd920)
    #        /drone/src/pkg/runtimes/docker/network.go:118 +0x20c
    '--no-hostip'
  )

  if k3d cluster list | grep ${K3D_CLUSTER_NAME} >/dev/null; then
    if confirm "Cluster '${K3D_CLUSTER_NAME}' already exists. Delete and re-create?" ' [y/N]'; then
      k3d cluster delete $K3D_CLUSTER_NAME
    else
      echo "Not reinstalled."
      exit 0
    fi
  fi

  echo "Installing and starting k3d cluster ( k3d ${K3D_VERSION}, k3s ${K3S_VERSION})"
  echo "To stop the cluster and all workloads use: k3d cluster stop ${K3D_CLUSTER_NAME}"
  echo "To restart the cluster use: k3d cluster start ${K3D_CLUSTER_NAME}"
  echo "To uninstall the cluster use: k3d cluster delete ${K3D_CLUSTER_NAME}"
  echo

  k3d cluster create ${K3D_CLUSTER_NAME} ${K3S_ARGS[*]}

  # Preload images
  # Otherwise really slow startup because of image pulls. 4 min for jenkins, another  3min for agent image
  # TODO We have to parse them from the helm charts (e.g. helm template) or define the versions in a common bash file 
  # and pass them to helm install :-/
  IMPORT_IMAGES=(
    'jenkins/inbound-agent:4.6-1-jdk11'
    'jenkins/jenkins:2.249.3-lts-jdk11'
  )
  k3d image import -c k8s-gitops-playground ${IMPORT_IMAGES[*]}

  k3d kubeconfig merge ${K3D_CLUSTER_NAME} --switch-context
}

main "$@"
