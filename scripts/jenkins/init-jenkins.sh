#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
#set -x

if [[ -z ${PLAYGROUND_DIR+x} ]]; then
  BASEDIR=$(dirname $0)
  PLAYGROUND_DIR="$(cd "${BASEDIR}" && cd .. && cd .. && pwd)"
fi

JENKINS_HELM_CHART_VERSION=3.3.14

SET_USERNAME="admin"
SET_PASSWORD="admin"
REMOTE_CLUSTER=false

source "${PLAYGROUND_DIR}"/scripts/jenkins/jenkins-REST-client.sh

function deployLocalJenkins() {
  SET_USERNAME=${1}
  SET_PASSWORD=${2}
  REMOTE_CLUSTER=${3}

  # Mark the first node for Jenkins and agents. See jenkins/values.yamls "agent.workingDir" for details.
  # Remove first (in case new nodes were added)
  kubectl label --all nodes node- >/dev/null
  kubectl label $(kubectl get node -o name | sort | head -n 1) node=jenkins

  createSecret jenkins-credentials --from-literal=jenkins-admin-user=$SET_USERNAME --from-literal=jenkins-admin-password=$SET_PASSWORD -n default

  kubectl apply -f jenkins/resources || true

  # Find out the docker group and put the agent into it. Otherwise it has no permission to access  the docker host.
  helm upgrade -i jenkins --values jenkins/values.yaml \
    $(jenkinsHelmSettingsForLocalCluster) --set agent.runAsGroup=$(queryDockerGroupOfJenkinsNode) \
    --version ${JENKINS_HELM_CHART_VERSION} jenkins/jenkins -n default
}

function jenkinsHelmSettingsForLocalCluster() {
  if [[ $REMOTE_CLUSTER != true ]]; then
    # Run Jenkins and Agent pods as the current user.
    # Avoids file permission problems when accessing files on the host that were written from the pods

    # We also need a host port, so jenkins can be reached via localhost:9090
    # But: This helm charts only uses the nodePort value, if the type is "NodePort". So change it for local cluster.
    echo "--set controller.runAsUser=$(id -u) --set agent.runAsUser=$(id -u)" \
      "--set controller.serviceType=NodePort"
  fi
}

function queryDockerGroupOfJenkinsNode() {
  kubectl apply -f jenkins/tmp-docker-gid-grepper.yaml >/dev/null
  until kubectl get po --field-selector=status.phase=Running | grep tmp-docker-gid-grepper >/dev/null; do
    sleep 1
  done

  kubectl exec tmp-docker-gid-grepper -- cat /etc/group | grep docker | cut -d: -f3

  # This call might block some (unnecessary) seconds so move to background
  kubectl delete -f jenkins/tmp-docker-gid-grepper.yaml >/dev/null &
}

function waitForJenkins() {
  echo -n "Waiting for Jenkins to become available at ${JENKINS_URL}/login"
  HTTP_CODE="0"
  while [[ "${HTTP_CODE}" -ne "200" ]]; do
    HTTP_CODE="$(curl -s -L -o /dev/null --max-time 10 -w ''%{http_code}'' "${JENKINS_URL}/login")" || true
    echo -n "."
    sleep 2
  done
  echo ""
}

function configureJenkins() {
  JENKINS_URL="${1}"
  export JENKINS_URL
  JENKINS_USERNAME="${2}"
  export JENKINS_USERNAME
  JENKINS_PASSWORD="${3}"
  export JENKINS_PASSWORD
  SCMM_URL="${4}"
  SCMM_PASSWORD="${5}"
  REGISTRY_URL="${6}"
  REGISTRY_PATH="${7}"
  REGISTRY_USERNAME="${8}"
  REGISTRY_PASSWORD="${9}"

  waitForJenkins

  installPlugin "docker-workflow" "1.25"
  installPlugin "docker-plugin" "1.2.1"
  installPlugin "pipeline-utility-steps" "2.6.1"
  installPlugin "junit" "1.48"
  installPlugin "scm-manager" "1.7.3"
  installPlugin "html5-notifier-plugin" "1.5"

  safeRestart
  waitForJenkins

  setGlobalProperty "SCMM_URL" "${SCMM_URL}"
  setGlobalProperty "REGISTRY_URL" "${REGISTRY_URL}"
  setGlobalProperty "REGISTRY_PATH" "${REGISTRY_PATH}"

  createCredentials "scmm-user" "gitops" "${SCMM_PASSWORD}" "credentials for accessing scm-manager"
  createCredentials "registry-user" "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" "credentials for accessing the docker-registry"

  createJob "fluxv1-applications" "${SCMM_URL}" "fluxv1" "scmm-user"
  createJob "fluxv2-applications" "${SCMM_URL}" "fluxv2" "scmm-user"
  createJob "argocd-applications" "${SCMM_URL}" "argocd" "scmm-user"
}
