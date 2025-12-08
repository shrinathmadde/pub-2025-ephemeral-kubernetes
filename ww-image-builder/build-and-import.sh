#!/bin/bash

set -ex

docker buildx build --network=host --no-cache -t k8s-base-ww -f Dockerfile.base .
docker buildx build --network=host --no-cache -t k8s-control-ww -f Dockerfile.control .
docker save k8s-base-ww -o k8s-base-ww.tar
docker save k8s-control-ww -o k8s-control-ww.tar
wwctl container import --force file://k8s-base-ww.tar k8s-base-ww
wwctl container import --force file://k8s-control-ww.tar k8s-control-ww
wwctl container build k8s-base-ww
wwctl container build k8s-control-ww
