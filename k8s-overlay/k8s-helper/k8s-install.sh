#!/bin/bash

################################################################################
# Author: Jonathan Decker
# Email: jonathan.decker@uni-goettingen.de
# Date: 2025-02-11
# Description: Installation Script for Ephemeral Kubernetes (HA Ready)
# Version: 4.2 (Script 2 Flow + Secure Upload & HPC Fixes)
################################################################################

# Disable strict mode to prevent crashes during network polling
# set -xeuo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

HOSTNAME=$(hostname)

# --- HELPER: ROBUST DNS FIX ---
fix_dns_robust() {
    # 1. Create a safe copy of the current hosts file
    if [ ! -f /tmp/hosts.fixed ]; then
        cp /etc/hosts /tmp/hosts.fixed
    fi

    # 2. Add the VIP if missing
    if ! grep -q "vip.kubernetes.local" /tmp/hosts.fixed; then
        echo "10.0.0.99 vip.kubernetes.local" >> /tmp/hosts.fixed
    fi

    # 3. Mount our fixed file OVER /etc/hosts
    if ! mountpoint -q /etc/hosts; then
        echo "Applying Bind-Mount protection to /etc/hosts..."
        mount --bind /tmp/hosts.fixed /etc/hosts
    else
        # If already mounted, just update the backing file
        if ! grep -q "vip.kubernetes.local" /tmp/hosts.fixed; then
             echo "10.0.0.99 vip.kubernetes.local" >> /tmp/hosts.fixed
             mount -o remount /etc/hosts
        fi
    fi
}

# --- STEP 1: WAIT FOR NETWORK ---
echo "Waiting for network..."
until ip addr show dev net0 | grep -q "inet"; do
  sleep 1
done

IP_ADDRESS=$(ip addr show dev net0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

# Security configuration
WW_HOST="10.0.0.7"
USE_SECURE_MODE="${USE_SECURE_MODE:-true}"

# --- STEP 2: ROBUST STARTUP ---
mkdir -p /share
mount -t nfs 10.0.0.7:/share /share || true

# Apply DNS Fix immediately
fix_dns_robust

echo "=== DIAGNOSTICS ==="
cat /etc/hosts
ip addr show net0
echo "==================="

# Try to find the node-specific token first
# (Used for both Followers to download AND Leader to upload)
TOKEN=$(cat /etc/k8s-token.${HOSTNAME} 2>/dev/null || echo "")
SECURE_FILES="/share/secure-files"

# Add a default route to cluster manager if not set already
ip route add default via "$IP_ADDRESS" || true

# Enable required kernel modules
cat <<MOD > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
ip_tables
MOD

# Enable sysctl settings required for Kubernetes
cat <<SYS > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.ip_nonlocal_bind = 1
SYS

# Load the settings
sysctl --system
modprobe overlay
modprobe br_netfilter
modprobe ip_tables

systemctl enable --now containerd
systemctl enable --now kubelet

# Check if /share is ready
for i in {1..60}; do
  if mountpoint -q "/share"; then
    echo "Mount is active"
    break
  fi
  sleep 1
done

# --- IMAGE PRE-LOADING ---
ctr -n k8s.io image import --base-name registry.k8s.io/coredns/coredns:v1.11.3 /share/images/coredns_v1.11.3.tar
ctr -n k8s.io image import /share/images/etcd_3.5.24-0.tar
ETCD_IMG=$(ctr -n k8s.io images ls | grep etcd | head -n 1 | awk '{print $1}')
ctr -n k8s.io image tag $ETCD_IMG registry.k8s.io/etcd:3.5.24-0
ctr -n k8s.io image import --base-name registry.k8s.io/kube-apiserver:v1.32.1 /share/images/kube-apiserver_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-controller-manager:v1.32.1 /share/images/kube-controller-manager_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-proxy:v1.32.1 /share/images/kube-proxy_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-scheduler:v1.32.1 /share/images/kube-scheduler_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.10 /share/images/pause_3.10.tar

# --- FIX: RETAG PAUSE IMAGE (Critical for Kubelet) ---
ctr -n k8s.io image tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1
# -----------------------------------------------------

ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.9 /share/images/pause_3.9.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.8 /share/images/pause_3.8.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel:v0.26.4 /share/images/flannel_v0.26.4.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel-cni-plugin:v1.6.2-flannel1 /share/images/flannel-cni-plugin_v1.6.2-flannel1.tar

LEADER_FILE="/share/leader"
LEADER_READY_FILE="/share/leader_ready"
PHYLACTERY_READY_FILE="/k8s-helper/phylactery_ready"

# Check if there is already a working cluster
## TODO

# --- CHECK IF THIS IS A WORKER NODE ---
if ! hostname | grep -q "control"; then
  echo "Based on hostname this is a worker"

  # Wait for the leader to create the leader_ready file
  until [ -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader node to be ready"
    sleep 5
  done

  # --- SECURE MODE: DOWNLOAD CONFIG FOR WORKER ---
  if [[ "$USE_SECURE_MODE" == "true" ]]; then
      if [ -z "$TOKEN" ]; then
          echo "Error: No token found for secure join."
          exit 1
      fi

      echo "Downloading configuration from secure server..."
      mkdir -p /root/.kube
      # Try to download config
      if ! curl -f -s "http://$WW_HOST:8000/config/$TOKEN" -o /root/.kube/config; then
          echo "Failed to download config. Token may be expired or invalid."
          exit 1
      fi
  else
      # Insecure Fallback
      mkdir -p /root/.kube
      cp /share/kube.config /root/.kube/config
  fi

  # Ensure worker is not already in the cluster and if so remove it
  node_data=$(kubectl --kubeconfig /root/.kube/config get nodes -o json)
  node_names=$(jq -r '.items[] | .metadata.name' <<< "$node_data")
  if echo "$node_names" | grep -q "$(hostname)"; then
    echo "Removing previous self from cluster before joining"
    kubectl --kubeconfig /root/.kube/config drain "$(hostname)" --delete-emptydir-data --force --ignore-daemonsets
    kubectl --kubeconfig /root/.kube/config delete node "$(hostname)"
  fi

  if ! kubeadm join --discovery-file /root/.kube/config --v=5; then
    echo "Failed to join, cleaning up and then trying again"
    kubeadm reset -f
  fi

  echo "Worker done."
  exit 0
fi

echo "Based on hostname this is a control node"

# --- LEADER ELECTION (Before Phylactery) ---
# Determine the leader to initialize the cluster via the first person to claim leadership
if ! (set -o noclobber; echo $(hostname) > "$LEADER_FILE"); then
  # If the leader file cannot be created, follow the leader node
  echo "Acknowledged $(cat $LEADER_FILE) as leader."

  # Wait for the leader to create the leader_ready file
  until [ -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader node to be ready"
    sleep 5
  done

  # --- SECURE MODE: DOWNLOAD CERTS FOR FOLLOWER ---
  if [[ "$USE_SECURE_MODE" == "true" ]]; then
      if [ -z "$TOKEN" ]; then
          echo "Error: No token found for secure join."
          exit 1
      fi

      echo "Downloading certificates from secure server..."
      mkdir -p /etc/kubernetes/pki/etcd
      if curl -f -s "http://$WW_HOST:8000/certs/$TOKEN" -o /tmp/pki.tar.gz; then
          # Extract safely
          tar -xzf /tmp/pki.tar.gz -C /etc/kubernetes/pki/
          
          # Clean up any potential node-specific certs just in case
          rm -f /etc/kubernetes/pki/apiserver*
          rm -f /etc/kubernetes/pki/front-proxy-client*
          rm -f /etc/kubernetes/pki/etcd/peer*
          rm -f /etc/kubernetes/pki/etcd/server*
          rm -f /etc/kubernetes/pki/etcd/healthcheck-client*
      else
          echo "Failed to download certificates."
          exit 1
      fi
  else
      # Insecure Fallback - Copy from /share
      mkdir -p /etc/kubernetes/pki/etcd
      cp /share/pki/ca.crt /etc/kubernetes/pki/ca.crt
      cp /share/pki/ca.key /etc/kubernetes/pki/ca.key
      cp /share/pki/sa.key /etc/kubernetes/pki/sa.key
      cp /share/pki/sa.pub /etc/kubernetes/pki/sa.pub
      cp /share/pki/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
      cp /share/pki/front-proxy-ca.key /etc/kubernetes/pki/front-proxy-ca.key
      cp /share/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/ca.crt
      cp /share/pki/etcd/ca.key /etc/kubernetes/pki/etcd/ca.key
  fi

  # Phylactery service setup, this also starts haproxy
  systemctl start phylactery.service

  systemctl start keepalived

  # --- SECURE MODE: DOWNLOAD CONFIG FOR FOLLOWER ---
  if [[ "$USE_SECURE_MODE" == "true" ]]; then
      echo "Downloading configuration from secure server..."
      mkdir -p /root/.kube
      if ! curl -f -s "http://$WW_HOST:8000/config/$TOKEN" -o /root/.kube/config; then
          echo "Failed to download config. Token may be expired or invalid."
          exit 1
      fi
  else
      # Setup kubectl access
      mkdir -p /root/.kube
      cp /share/kube.config /root/.kube/config
  fi

  # Wait for the phylactery to create the phylactery_ready file
  until [ -f "$PHYLACTERY_READY_FILE" ]; do
    echo "Waiting for phylactery service to be ready"
    sleep 5
  done

  if ! kubeadm join --discovery-file /root/.kube/config --control-plane --v=5; then
    echo "Failed to join, cleaning up and then trying again"
    kubeadm reset -f
  fi

  echo "Follower done."
  exit 0
fi

# --- LEADER INITIALIZATION ---
echo "I am the leader ($HOSTNAME)"

# Setup phylactery directories
mkdir -p /share/phylactery
mkdir -p /share/pki/etcd
cp /k8s-helper/haproxy.cfg /share/phylactery/haproxy.cfg
cp /k8s-helper/haproxy.cfg.base /share/phylactery/haproxy.cfg.base

systemctl start phylactery.service

#systemctl start haproxy
systemctl start keepalived

# Wait for the phylactery to create the phylactery_ready file
until [ -f "$PHYLACTERY_READY_FILE" ]; do
  echo "Waiting for phylactery service to be ready"
  sleep 5
done

# Initialize master node
kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=v1.32.1 --v=5 \
  --control-plane-endpoint vip.kubernetes.local:8443 --upload-certs

# Setup kubectl access
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

# --- SECURE MODE: UPLOAD KEYS AND CONFIG ---
if [[ "$USE_SECURE_MODE" == "true" ]]; then
    echo "Uploading certificates to secure file server (CA ONLY)"
    
    # 1. Create Tarball (CA Keys Only)
    cd /etc/kubernetes/pki
    tar -czf /tmp/pki.tar.gz \
        ca.crt ca.key sa.key sa.pub \
        front-proxy-ca.crt front-proxy-ca.key \
        etcd/ca.crt etcd/ca.key
    
    # 2. Upload to Secure Server via POST (No more NFS copying!)
    echo "Uploading secrets via API Push..."
    
    # Upload Config
    curl -X POST --fail --data-binary @/etc/kubernetes/admin.conf \
         "http://$WW_HOST:8000/upload/kube.config/$TOKEN" || echo "ERROR: Failed to upload kube.config"

    # Upload PKI Keys
    curl -X POST --fail --data-binary @/tmp/pki.tar.gz \
         "http://$WW_HOST:8000/upload/pki.tar.gz/$TOKEN" || echo "ERROR: Failed to upload pki.tar.gz"

    # Cleanup temp file
    rm -f /tmp/pki.tar.gz

else
    # Insecure Fallback (Not recommended) - Upload to /share
    cp /root/.kube/config /share/kube.config

    # Upload pki files to shared folder
    cp /etc/kubernetes/pki/ca.crt /share/pki/ca.crt
    cp /etc/kubernetes/pki/ca.key /share/pki/ca.key
    cp /etc/kubernetes/pki/sa.key /share/pki/sa.key
    cp /etc/kubernetes/pki/sa.pub /share/pki/sa.pub
    cp /etc/kubernetes/pki/front-proxy-ca.crt /share/pki/front-proxy-ca.crt
    cp /etc/kubernetes/pki/front-proxy-ca.key /share/pki/front-proxy-ca.key
    cp /etc/kubernetes/pki/etcd/ca.crt /share/pki/etcd/ca.crt
    cp /etc/kubernetes/pki/etcd/ca.key /share/pki/etcd/ca.key
fi

# Setup CNI
kubectl apply -f /k8s-helper/kube-flannel.yml

# --- FIX FLANNEL INTERFACE ---
# Flannel crashes if it binds to eth0 when we use net0. We patch it here.
kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-flannel patch ds kube-flannel-ds --type json -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--iface=net0"}]'

# Wait for etcd to create the server certs (Script 2 compatibility)
until [ -f "/etc/kubernetes/pki/etcd/server.crt" ]; do
  echo "Waiting for etcd server to be ready"
  sleep 5
done

# Upload etcd server certs if needed (Script 2 compatibility)
if [[ "$USE_SECURE_MODE" != "true" ]]; then
    cp /etc/kubernetes/pki/etcd/server.key /share/pki/etcd/server.key
    cp /etc/kubernetes/pki/etcd/server.crt /share/pki/etcd/server.crt
fi

touch "$LEADER_READY_FILE"

echo "Leader done."
