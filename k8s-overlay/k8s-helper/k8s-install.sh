#!/bin/bash

################################################################################
# Author: Jonathan Decker
# Email: jonathan.decker@uni-goettingen.de
# Date: 2025-02-11
# Description: Installation Script for Ephemeral Kubernetes
# Version: 1.0
################################################################################

set -xeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

HOSTNAME=$(hostname)
IP_ADDRESS=$(ip addr show dev net0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

# Add a default route to cluster manager if not set already
ip route add default via "$IP_ADDRESS" || true

# Enable required kernel modules
echo "overlay\nbr_netfilter\nip_tables" > /etc/modules-load.d/containerd.conf

# Enable sysctl settings required for Kubernetes
echo 'net.bridge.bridge-nf-call-iptables = 1' > /etc/sysctl.d/k8s.conf 
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/k8s.conf 
echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.d/k8s.conf
echo 'net.ipv4.conf.all.forwarding = 1' >> /etc/sysctl.d/k8s.conf
echo 'net.ipv4.ip_nonlocal_bind = 1' >> /etc/sysctl.d/k8s.conf

# Load the settings
sysctl -p /etc/sysctl.d

# Ensure the kernel modules are loaded
modprobe overlay
modprobe br_netfilter
modprobe ip_tables

# Refresh the settings
sysctl --system

# Verify that it worked
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "0" ]; then
  echo "Failed to enable IP forwarding."
  exit
fi

systemctl enable --now containerd
systemctl enable --now kubelet

# Check if /share is ready and wait for it if needed
for i in {1..60}; do
  if mountpoint -q "/share"; then
    echo "Mount is active"
    break
  fi
  sleep 1
done

# Load base Kubernetes images for 1.32.1 installation
ctr -n k8s.io image import --base-name registry.k8s.io/coredns/coredns:v1.11.3 /share/images/coredns_v1.11.3.tar
ctr -n k8s.io image import /share/images/etcd_3.5.24-0.tar
ctr -n k8s.io image tag docker.io/library/etcd-fixed:latest registry.k8s.io/etcd:3.5.24-0
ctr -n k8s.io image import --base-name registry.k8s.io/kube-apiserver:v1.32.1 /share/images/kube-apiserver_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-controller-manager:v1.32.1 /share/images/kube-controller-manager_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-proxy:v1.32.1 /share/images/kube-proxy_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-scheduler:v1.32.1 /share/images/kube-scheduler_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.10 /share/images/pause_3.10.tar
ctr -n k8s.io image tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.9 /share/images/pause_3.9.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.8 /share/images/pause_3.8.tar

# Load images for Flannel CNI
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel:v0.26.4 /share/images/flannel_v0.26.4.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel-cni-plugin:v1.6.2-flannel1 /share/images/flannel-cni-plugin_v1.6.2-flannel1.tar

LEADER_FILE="/share/leader"
LEADER_READY_FILE="/share/leader_ready"

PHYLACTERY_READY_FILE="/k8s-helper/phylactery_ready"

# Check if there is already a working cluster
## TODO

# Check if the node is a worker
if ! hostname | grep -q "control"; then
  echo "Based on hostname this is a worker"

  # Wait for the leader to create the leader_ready file
  while [ ! -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader node to be ready"
    sleep 5
  done

  # Ensure worker is not already in the cluster and if so remove it
  node_data=$(kubectl --kubeconfig /share/kube.config get nodes -o json)
  node_names=$(jq -r '.items[] | .metadata.name' <<< "$node_data")
  if echo "$node_names" | grep -q "$(hostname)"; then
    echo "Removing previous self from cluster before joining"
    kubectl --kubeconfig /share/kube.config drain "$(hostname)" --delete-emptydir-data --force --ignore-daemonsets
    kubectl --kubeconfig /share/kube.config delete node "$(hostname)"
  fi

  if ! kubeadm join --discovery-file /share/kube.config --v=5; then
    echo "Failed to join, cleaning up and then trying again"
    kubeadm reset -f
  fi

  echo "Worker done."
  exit 0
fi

echo "Based on hostname this is a control node"


# Determine the leader to initialize the cluster via the first person to claim leader ship
if ! (set -o noclobber; echo $(hostname) > "$LEADER_FILE"); then
  # If the leader file cannot be created, follow the leader node
  echo "Acknowledged $(cat $LEADER_FILE) as leader."

  # Wait for the leader to create the leader_ready file
  while [ ! -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader node to be ready"
    sleep 5
  done

  mkdir -p /etc/kubernetes/pki/etcd
  cp /share/pki/ca.crt /etc/kubernetes/pki/ca.crt
  cp /share/pki/ca.key /etc/kubernetes/pki/ca.key
  cp /share/pki/sa.key /etc/kubernetes/pki/sa.key
  cp /share/pki/sa.pub /etc/kubernetes/pki/sa.pub
  cp /share/pki/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
  cp /share/pki/front-proxy-ca.key /etc/kubernetes/pki/front-proxy-ca.key
  cp /share/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/ca.crt
  cp /share/pki/etcd/ca.key /etc/kubernetes/pki/etcd/ca.key

  # Phylactery service setup, this also starts haproxy
  systemctl start phylactery.service

  systemctl start keepalived

  # Setup kubectl access
  mkdir -p /root/.kube
  cp /share/kube.config /root/.kube/config

  # Wait for the phylactery to create the leader_ready file
  while [ ! -f "$PHYLACTERY_READY_FILE" ]; do
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

mkdir -p /share/phylactery
mkdir -p /share/pki/etcd
cp /k8s-helper/haproxy.cfg /share/phylactery/haproxy.cfg
cp /k8s-helper/haproxy.cfg.base /share/phylactery/haproxy.cfg.base

systemctl start phylactery.service

#systemctl start haproxy
systemctl start keepalived

# Wait for the phylactery to create the leader_ready file
while [ ! -f "$PHYLACTERY_READY_FILE" ]; do
  echo "Waiting for phylactery service to be ready"
  sleep 5
done

# Initialize master node
# Initialize master node with the config

# Create a Kubelet configuration patch to disable disk checks for tmpfs
# Create a Kubelet configuration patch to disable disk checks for tmpfs
# AND include the cluster configuration settings
cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  ignorePreflightErrors:
  - FileAvailable--etc-kubernetes-manifests-kube-apiserver.yaml
  - FileAvailable--etc-kubernetes-manifests-kube-controller-manager.yaml
  - FileAvailable--etc-kubernetes-manifests-kube-scheduler.yaml
  - FileAvailable--etc-kubernetes-manifests-etcd.yaml
  - Port-10250
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
evictionHard:
  nodefs.available: "0%"
  nodefs.inodesFree: "0%"
  imagefs.available: "0%"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.32.1
controlPlaneEndpoint: "vip.kubernetes.local:8443"
networking:
  podSubnet: "10.249.0.0/16"
apiServer:
  certSANs:
  - "10.0.0.15"
EOF




# Initialize master node with the config
kubeadm init --config /root/kubeadm-config.yaml

# Setup kubectl access
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
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

# Setup CNI
kubectl apply -f /k8s-helper/kube-flannel.yml

# Wait for etcd to create the server certs
while [ ! -f "/etc/kubernetes/pki/etcd/server.crt" ]; do
  echo "Waiting for etcd servere to be ready"
  sleep 5
done

cp /etc/kubernetes/pki/etcd/server.key /share/pki/etcd/server.key
cp /etc/kubernetes/pki/etcd/server.crt /share/pki/etcd/server.crt

touch "$LEADER_READY_FILE"

echo "Leader done."
