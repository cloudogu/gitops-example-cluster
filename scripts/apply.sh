#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
#set -x

SCM_USER=scmadmin
SCM_PWD=scmadmin

BASEDIR=$(dirname $0)
ABSOLUTE_BASEDIR="$(cd ${BASEDIR} && pwd)"
PLAYGROUND_DIR="$(cd ${BASEDIR} && cd .. && pwd)"
JENKINS_HOME="/tmp/k8s-gitops-playground-jenkins-agent"

PETCLINIC_COMMIT=949c5af
# get scm-manager port from values
SCMM_PORT=$(grep -A1 'service:' "${PLAYGROUND_DIR}"/scm-manager/values.yaml | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')

PETCLINIC_COMMIT=949c5af
# get scm-manager port from values
SCMM_PORT=$(grep -A1 'service:' scm-manager/values.yaml | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')

source ${ABSOLUTE_BASEDIR}/utils.sh

function main() {
  DEBUG=$1
  INSTALL_ALL_MODULES=$2
  INSTALL_FLUXV1=$3
  INSTALL_FLUXV2=$4
  INSTALL_ARGOCD=$5

  if [[ $DEBUG = true ]]; then
    set -x
    applyBasicK8sResources
    initSCMM

    if [[ $INSTALL_ALL_MODULES = true || $INSTALL_FLUXV1 = true ]]; then
      initFluxV1
    fi
    if [[ $INSTALL_ALL_MODULES = true || $INSTALL_FLUXV2 = true ]]; then
      initFluxV2
    fi
    if [[ $INSTALL_ALL_MODULES = true || $INSTALL_ARGOCD = true ]]; then
      initArgo
    fi

    # Start Jenkins last, so all repos have been initialized when repo indexing starts
    initJenkins

  else
    applyBasicK8sResources > /dev/null 2>&1 & spinner "Basic setup..."
    initSCMM > /dev/null 2>&1 & spinner "Starting SCM-Manager..."

    if [[ $INSTALL_ALL_MODULES = true || $INSTALL_FLUXV1 = true ]]; then
      initFluxV1 > /dev/null 2>&1 & spinner "Starting Flux V1..."
    fi
    if [[ $INSTALL_ALL_MODULES = true || $INSTALL_FLUXV2 = true ]]; then
      initFluxV2 > /dev/null 2>&1 & spinner "Starting Flux V2..."
    fi
    if [[ $INSTALL_ALL_MODULES = true || $INSTALL_ARGOCD = true ]]; then
      initArgo > /dev/null 2>&1 & spinner "Starting ArgoCD..."
    fi

    # Start Jenkins last, so all repos have been initialized when repo indexing starts
    initJenkins > /dev/null 2>&1 & spinner "Starting Jenkins..."
  fi

  printWelcomeScreen
}

function applyBasicK8sResources() {

  # Create Jenkins agent working dir explicitly. Otherwise it seems to be owned by root
  mkdir -p ${JENKINS_HOME}

  kubectl apply -f k8s-namespaces || true

  createScmmSecrets

  kubectl apply -f jenkins/resources || true

  helm repo add jenkins https://charts.jenkins.io
  helm repo add fluxcd https://charts.fluxcd.io
  helm repo add stable https://charts.helm.sh/stable
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo update

  helm upgrade -i docker-registry --values docker-registry/values.yaml --version 1.9.4 stable/docker-registry -n default
}

function initSCMM() {
    helm upgrade -i scmm --values scm-manager/values.yaml \
    --set-file=postStartHookScript=scm-manager/initscmm.sh \
    scm-manager/chart -n default

    pushHelmChartRepo 'common/spring-boot-helm-chart'
}

function initJenkins() {
  # Make sure to run Jenkins and Agent containers as the current user. Avoids permission problems.
  # Find out the docker group and put the agent into it. Otherwise it has no permission to access  the docker host.
  helm upgrade -i jenkins --values jenkins/values.yaml \
    --set master.runAsUser=$(id -u) \
    --set agent.runAsUser=$(id -u) \
    --set agent.runAsGroup=$(getent group docker | awk -F: '{ print $3}') \
    --version 2.13.0 jenkins/jenkins -n default
}

function initFluxV1() {
  initRepo 'fluxv1/gitops'
  pushPetClinicRepo 'applications/petclinic/fluxv1/plain-k8s' 'fluxv1/petclinic-plain'
  initRepoWithSource 'applications/nginx/fluxv1' 'fluxv1/nginx-helm'

  helm upgrade -i flux-operator --values fluxv1/flux-operator/values.yaml --version 1.3.0 fluxcd/flux -n fluxv1
  helm upgrade -i helm-operator --values fluxv1/helm-operator/values.yaml --version 1.0.2 fluxcd/helm-operator -n fluxv1
}

function initFluxV2() {
  pushPetClinicRepo 'applications/petclinic/fluxv2/plain-k8s' 'fluxv2/petclinic-plain'
  initRepoWithSource 'fluxv2' 'fluxv2/gitops'

  kubectl apply -f fluxv2/clusters/k8s-gitops-playground/fluxv2/gotk-components.yaml || true
  kubectl apply -f fluxv2/clusters/k8s-gitops-playground/fluxv2/gotk-gitrepository.yaml || true
  kubectl apply -f fluxv2/clusters/k8s-gitops-playground/fluxv2/gotk-kustomization.yaml || true

}

function initArgo() {
  helm upgrade -i argocd --values argocd/values.yaml --version 2.9.5 argo/argo-cd -n argocd
  kubectl apply -f argocd/resources -n argocd || true

  # set argocd admin password to 'admin' here, because it does not work through the helm chart
  kubectl patch secret -n argocd argocd-secret -p '{"stringData": { "admin.password": "$2y$10$GsLZ7KlAhW9xNsb10YO3/O6jlJKEAU2oUrBKtlF/g1wVlHDJYyVom"}}' || true

  pushPetClinicRepo 'applications/petclinic/argocd/plain-k8s' 'argocd/petclinic-plain'
  initRepo 'argocd/gitops'
  initRepoWithSource 'applications/nginx/argocd' 'argocd/nginx-helm'
}

function createScmmSecrets() {
  kubectl create secret generic gitops-scmm --from-literal=USERNAME=gitops --from-literal=PASSWORD=somePassword -n default || true
  kubectl create secret generic gitops-scmm --from-literal=USERNAME=gitops --from-literal=PASSWORD=somePassword -n fluxv1 || true
  # fluxv2 needs lowercase fieldnames
  kubectl create secret generic gitops-scmm --from-literal=username=gitops --from-literal=password=somePassword -n fluxv2 || true
  kubectl create secret generic gitops-scmm --from-literal=USERNAME=gitops --from-literal=PASSWORD=somePassword -n argocd || true
}

function pushPetClinicRepo() {
  LOCAL_PETCLINIC_SOURCE="$1"
  TARGET_REPO_SCMM="$2"

  TMP_REPO=$(mktemp -d)

  git clone -n https://github.com/cloudogu/spring-petclinic.git "${TMP_REPO}" --quiet > /dev/null 2>&1
  (
    cd "${TMP_REPO}"
    # Checkout a defined commit in order to get a deterministic result
    git checkout ${PETCLINIC_COMMIT} --quiet

    cp -r "${PLAYGROUND_DIR}/${LOCAL_PETCLINIC_SOURCE}"/* .
    git checkout -b main --quiet
    git add .
    git commit -m 'Add GitOps Pipeline and K8s resources' --quiet

    waitForScmManager
    git push -u "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" HEAD:main --force --quiet
  )

  rm -rf "${TMP_REPO}"

  setMainBranch "${TARGET_REPO_SCMM}"
}

function pushHelmChartRepo() {
  TARGET_REPO_SCMM="$1"

  TMP_REPO=$(mktemp -d)

  git clone -n https://github.com/cloudogu/spring-boot-helm-chart.git "${TMP_REPO}" --quiet
  (
    cd "${TMP_REPO}"
    git tag 1.0.0

    waitForScmManager
    git push "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" HEAD:main --force --quiet
    git push "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" refs/tags/1.0.0 --quiet
  )

  rm -rf "${TMP_REPO}"

  setMainBranch "${TARGET_REPO_SCMM}"
}

function waitForScmManager() {
#  echo -n "Waiting for SCM-Manager to become available at http://localhost:${SCMM_PORT}/scm"
  while [[ "$(curl -s -L -o /dev/null -w ''%{http_code}'' "http://localhost:${SCMM_PORT}/scm")" -ne "200" ]]; do
#    echo -n .
    sleep 2
  done
}

function initRepo() {
  TARGET_REPO_SCMM="$1"

  TMP_REPO=$(mktemp -d)

  git clone "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" "${TMP_REPO}"
  (
    cd "${TMP_REPO}"
    git checkout main --quiet || git checkout -b main --quiet
    echo "# gitops" >README.md
    git add README.md
    # exits with 1 if there were differences and 0 means no differences.
    if ! git diff-index --exit-code --quiet HEAD --; then
      git commit -m "Add readme" --quiet
    fi
    waitForScmManager
    git push -u "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" HEAD:main --force
  )

  setMainBranch "${TARGET_REPO_SCMM}"
}

function initRepoWithSource() {
  echo "initiating repo $1 with source $2"
  SOURCE_REPO="$1"
  TARGET_REPO_SCMM="$2"

  TMP_REPO=$(mktemp -d)

  git clone "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" "${TMP_REPO}"
  (
    cd "${TMP_REPO}"
    cp -r "${PLAYGROUND_DIR}/${SOURCE_REPO}"/* .
    git checkout main --quiet || git checkout -b main --quiet
    git add .
    git commit -m "Init ${TARGET_REPO_SCMM}" --quiet || true
    waitForScmManager
    git push -u "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/repo/${TARGET_REPO_SCMM}" HEAD:main --force
  )

  rm -rf "${TMP_REPO}"

  setMainBranch "${TARGET_REPO_SCMM}"
}

function setMainBranch() {
  TARGET_REPO_SCMM="$1"

  curl -s -L -X PUT -H 'Content-Type: application/vnd.scmm-gitConfig+json' \
    --data-raw "{\"defaultBranch\":\"main\"}" \
    "http://${SCM_USER}:${SCM_PWD}@localhost:${SCMM_PORT}/scm/api/v2/config/git/${TARGET_REPO_SCMM}"
}

function printWelcomeScreen() {
  echo
  echo
  echo "|-----------------------------------------------------------------------------------------------------------------------|"
  echo "|                                     Welcome to the GitOps playground by Cloudogu!                                     |"
  echo "|-----------------------------------------------------------------------------------------------------------------------|"
  echo "|                                                                                                                       |"
  echo "| The playground features three example applications (Sprint PetClinic - one for every gitops solution) in SCM-Manager. |"
  echo "| See here:                                                                                                             |"
  echo "|                                                                                                                       |"
  echo -e "| - \e[32mhttp://localhost:9091/scm/repo/fluxv1/petclinic-plain/code/sources/main/\e[0m                                            |"
  echo -e "| - \e[32mhttp://localhost:9091/scm/repo/fluxv2/petclinic-plain/code/sources/main/\e[0m                                            |"
  echo -e "| - \e[32mhttp://localhost:9091/scm/repo/argocd/petclinic-plain/code/sources/main/\e[0m                                            |"
  echo "|                                                                                                                       |"
  echo -e "| Credentials for SCM-Manager and Jenkins are: \e[31mscmadmin/scmadmin\e[0m                                                        |"
  echo "|                                                                                                                       |"
  echo "| Right now, four Jenkins jobs are running: (when Jenkins is successfully deployed and running)                         |"
  echo "|                                                                                                                       |"
  echo -e "| - \e[32mhttp://localhost:9090/job/fluxv1-nginx/\e[0m                                                                             |"
  echo -e "| - \e[32mhttp://localhost:9090/job/fluxv1-petclinic-plain/\e[0m                                                                   |"
  echo -e "| - \e[32mhttp://localhost:9090/job/fluxv2-petclinic-plain/\e[0m                                                                   |"
  echo -e "| - \e[32mhttp://localhost:9090/job/argocd-petclinic-plain/\e[0m                                                                   |"
  echo "|                                                                                                                       |"
  echo "| During the job, jenkins pushes into the corresponding GitOps repo and creates a pull request for production:          |"
  echo "|                                                                                                                       |"
  echo "| For Flux V1:                                                                                                          |"
  echo "|                                                                                                                       |"
  echo -e "| - GitOps repo: \e[32mhttp://localhost:9091/scm/repo/fluxv1/gitops/code/sources/main/\e[0m                                        |"
  echo -e "| - Pull requests: \e[32mhttp://localhost:9091/scm/repo/fluxv1/gitops/pull-requests\e[0m                                           |"
  echo "|                                                                                                                       |"
  echo "| For Flux V2:                                                                                                          |"
  echo "|                                                                                                                       |"
  echo -e "| - GitOps repo: \e[32mhttp://localhost:9091/scm/repo/fluxv2/gitops/code/sources/main/\e[0m                                        |"
  echo -e "| - Pull requests: \e[32mhttp://localhost:9091/scm/repo/fluxv2/gitops/pull-requests\e[0m                                           |"
  echo "|                                                                                                                       |"
  echo "| For ArgoCD:                                                                                                           |"
  echo "|                                                                                                                       |"
  echo -e "| - GitOps repo: \e[32mhttp://localhost:9091/scm/repo/argocd/gitops/code/sources/main/\e[0m                                        |"
  echo -e "| - Pull requests: \e[32mhttp://localhost:9091/scm/repo/argocd/gitops/pull-requests\e[0m                                           |"
  echo "|                                                                                                                       |"
  echo -e "| There is also the ArgoCD UI which can be found at \e[32mhttp://localhost:9092/\e[0m                                              |"
  echo -e "| Credentials for the ArgoCD UI are: \e[31madmin/admin\e[0m                                                                        |"
  echo "|                                                                                                                       |"
  echo "| After a successful Jenkins build, the application will be deployed into the cluster.                                  |"
  echo "| This may take a minute for the GitOps operator to sync.                                                               |"
  echo "|                                                                                                                       |"
  echo "| Flux V1 applications:                                                                                                 |"
  echo -e "| \e[32mhttp://localhost:9000/\e[0m for Flux V1 petclinic for staging                                                              |"
  echo -e "| \e[32mhttp://localhost:9001/\e[0m for Flux V1 petclinic for production                                                           |"
  echo -e "| \e[32mhttp://localhost:9002/\e[0m for Flux V1 nginx for staging                                                                  |"
  echo -e "| \e[32mhttp://localhost:9003/\e[0m for Flux V1 nginx for production                                                               |"
  echo "|                                                                                                                       |"
  echo "| Flux V2 applications:                                                                                                 |"
  echo -e "| \e[32mhttp://localhost:9010/\e[0m for Flux V2 petclinic for staging                                                              |"
  echo -e "| \e[32mhttp://localhost:9011/\e[0m for Flux V2 petclinic for production                                                           |"
  echo "|                                                                                                                       |"
  echo "| ArgoCD applications:                                                                                                  |"
  echo -e "| \e[32mhttp://localhost:9020/\e[0m for ArgoCD petclinic for staging                                                               |"
  echo -e "| \e[32mhttp://localhost:9021/\e[0m for ArgoCD petclinic for production                                                            |"
  echo "|                                                                                                                       |"
  echo "| The applications on the *-production namespace are only available (deployed) when you merge the pull requests         |"
  echo "| in the corresponding gitops repos.                                                                                    |"
  echo "| After about 1 Minute after the merge, the GitOps operator deploys to production.                                      |"
  echo "|                                                                                                                       |"
  echo "|-----------------------------------------------------------------------------------------------------------------------|"
}

function printUsage()
{
    echo "This script will install all necessary resources for Flux V1, Flux V2 and ArgoCD into your k8s-cluster."
    echo ""
    printParameters
    echo ""
}

function printParameters() {
    echo "The following parameters are valid:"
    echo
    echo " -h | --help     >> Help screen"
    echo
    echo "Install only the desired GitOps modules. Multiple selections possible."
    echo "    | --fluxv1   >> Install the Flux V1 module"
    echo "    | --fluxv2   >> Install the Flux V2 module"
    echo "    | --argocd   >> Install the ArgoCD module"
    echo
    echo " -w | --welcome  >> Welcome screen"
    echo
    echo " -d | --debug    >> Debug output"
}


COMMANDS=$(getopt \
                -o hwd \
                --long help,fluxv1,fluxv2,argocd,welcome,debug \
                -- "$@")

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

eval set -- "$COMMANDS"

DEBUG=false
INSTALL_ALL_MODULES=true
INSTALL_FLUXV1=false
INSTALL_FLUXV2=false
INSTALL_ARGOCD=false
while true; do
  case "$1" in
    -h | --help     ) printUsage; exit 0 ;;
    --fluxv1        ) INSTALL_FLUXV1=true; INSTALL_ALL_MODULES=false; shift ;;
    --fluxv2        ) INSTALL_FLUXV2=true; INSTALL_ALL_MODULES=false; shift ;;
    --argocd        ) INSTALL_ARGOCD=true; INSTALL_ALL_MODULES=false; shift ;;
    -w | --welcome  ) printWelcomeScreen; exit 0 ;;
    -d | --debug    ) DEBUG=true; shift ;;
    --              ) shift; break ;;
    *               ) break ;;
  esac
done

confirm "Applying gitops playground to kubernetes cluster: '$(kubectl config current-context)'." 'Continue? y/n [n]' ||
  exit 0

main $DEBUG $INSTALL_ALL_MODULES $INSTALL_FLUXV1 $INSTALL_FLUXV2 $INSTALL_ARGOCD

