#!/bin/bash

################################################################################
# Author: Jonathan Decker (Modified for Pure Join Token Approach)
# Email: jonathan.decker@uni-goettingen.de
# Date: 2025-01-20
# Description: Installation Script for Ephemeral Kubernetes (HA Ready)
# Version: 6.0 (Pure Join Token - No Kubeconfig Distribution)
################################################################################

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

HOSTNAME=$(hostname)

# --- HELPER: ROBUST DNS FIX ---
fix_dns_robust() {
    if [ ! -f /tmp/hosts.fixed ]; then
        cp /etc/hosts /tmp/hosts.fixed
    fi

    if ! grep -q "vip.kubernetes.local" /tmp/hosts.fixed; then
        echo "10.0.0.99 vip.kubernetes.local" >> /tmp/hosts.fixed
    fi

    if ! mountpoint -q /etc/hosts; then
        echo "Applying Bind-Mount protection to /etc/hosts..."
        mount --bind /tmp/hosts.fixed /etc/hosts
    else
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

# --- STEP 2: ROBUST STARTUP ---
mkdir -p /share
mount -t nfs 10.0.0.3:/share /share || true

# Apply DNS Fix immediately
fix_dns_robust

echo "=== DIAGNOSTICS ==="
cat /etc/hosts
ip addr show net0
echo "==================="

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
echo "Loading container images..."
ctr -n k8s.io image import --base-name registry.k8s.io/coredns/coredns:v1.11.3 /share/images/coredns_v1.11.3.tar
ctr -n k8s.io image import /share/images/etcd_3.5.24-0.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-apiserver:v1.32.1 /share/images/kube-apiserver_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-controller-manager:v1.32.1 /share/images/kube-controller-manager_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-proxy:v1.32.1 /share/images/kube-proxy_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-scheduler:v1.32.1 /share/images/kube-scheduler_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.10 /share/images/pause_3.10.tar

# --- FIX: RETAG PAUSE IMAGE (Critical for Kubelet) ---
ctr -n k8s.io image tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1

ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.9 /share/images/pause_3.9.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.8 /share/images/pause_3.8.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel:v0.26.4 /share/images/flannel_v0.26.4.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel-cni-plugin:v1.6.2-flannel1 /share/images/flannel-cni-plugin_v1.6.2-flannel1.tar

LEADER_FILE="/share/leader"
LEADER_READY_FILE="/share/leader_ready"
PHYLACTERY_READY_FILE="/k8s-helper/phylactery_ready"

# --- CHECK IF THIS IS A WORKER NODE ---
if ! hostname | grep -q "control"; then
  echo "Based on hostname this is a worker node"

  # Wait for the leader to create the leader_ready file
  until [ -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader node to be ready"
    sleep 5
  done

  # --- JOIN USING TOKEN (NO KUBECONFIG) ---
  echo "Reading join information from share..."
  
  until [ -f "/share/join-info.sh" ]; do
    sleep 2
    echo "Waiting for join information..."
  done
  
  source /share/join-info.sh
  
  echo "Joining cluster as worker using join token..."
  if $JOIN_TOKEN --v=5; then
      echo "Worker joined successfully."
  else
      echo "Failed to join, cleaning up and retrying..."
      kubeadm reset -f || true
  fi

  echo "Worker done."
  exit 0
fi

echo "Based on hostname this is a control node"

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
  
  # --- BRING UP VIP ON LEADER ---
  echo "Binding VIP 10.0.0.99 to net0..."
  ip addr add 10.0.0.99/24 dev net0 || echo "VIP already exists or failed to add"

  # --- CHECK IF CLUSTER ALREADY EXISTS ---
  if [ -f "/share/cluster_initialized" ]; then
      echo "Cluster already initialized, rejoining as leader..."
      
      # Copy CA certificates from share
      mkdir -p /etc/kubernetes/pki/etcd
      cp /share/pki/ca.crt /etc/kubernetes/pki/ca.crt
      cp /share/pki/ca.key /etc/kubernetes/pki/ca.key
      cp /share/pki/sa.key /etc/kubernetes/pki/sa.key
      cp /share/pki/sa.pub /etc/kubernetes/pki/sa.pub
      cp /share/pki/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
      cp /share/pki/front-proxy-ca.key /etc/kubernetes/pki/front-proxy-ca.key
      cp /share/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/ca.crt
      cp /share/pki/etcd/ca.key /etc/kubernetes/pki/etcd/ca.key
      
      # Re-upload certificates (they expire after 2 hours)
      echo "Re-uploading certificates for rejoining nodes..."
      CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
      
      # Update join-info.sh with new certificate key
      source /share/join-info.sh
      cat > /share/join-info.sh <<EOF
#!/bin/bash
JOIN_TOKEN="$JOIN_TOKEN"
CERT_KEY="$CERT_KEY"
EOF
      echo "✓ Certificate key refreshed"
      
      # Join the cluster
      source /share/join-info.sh
      if $JOIN_TOKEN --control-plane --certificate-key "$CERT_KEY" --v=5; then
          echo "✓ Leader rejoined cluster successfully"
      else
          echo "Failed to rejoin, cleaning up..."
          kubeadm reset -f || true
          rm -rf /etc/kubernetes/pki
      fi
      
      # Re-apply VIP (might have been lost)
      ip addr add 10.0.0.99/24 dev net0 || echo "VIP already exists"
      
      touch "$LEADER_READY_FILE"
      echo "Leader rejoin complete."
      exit 0
  fi

  # --- INITIALIZE NEW CLUSTER ---
  echo "Initializing Kubernetes cluster..."
  kubeadm init --control-plane-endpoint "vip.kubernetes.local:8443" --upload-certs --kubernetes-version v1.32.1 --pod-network-cidr=10.244.0.0/16

  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  
  # --- CREATE PERMANENT JOIN TOKEN ---
  echo "Creating permanent join token for nodes..."
  
  # Create a token that never expires (ttl=0)
  JOIN_TOKEN=$(kubeadm token create --ttl 0 --print-join-command)
  
  # Get the certificate key for control plane join
  CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
  
  # Save join information to share
  cat > /share/join-info.sh <<EOF
#!/bin/bash
# Auto-generated join information
# This token allows joining the cluster but provides NO other access
JOIN_TOKEN="$JOIN_TOKEN"
CERT_KEY="$CERT_KEY"
EOF
  
  chmod 644 /share/join-info.sh
  echo "✓ Join token saved to /share/join-info.sh"
  
  # --- COPY CA CERTIFICATES TO SHARE ---
  echo "Copying CA certificates to share for control plane nodes..."
  mkdir -p /share/pki/etcd
  cp /etc/kubernetes/pki/ca.crt /share/pki/ca.crt
  cp /etc/kubernetes/pki/ca.key /share/pki/ca.key
  cp /etc/kubernetes/pki/sa.key /share/pki/sa.key
  cp /etc/kubernetes/pki/sa.pub /share/pki/sa.pub
  cp /etc/kubernetes/pki/front-proxy-ca.crt /share/pki/front-proxy-ca.crt
  cp /etc/kubernetes/pki/front-proxy-ca.key /share/pki/front-proxy-ca.key
  cp /etc/kubernetes/pki/etcd/ca.crt /share/pki/etcd/ca.crt
  cp /etc/kubernetes/pki/etcd/ca.key /share/pki/etcd/ca.key
  chmod 644 /share/pki/*.crt /share/pki/*.key /share/pki/*.pub /share/pki/etcd/*.crt /share/pki/etcd/*.key
  echo "✓ CA certificates copied to share"
  
  # Save admin kubeconfig for phylactery.py and cluster management
  # NOTE: This is NOT used for joining - only for cluster management and phylactery
  cp /etc/kubernetes/admin.conf /share/kube.config
  chmod 644 /share/kube.config
  echo "✓ Admin kubeconfig saved to /share/kube.config (for phylactery and management only)"
  
  # Mark cluster as initialized
  touch /share/cluster_initialized

  # Apply Flannel
  echo "Applying Flannel CNI..."
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /k8s-helper/kube-flannel.yml
  
  # Fix Flannel interface
  echo "Patching Flannel to use net0 interface..."
  kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-flannel patch ds kube-flannel-ds --type json -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--iface=net0"}]'

  # Signal followers
  touch "$LEADER_READY_FILE"
  echo "Leader initialization complete."

else
  echo "I am a follower control node ($HOSTNAME)"
  
  # Wait for leader
  until [ -f "$LEADER_READY_FILE" ]; do
    sleep 5
    echo "Waiting for leader..."
  done

  # --- JOIN USING TOKEN (NO KUBECONFIG) ---
  echo "Reading join information from share..."
  
  until [ -f "/share/join-info.sh" ]; do
    sleep 2
    echo "Waiting for join information..."
  done
  
  source /share/join-info.sh
  echo "Join token loaded successfully"
  
  # Copy CA certificates (required for control plane join)
  echo "Copying CA certificates from share..."
  mkdir -p /etc/kubernetes/pki/etcd
  
  until [ -f "/share/pki/ca.crt" ]; do
    sleep 2
    echo "Waiting for CA certificates..."
  done
  
  cp /share/pki/ca.crt /etc/kubernetes/pki/ca.crt
  cp /share/pki/ca.key /etc/kubernetes/pki/ca.key
  cp /share/pki/sa.key /etc/kubernetes/pki/sa.key
  cp /share/pki/sa.pub /etc/kubernetes/pki/sa.pub
  cp /share/pki/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
  cp /share/pki/front-proxy-ca.key /etc/kubernetes/pki/front-proxy-ca.key
  cp /share/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/ca.crt
  cp /share/pki/etcd/ca.key /etc/kubernetes/pki/etcd/ca.key
  
  echo "✓ CA certificates copied"
  
  # --- HANDLE CERTIFICATE KEY EXPIRATION ---
  # If certificate key is expired, wait for leader to refresh it
  MAX_JOIN_ATTEMPTS=3
  ATTEMPT=0
  
  while [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ]; do
      ATTEMPT=$((ATTEMPT + 1))
      echo "Join attempt $ATTEMPT/$MAX_JOIN_ATTEMPTS..."
      
      # Reload join info (in case leader updated it)
      source /share/join-info.sh
      
      if $JOIN_TOKEN --control-plane --certificate-key "$CERT_KEY" --v=5; then
          echo "✓ Successfully joined cluster using join token"
          echo "Follower control node done."
          exit 0
      else
          echo "Join attempt $ATTEMPT failed."
          
          if [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ]; then
              echo "Certificate key might be expired. Waiting for leader to refresh..."
              sleep 30
          fi
      fi
  done
  
  echo "ERROR: Failed to join after $MAX_JOIN_ATTEMPTS attempts"
  echo "Cleaning up..."
  kubeadm reset -f || true
  rm -rf /etc/kubernetes/pki
  exit 1
fi
