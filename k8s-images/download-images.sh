#!/bin/bash
set -e

# List of standard images
IMAGE_TAGS=(
  "registry.k8s.io/kube-apiserver:v1.32.1"
  "registry.k8s.io/kube-controller-manager:v1.32.1"
  "registry.k8s.io/kube-scheduler:v1.32.1"
  "registry.k8s.io/kube-proxy:v1.32.1"
  "registry.k8s.io/coredns/coredns:v1.11.3"
  "registry.k8s.io/pause:3.10"
  "registry.k8s.io/pause:3.9"
  "registry.k8s.io/pause:3.8"  
  "ghcr.io/flannel-io/flannel:v0.26.4"
  "ghcr.io/flannel-io/flannel-cni-plugin:v1.6.2-flannel1"
)

# 1. Download standard images
for IMAGE_TAG in "${IMAGE_TAGS[@]}"; do
  echo "Processing $IMAGE_TAG..."
  docker pull "$IMAGE_TAG"
  
  # Filename logic
  IMAGE_NAME="${IMAGE_TAG%:*}"
  IMAGE_TAG_NAME="${IMAGE_TAG##*:}"
  FILENAME="${IMAGE_NAME##*/}_${IMAGE_TAG_NAME}.tar"
  
  docker save -o "$FILENAME" "$IMAGE_TAG"
  echo "Saved $FILENAME"
done

# 2. SPECIAL HANDLING FOR ETCD (The Fix)
ETCD_TAG="registry.k8s.io/etcd:3.5.24-0"
ETCD_FILE="etcd_3.5.24-0.tar"
FIXED_TAG="etcd-fixed:latest"

echo "Processing ETCD with special handling..."
# Pull specifically for AMD64
docker pull --platform linux/amd64 "$ETCD_TAG"

# Get the actual Image ID (skips the manifest list)
IMAGE_ID=$(docker inspect --format='{{.Id}}' "$ETCD_TAG")
echo "Found ETCD Image ID: $IMAGE_ID"

# Tag that ID explicitly
docker tag "$IMAGE_ID" "$FIXED_TAG"

# Save the FIXED tag
docker save -o "$ETCD_FILE" "$FIXED_TAG"
echo "Saved $ETCD_FILE (Size: $(du -h $ETCD_FILE | cut -f1))"
