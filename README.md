[![Build Status](https://travis-ci.org/misterjoshua/k8s-names.svg?branch=master)](https://travis-ci.org/misterjoshua/k8s-names)

# K8s Names Script

This script provides convention-over-configuration-based names for docker images, docker image tags, and kubernetes namespaces by outputting environment variables that can be consumed by your build scripts.

## Basic Usage

The script provides a stable interface for getting names for scripts that deploy to kubernetes. This is useful if you're developing scripts to build a project and deploy to kubernetes.

```
$ hostname
nyx

# A project directory
$ cd /home/user/proj/myproj

$ ./k8s-names.sh env
PROJ_HOST=home-user-proj-myproj.nyx
PROJ_NAMESPACE=home-user-proj-myproj
PROJ_ROOT=/home/user/proj/myproj
PROJ_DOCKER_IMAGE=home-user-proj-myproj:latest
PROJ_IP=192.168.1.110

# A different project directory. Note the difference in namespace
$ cd /home/user/proj/myotherproj

$ ./k8s-names.sh env
PROJ_HOST=home-user-proj-myotherproj.nyx
PROJ_NAMESPACE=home-user-proj-myotherproj
PROJ_ROOT=/home/user/proj/myotherproj
PROJ_DOCKER_IMAGE=home-user-proj-myotherproj:latest
PROJ_IP=192.168.1.110

# Import the variables
$ source <(./k8s-names.sh env)

# One-liner to use the env vars from the web
$ source <(bash <(curl https://raw.githubusercontent.com/misterjoshua/k8s-names/master/k8s-names.sh) env)

$ echo $PROJ_NAMESPACE
/home/user/proj/myotherproj
```

## Output Environment Variables

These are the environment variables you may use in your build scripts.

| Variable | Description
| -------- | -----------
| `PROJ_NAMESPACE` | A kubernetes namespace name.
| `PROJ_HOST` | A host name, possibly useful for ingress resources. This is based on the namespace and local hostname.
| `PROJ_ROOT` | Root directory for a project. Unless explicitly overridden, this is based on your current working directory when invoking this script.
| `PROJ_DOCKER_IMAGE` | The full docker image name following this script's naming convention, which is based based on `PROJ_ROOT` or the explicit namespace set through `NAMESPACE=mynamespace`
| `PROJ_IP` | The IP address of the interface that knows how to get to the Internet.

## Configuration Environment Variables

You may provide configuration to override the conventions of this script.

| Variable | Description
| -------- | -------------
| `PROJ_ROOT` | Allows you to explicitly set the project root directory. By default, this is your `pwd` when calling this script.
| `DOCKER_REPO` | Allows you to explicitly set the docker repository name of the image. You might set this at the pipeline step level.
| `DOCKER_TAG` | Explicitly set the docker image tag. You might want to set it to `latest` if you're pushing semantically versioned docker images.
| `NAMESPACE` | Explicitly set the namespace. You might set this at the pipeline step level.

## Travis CI Pipeline Example

```
language: generic
script:
- source <(bash <(curl https://raw.githubusercontent.com/misterjoshua/k8s-names/master/k8s-names.sh) env)
- docker build -t $PROJ_DOCKER_IMAGE .
- echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
- docker push $PROJ_DOCKER_IMAGE
```