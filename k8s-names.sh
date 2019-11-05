#!/bin/bash -e

function log() {
  echo "$*" >&2
}

function die() {
  log "$*"
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
# Use an explicit docker tag if present
# Use a bitbucket build number to generate a name if it's possible
# Otherwise, use 'latest'
function tag() {
  BUILD_NUMBER="$BITBUCKET_BUILD_NUMBER$TRAVIS_BUILD_NUMBER$CIRCLE_BUILD_NUM"
  COMMIT="$BITBUCKET_COMMIT$TRAVIS_COMMIT$CIRCLE_SHA1"

  if [ ! -z "$DOCKER_TAG" ]; then
    echo "$DOCKER_TAG"
  elif [ ! -z "$BUILD_NUMBER" ]; then
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
  log "Performing a self test"

  log "Clearing env vars that might interfere with testing."
  unset TRAVIS_BUILD_NUMBER
  unset TRAVIS_COMMIT
  unset CIRCLE_BUILD_NUM
  unset CIRCLE_SHA1
  unset BITBUCKET_BUILD_NUMBER
  unset BITBUCKET_COMMIT

  log "Testing detecting local k8s servers."
  isLocalK8s "https://127.0.0.1:14443" || die "Didn't detect local k8s server from string."
  isLocalK8s "https://somecluster.hcp.someregion.azmk8s.io:443" && die "Detected an AKS server as a local k8s."
  isLocalK8s "" && die "Detected no server name as a local server."

  log "Testing that project root dir is the pwd when this script is run."
  PROJ_ROOT2=$(projRoot)
  [ "$PROJ_ROOT2" = "$PROJ_ROOT" ] || die "Project root dir was $PROJ_ROOT2 but it should be $PROJ_ROOT."

  log "Testing that unique names include parts of the project root dir."
  EXPECTED_PROJ_DIRNAME=$(basename $PROJ_ROOT)
  grep "$EXPECTED_PROJ_DIRNAME" <(uniqueName) &>/dev/null || die "Unique name should include the project dir name."
  
  log "Testing docker image name in a bitbucket pipeline."
  IMAGENAME=$(DOCKER_REPO=reponame BITBUCKET_BUILD_NUMBER=999 BITBUCKET_COMMIT=feedbeef image)
  [ "reponame:build-999-feedbee" = "$IMAGENAME" ] || die "Expected reponame:build-999-feedbee but got $IMAGENAME."

  log "Testing docker image name with an explicit tag override."
  IMAGENAME=$(DOCKER_REPO=reponame DOCKER_TAG=latest image)
  [ "reponame:latest" = "$IMAGENAME" ] || die "Expected reponame:latest but got $IMAGENAME."

  log "Testing docker image name in a travis ci."
  IMAGENAME=$(DOCKER_REPO=reponame TRAVIS_BUILD_NUMBER=999 TRAVIS_COMMIT=feedbeef image)
  [ "reponame:build-999-feedbee" = "$IMAGENAME" ] || die "Expected reponame:build-999-feedbee but got $IMAGENAME."

  log "Testing docker image name in a circle ci."
  IMAGENAME=$(DOCKER_REPO=reponame CIRCLE_BUILD_NUM=999 CIRCLE_SHA1=feedbeef image)
  [ "reponame:build-999-feedbee" = "$IMAGENAME" ] || die "Expected reponame:build-999-feedbee but got $IMAGENAME."

  log "Testing namespace name when explicitly set."
  EXPLICIT_NAMESPACE=$(NAMESPACE=somens-dev namespace)
  [ "somens-dev" = "$EXPLICIT_NAMESPACE" ] || die "Expected explicit ns to be somens-dev. Got $EXPLICIT_NAMESPACE."
  
  log "Testing namespace name when using a default value."
  DEFAULT_NAMESPACE=$(namespace)
  [[ "$DEFAULT_NAMESPACE" == *"$EXPECTED_PROJ_DIRNAME"* ]] || die "Local k8s namespace didnt include $EXPECT. Got $DEFAULT_NAMESPACE."

  ##
  ## Test stories.
  ##
  
  log "Story: Building a docker image on a dev workstation without kubernetes configured should result in a unique image name without any repo server."
  function getK8sServer() { return 0; }
  LOCAL_DOCKER_IMAGE=$(PROJ_ROOT=/tmp image)
  ENV=$(PROJ_ROOT=/tmp projenv)
  source <(echo $ENV)
  [ "$PROJ_DOCKER_IMAGE" = "tmp:latest" ] || die "Expected docker image to be tmp:latest. Got $LOCAL_DOCKER_IMAGE."

  log "Story: Building a docker image on a dev with a local kubernetes should result in a unique name on a local docker repo and the same unique name as a namspace."
  function getK8sServer() { echo "https://127.0.0.1"; }
  ENV=$(PROJ_ROOT=/tmp projenv)
  log $ENV
  source <(echo $ENV)
  # docker build -t $PROJ_DOCKER_IMAGE .
  [ "$PROJ_DOCKER_IMAGE" = "localhost:32000/tmp:latest" ] || die "Image name for local k8s should be localhost:32000/tmp:latest. Got $PROJ_DOCKER_IMAGE."
  # kubectl -n $PROJ_NAMESPACE apply -f resources/
  [ "$PROJ_NAMESPACE" = "tmp" ] || die "Namespace for local k8s should be tmp. Got $PROJ_NAMESPACE."

  log "Story: Building a docker in a bitbucket build pipeline should yield an explicit repo name with build info in the tag and an explicit namespace."
  function getK8sServer() { echo "https://somecluster.hcp.someregion.azmk8s.io:443"; }
  ENV=$(DOCKER_REPO=reponame BITBUCKET_BUILD_NUMBER=999 BITBUCKET_COMMIT=feedbeef NAMESPACE=somens projenv)
  log $ENV
  source <(echo $ENV)
  # docker build -t $BITBUCKET_IMAGE
  [ "$PROJ_DOCKER_IMAGE" = "reponame:build-999-feedbee" ] || die "Bitbucket pipeline image name should be reponame:build-999-feebee."
  # kubectl -n $PROJ_NAMESPACE apply -f resources/
  [ "$PROJ_NAMESPACE" = "somens" ] || die "Bitbucket pipeline image name should be reponame:build-999-feebee."

  log "Self test succeeded."
}

PROJ_ROOT=${PROJ_ROOT:-$(realpath $PWD)}
case "$1" in
  selftest) selftest ;;
  env) projenv ;;
  projenv) projenv ;;
esac
