#!/bin/bash

################################################################################
# Author: Jonathan Decker
# Email: jonathan.decker@uni-goettingen.de
# Date: 2025-02-11
# Description: Installation Script for Ephemeral Kubernetes (HA Ready)
# Version: 4.0 (Secure Upload & No-Expire Token)
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
WW_HOST="10.0.0.3"
USE_SECURE_MODE="${USE_SECURE_MODE:-true}"

# --- STEP 2: ROBUST STARTUP ---
mkdir -p /share
mount -t nfs 10.0.0.3:/share /share || true

# Apply DNS Fix immediately
fix_dns_robust

echo "=== DIAGNOSTICS ==="
cat /etc/hosts
ip addr show net0
echo "==================="

# Try to find the node-specific token first
# (Used for both Followers to download AND Leader to upload)
TOKEN=$(cat /etc/k8s-token* 2>/dev/null | head -n 1 || echo "")
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

# Wait for Phylactery Service to be ready (It fixes cluster membership)
echo "Waiting for phylactery service to be ready..."
until [ -f "$PHYLACTERY_READY_FILE" ]; do
  sleep 5
  echo "Waiting for phylactery service to be ready"
done
echo "Phylactery service is ready."

# --- LEADER ELECTION ---
if [ ! -f "$LEADER_FILE" ]; then
  echo "$HOSTNAME" > "$LEADER_FILE"
fi

LEADER=$(cat "$LEADER_FILE")

if [ "$HOSTNAME" == "$LEADER" ]; then
  echo "I am the leader ($HOSTNAME)"
  
  # --- CRITICAL FIX: BRING UP VIP ON LEADER ---
  # We must bind the VIP 10.0.0.99 to the interface so the cluster has a valid endpoint.
  echo "Binding VIP 10.0.0.99 to net0..."
  ip addr add 10.0.0.99/24 dev net0 || echo "VIP already exists or failed to add"
  # --------------------------------------------

  # Initialize Cluster
  kubeadm init --control-plane-endpoint "vip.kubernetes.local:8443" --upload-certs --kubernetes-version v1.32.1 --pod-network-cidr=10.244.0.0/16

  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  
  # --- SECURE MODE: UPLOAD ONLY CA KEYS ---
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
      # Insecure Fallback (Not recommended)
      cp /etc/kubernetes/admin.conf /share/kube.config
      chmod 644 /share/kube.config
  fi

  # Apply Flannel
  echo "Applying Flannel..."
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /k8s-helper/kube-flannel.yml
  
  # --- FIX FLANNEL INTERFACE ---
  # Flannel crashes if it binds to eth0 when we use net0. We patch it here.
  kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-flannel patch ds kube-flannel-ds --type json -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--iface=net0"}]'

  # Signal followers
  touch "$LEADER_READY_FILE"
  echo "Leader done."

else
  echo "I am a follower ($HOSTNAME)"
  
  # Wait for leader
  until [ -f "$LEADER_READY_FILE" ]; do
    sleep 5
    echo "Waiting for leader..."
  done

  # --- SECURE MODE: DOWNLOAD & JOIN ---
  if [[ "$USE_SECURE_MODE" == "true" ]]; then
      if [ -z "$TOKEN" ]; then
          echo "Error: No token found for secure join."
          exit 1
      fi

      echo "Downloading configuration from secure server..."
      mkdir -p /root/.kube
      # Try to download config.
      if ! curl -f -s "http://$WW_HOST:8000/config/$TOKEN" -o /root/.kube/config; then
          echo "Failed to download config. Token may be expired or invalid."
          exit 1
      fi

      echo "Downloading certificates from secure server..."
      mkdir -p /etc/kubernetes/pki
      if curl -f -s "http://$WW_HOST:8000/certs/$TOKEN" -o /tmp/pki.tar.gz; then
          # Extract safely
          tar -xzf /tmp/pki.tar.gz -C /etc/kubernetes/pki/
          
          # Clean up any potential node-specific certs just in case
          rm -f /etc/kubernetes/pki/apiserver* rm -f /etc/kubernetes/pki/front-proxy-client*
          rm -f /etc/kubernetes/pki/etcd/peer* rm -f /etc/kubernetes/pki/etcd/server*
          rm -f /etc/kubernetes/pki/etcd/healthcheck-client*
      else
          echo "Failed to download certificates."
          exit 1
      fi
  else
      # Insecure Fallback
      mkdir -p /root/.kube
      cp /share/kube.config /root/.kube/config
  fi

  # Join the cluster
  echo "Joining cluster..."
  if kubeadm join --discovery-file /root/.kube/config --control-plane; then
      echo "Joined successfully."
      
      # Token Expiry has been DISABLED as requested.
      # Tokens can now be reused if the node reboots.
      
      echo "Follower done."
  else
      echo "Failed to join, cleaning up and then trying again"
      kubeadm reset -f || true
      rm -rf /etc/kubernetes/pki
      rm -f /root/.kube/config
  fi
fi
