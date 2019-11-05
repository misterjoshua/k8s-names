#!/bin/bash -e

function die() {
  echo "$*" >&2
  exit 1
}

function getK8sContextCluster() {
  kubectl config get-contexts | awk '/^\*/ { print $2, $3 }'
}

function getK8sClusterServer() {
  kubectl config view -ojsonpath="{.clusters[?(@.name=='$1')].cluster.server}"
}

# Get the server address for the current cluster according to kubectl
function getK8sServer() {
  if [ ! -z "$(command -v kubectl)" ]; then
    read CONTEXT CLUSTER < <(getK8sContextCluster)
    getK8sClusterServer $CLUSTER
  fi
  
  # No kubectl? No server, so we provide no output.
}

# Detect if we're operating on a local kubernetes cluster like microk8s.
function isLocalK8s() {
  egrep "http.*//127|localhost" <<<$1 &>/dev/null
}

# Generate a unique name
function uniqueName() {
  sed -re 's#/#-#g; s#^-##' <(realpath $(projRoot))
}

# Provides a namespace name.
# If $NAMESPACE is set, use that explicitly.
# Otherwise, use a unique name
function namespace() {
  if [ ! -z "$NAMESPACE" ]; then
    # Explicit namespace
    echo "$NAMESPACE"
  else
    # Use a unique name
    uniqueName
  fi
}

# Project root directory.
function projRoot() {
  realpath $PROJ_ROOT
}

# A host name unique for this project.
function host() {
  echo "$(namespace).$(hostname)"
}

# External IP
function externalIp() {
  if [ -x "$(command -v ip)" ]; then
    awk '/via.*src/{print $7}' <(ip route get 1.1.1.1)
  fi
}

# Repository name for a docker image.
# If an explicit $DOCKER_REPO is provided, use that.
# If we're using a local cluster, use a local repository.
# Otherwise, use a unique name.
function repo() {
  if [ ! -z "$DOCKER_REPO" ]; then
    # Explicit docker repository
    echo $DOCKER_REPO
  elif isLocalK8s $(getK8sServer); then
    # Local k8s, use a local repo
    echo "localhost:32000/$(namespace)"
  else
    # Otherwise, use a unique name
    uniqueName
  fi
}

# Tag name for docker image.
# Use a bitbucket build number to generate a name if it's possible
# Otherwise, use 'latest'
function tag() {
  BUILD_NUMBER="$BITBUCKET_BUILD_NUMBER$TRAVIS_BUILD_NUMBER$CIRCLE_BUILD_NUM"
  COMMIT="$BITBUCKET_COMMIT$TRAVIS_COMMIT$CIRCLE_SHA1"

  if [ ! -z "$BUILD_NUMBER" ]; then
    # In the pipeline, tag the image by build number and part of the commit hash
    echo "build-$BUILD_NUMBER-$(cut -b1-7 <<<$COMMIT)"
  else
    # Outside of the pipeline, it's always latest
    echo "latest"
  fi
}

# Image name including repo and tag, especially for docker build -t <tag>
function image() {
  echo "$(repo):$(tag)"
}

# Provide sourceable environment variables.
function projenv() {
  echo PROJ_HOST=$(host)
  echo PROJ_NAMESPACE=$(namespace)
  echo PROJ_ROOT=$(projRoot)
  echo PROJ_DOCKER_IMAGE=$(image)
  echo PROJ_IP=$(externalIp)
}

function selftest() {
  # Clear out some env vars that might interfere.
  unset TRAVIS_BUILD_NUMBER
  unset TRAVIS_COMMIT
  unset CIRCLE_BUILD_NUM
  unset CIRCLE_SHA1
  unset BITBUCKET_BUILD_NUMBER
  unset BITBUCKET_COMMIT

  # Test detecting local k8s servers
  isLocalK8s "https://127.0.0.1:14443" || die "Didn't detect local k8s server from string"
  isLocalK8s "https://somecluster.hcp.someregion.azmk8s.io:443" && die "Detected an AKS server as a local k8s"
  isLocalK8s "" && die "Detected no server name as a local server"

  # Project root dir should be the pwd when this script is run.
  PROJ_ROOT2=$(projRoot)
  [ "$PROJ_ROOT2" = "$PROJ_ROOT" ] || die "Project root dir was $PROJ_ROOT2 but it should be $PROJ_ROOT"

  EXPECTED_PROJ_DIRNAME=$(basename $PROJ_ROOT)
  # Unique names should include parts of the project root dir.
  grep "$EXPECTED_PROJ_DIRNAME" <(uniqueName) &>/dev/null || die "Unique name should include the project dir name."
  
  # Docker image in a bitbucket pipeline.
  IMAGENAME=$(DOCKER_REPO=reponame BITBUCKET_BUILD_NUMBER=999 BITBUCKET_COMMIT=feedbeef image)
  [ "reponame:build-999-feedbee" = "$IMAGENAME" ] || die "Expected 'reponame:build-999-feedbee' but got '$IMAGENAME'"

  # Docker image in a travis ci
  IMAGENAME=$(DOCKER_REPO=reponame TRAVIS_BUILD_NUMBER=999 TRAVIS_COMMIT=feedbeef image)
  [ "reponame:build-999-feedbee" = "$IMAGENAME" ] || die "Expected 'reponame:build-999-feedbee' but got '$IMAGENAME'"

  # Docker image in a circle ci
  IMAGENAME=$(DOCKER_REPO=reponame CIRCLE_BUILD_NUM=999 CIRCLE_SHA1=feedbeef image)
  [ "reponame:build-999-feedbee" = "$IMAGENAME" ] || die "Expected 'reponame:build-999-feedbee' but got '$IMAGENAME'"

  # Namespace when explicitly set.
  EXPLICIT_NAMESPACE=$(NAMESPACE=somens-dev namespace)
  [ "somens-dev" = "$EXPLICIT_NAMESPACE" ] || die "Expected explicit ns to be somens-dev. Got $EXPLICIT_NAMESPACE"
  
  # Namespace when default should include the project dir.
  DEFAULT_NAMESPACE=$(namespace)
  [[ "$DEFAULT_NAMESPACE" == *"$EXPECTED_PROJ_DIRNAME"* ]] || die "Local k8s namespace didnt include $EXPECT. Got $DEFAULT_NAMESPACE"

  ##
  ## Scenarios
  ##
  
  ## Building a docker image on a dev workstation without kubernetes configured should be to the unique name without any repo server
  function getK8sClusterServer() { return 0; }
  LOCAL_DOCKER_IMAGE=$(PROJ_ROOT=/tmp image)
  [ "$LOCAL_DOCKER_IMAGE" = "tmp:latest" ] || die "Expected docker image to be tmp:latest. Got $LOCAL_DOCKER_IMAGE."

  ## Building a docker image on a dev with a local kubernetes should push to the local k8s repo and have a unique name namespace.
  function getK8sClusterServer() { echo "https://127.0.0.1"; }
  LOCAL_K8S_IMAGE=$(PROJ_ROOT=/tmp image)
  # docker build -t $LOCAL_K8S_IMAGE .
  [ "$LOCAL_K8S_IMAGE" = "localhost:32000/tmp:latest" ] || die "Image name for local k8s should be localhost:32000/tmp:latest. Got $LOCAL_K8S_IMAGE"
  LOCAL_K8S_NS=$(PROJ_ROOT=/tmp namespace)
  # kubectl -n $LOCAL_K8S_NS apply -f resources/
  [ "$LOCAL_K8S_NS" = "tmp" ] || die "Namespace for local k8s should be tmp. Got $LOCAL_K8S_NS"

  ## Building a docker in a bitbucket build pipeline should push to somewhere else 
  BITBUCKET_IMAGE=$(DOCKER_REPO=reponame BITBUCKET_BUILD_NUMBER=999 BITBUCKET_COMMIT=feedbeef NAMESPACE=somens image)
  [ "$BITBUCKET_IMAGE" = "reponame:build-999-feedbee" ] || die "Bitbucket pipeline image name should be reponame:build-999-feebee"
  # docker build -t $BITBUCKET_IMAGE
  BITBUCKET_NS=$(DOCKER_REPO=reponame BITBUCKET_BUILD_NUMBER=999 BITBUCKET_COMMIT=feedbeef NAMESPACE=somens namespace)
  # kubectl -n $BITBUCKET_NS apply -f resources/
  [ "$BITBUCKET_NS" = "somens" ] || die "Bitbucket pipeline image name should be reponame:build-999-feebee"
}

PROJ_ROOT=$(realpath $(dirname $PWD))
case "$1" in
  selftest) selftest ;;
  env) projenv ;;
esac
