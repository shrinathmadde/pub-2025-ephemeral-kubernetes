#!/bin/bash

################################################################################
# Author: Jonathan Decker / Shrinath Madde
# Description: Ephemeral Kubernetes Install — Unified Multi-Approach Security
# Version: 8.0 (Three Security Approaches in One File)
#
# ============================================================================
# SECURITY_MODE selector — set this variable to choose the credential model:
#
#   APPROACH_1 = NFS-SIMPLE
#     All credentials (kube.config, all PKI private keys) are written directly
#     to /share. Simple to deploy; maximum credential exposure. Original design.
#     /share/kube.config         Full cluster-admin kubeconfig
#     /share/pki.tar.gz          Complete PKI including all private keys
#     /share/join-command.txt    kubeadm join command (bootstrap token)
#
#   APPROACH_2 = SECURE-SERVER
#     Per-node SHA-256 keys distributed via Warewulf overlay authenticate
#     against a Flask server on the cluster manager (10.0.0.3:8000).
#     Sensitive credentials live in /var/lib/warewulf/private-secrets on the
#     manager and are never written to /share.  After a node successfully joins
#     it deletes its key (/etc/k8s-token.<HOSTNAME>), closing the auth window.
#     /share/join-command.txt    Bootstrap token only (minimal scope)
#     Secure server:             kube.config + pki.tar.gz (CA certs/keys only)
#
#   APPROACH_3 = TOKEN-RBAC  [default]
#     Least-privilege NFS credentials.  Raw PKI private keys never touch /share;
#     kubeadm stores them encrypted inside etcd.
#     /share/join-command.txt        Bootstrap token — node joining only
#     /share/certificate-key.txt     Decrypts kubeadm PKI bundle from API server
#     /share/phylactery-kubeconfig   SA kubeconfig — node lifecycle ops only
# ============================================================================
################################################################################

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

HOSTNAME=$(hostname)

# ============================================================================
# SECURITY MODE — change this one variable to switch between approaches
# ============================================================================
SECURITY_MODE="${SECURITY_MODE:-APPROACH_3}"
echo "=== Security Mode: $SECURITY_MODE ==="

# Write security mode to file so phylactery.py can read it
mkdir -p /k8s-helper
echo "$SECURITY_MODE" > /k8s-helper/security_mode

# APPROACH_2: node key delivered by Warewulf overlay.
# generate-tokens.sh writes the key to k8s-token.<NODE> in the overlay,
# so it lands on the node at /etc/k8s-token.<HOSTNAME>.
SECURE_SERVER="http://10.0.0.3:8000"
NODE_KEY_FILE="/etc/k8s-token.${HOSTNAME}"

# ---------------------------------------------------------------------------
# HELPER: ROBUST DNS FIX
# ---------------------------------------------------------------------------
fix_dns_robust() {
    if [ ! -f /tmp/hosts.fixed ]; then
        cp /etc/hosts /tmp/hosts.fixed
    fi
    if ! grep -q "vip.kubernetes.local" /tmp/hosts.fixed; then
        echo "10.0.0.99 vip.kubernetes.local" >> /tmp/hosts.fixed
    fi
    if ! mountpoint -q /etc/hosts; then
        echo "Applying bind-mount protection to /etc/hosts..."
        mount --bind /tmp/hosts.fixed /etc/hosts
    else
        if ! grep -q "vip.kubernetes.local" /tmp/hosts.fixed; then
            echo "10.0.0.99 vip.kubernetes.local" >> /tmp/hosts.fixed
            mount -o remount /etc/hosts
        fi
    fi
}

# ---------------------------------------------------------------------------
# STEP 1: WAIT FOR NETWORK
# ---------------------------------------------------------------------------
echo "Waiting for network..."
until ip addr show dev net0 | grep -q "inet"; do
  sleep 1
done

IP_ADDRESS=$(ip addr show dev net0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

# ---------------------------------------------------------------------------
# STEP 2: MOUNT NFS & DNS
# ---------------------------------------------------------------------------
mkdir -p /share
mount -t nfs 10.0.0.3:/share /share || true

fix_dns_robust

echo "=== DIAGNOSTICS ==="
cat /etc/hosts
ip addr show net0
echo "==================="

ip route add default via "$IP_ADDRESS" || true

# ---------------------------------------------------------------------------
# STEP 3: KERNEL MODULES & SYSCTL
# ---------------------------------------------------------------------------
cat <<MOD > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
ip_tables
MOD

cat <<SYS > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.ip_nonlocal_bind = 1
SYS

sysctl --system
modprobe overlay
modprobe br_netfilter
modprobe ip_tables

systemctl enable --now containerd
systemctl enable --now kubelet

# Wait for NFS mount
for i in {1..60}; do
  if mountpoint -q "/share"; then
    echo "NFS mount is active"
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# STEP 4: IMAGE PRE-LOADING
# ---------------------------------------------------------------------------
echo "Loading container images..."
ctr -n k8s.io image import --base-name registry.k8s.io/coredns/coredns:v1.11.3 /share/images/coredns_v1.11.3.tar
ctr -n k8s.io image import /share/images/etcd_3.5.24-0.tar
ETCD_IMG=$(ctr -n k8s.io images ls | grep etcd | head -n 1 | awk '{print $1}')
ctr -n k8s.io image tag "$ETCD_IMG" registry.k8s.io/etcd:3.5.24-0
ctr -n k8s.io image import --base-name registry.k8s.io/kube-apiserver:v1.32.1 /share/images/kube-apiserver_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-controller-manager:v1.32.1 /share/images/kube-controller-manager_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-proxy:v1.32.1 /share/images/kube-proxy_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/kube-scheduler:v1.32.1 /share/images/kube-scheduler_v1.32.1.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.10 /share/images/pause_3.10.tar
ctr -n k8s.io image tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.9 /share/images/pause_3.9.tar
ctr -n k8s.io image import --base-name registry.k8s.io/pause:3.8 /share/images/pause_3.8.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel:v0.26.4 /share/images/flannel_v0.26.4.tar
ctr -n k8s.io image import --base-name ghcr.io/flannel-io/flannel-cni-plugin:v1.6.2-flannel1 /share/images/flannel-cni-plugin_v1.6.2-flannel1.tar

# ---------------------------------------------------------------------------
# SHARED FILE PATHS (used by all approaches for leader election and discovery)
# ---------------------------------------------------------------------------
LEADER_FILE="/share/leader"
LEADER_READY_FILE="/share/leader_ready"
PHYLACTERY_READY_FILE="/k8s-helper/phylactery_ready"

# Credential file paths (APPROACH_1 and APPROACH_2 share join-command.txt on /share;
# APPROACH_3 adds certificate-key.txt and phylactery-kubeconfig)
JOIN_COMMAND_FILE="/share/join-command.txt"
CERT_KEY_FILE="/share/certificate-key.txt"          # APPROACH_3 only
PHYLACTERY_KUBECONFIG="/share/phylactery-kubeconfig" # APPROACH_3 only

# ---------------------------------------------------------------------------
# WORKER NODE PATH
# ---------------------------------------------------------------------------
if ! hostname | grep -q "control"; then
  echo "Based on hostname this is a worker node"

  until [ -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader node to be ready..."
    sleep 5
  done

  until [ -f "$JOIN_COMMAND_FILE" ]; do
    echo "Waiting for join-command.txt..."
    sleep 2
  done

  echo "Joining cluster as worker..."
  kubeadm reset -f || true
  if eval "$(cat "$JOIN_COMMAND_FILE") --v=5"; then
    echo "Worker joined successfully."
    # APPROACH_2: self-destruct key after successful join
    if [ "$SECURITY_MODE" = "APPROACH_2" ] && [ -f "$NODE_KEY_FILE" ]; then
      rm -f "$NODE_KEY_FILE"
      echo "APPROACH_2: Node key deleted after successful join."
    fi
  else
    echo "Worker join failed, cleaning up..."
    kubeadm reset -f || true
  fi

  echo "Worker done."
  exit 0
fi

echo "Based on hostname this is a control node"

# ---------------------------------------------------------------------------
# LEADER ELECTION
# First writer wins via noclobber. On reboot the previous leader's hostname
# persists in the file, so the same node naturally re-takes leadership.
# ---------------------------------------------------------------------------
(set -o noclobber; echo "$HOSTNAME" > "$LEADER_FILE") 2>/dev/null || true
LEADER=$(cat "$LEADER_FILE" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# FOLLOWER CONTROL-PLANE PATH
# ---------------------------------------------------------------------------
if [ "$HOSTNAME" != "$LEADER" ]; then
  echo "Acknowledged $LEADER as leader, running as control-plane follower."

  until [ -f "$LEADER_READY_FILE" ]; do
    echo "Waiting for leader to be ready..."
    sleep 5
  done

  # Phylactery: updates HAProxy peer list and cleans stale k8s/etcd membership
  systemctl start phylactery.service
  systemctl start keepalived

  until [ -f "$PHYLACTERY_READY_FILE" ]; do
    echo "Waiting for phylactery service to be ready..."
    sleep 5
  done

  kubeadm reset -f || true

  MAX_JOIN_ATTEMPTS=3
  ATTEMPT=0

  case "$SECURITY_MODE" in

    # ------------------------------------------------------------------
    APPROACH_1)
    # ------------------------------------------------------------------
    # CA files are on /share. Extract them so kubeadm uses them to sign
    # fresh node-specific certs for THIS node (no --certificate-key needed).
    # pki.tar.gz contains CA certs/keys only — node-specific certs (e.g.
    # apiserver.crt) are intentionally excluded so kubeadm generates them
    # for the correct hostname/IP rather than reusing the leader's copies.
      until [ -f "/share/pki.tar.gz" ] && [ -f "$JOIN_COMMAND_FILE" ]; do
        echo "Waiting for PKI and join command on /share..."
        sleep 2
      done

      while [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "Control-plane join attempt $ATTEMPT/$MAX_JOIN_ATTEMPTS..."
        kubeadm reset -f || true
        # Re-extract CA files after every reset — kubeadm reset wipes /etc/kubernetes/pki/
        mkdir -p /etc/kubernetes
        tar -xzf /share/pki.tar.gz -C /etc/kubernetes
        echo "PKI (CA files) extracted from NFS."
        if eval "$(cat "$JOIN_COMMAND_FILE") --control-plane --v=5"; then
          echo "Successfully joined as control-plane follower."
          mkdir -p /root/.kube
          cp /etc/kubernetes/admin.conf /root/.kube/config
          echo "Follower done."
          exit 0
        fi
        echo "Attempt $ATTEMPT failed."
        [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ] && sleep 15
      done
      ;;

    # ------------------------------------------------------------------
    APPROACH_2)
    # ------------------------------------------------------------------
    # Download admin kubeconfig + PKI subset from secure server using this
    # node's unique key, then join with pre-populated PKI. Delete key after.
      until [ -f "$JOIN_COMMAND_FILE" ]; do
        echo "Waiting for join command on /share..."
        sleep 2
      done

      NODE_KEY=$(cat "$NODE_KEY_FILE" 2>/dev/null || echo "")
      if [ -z "$NODE_KEY" ]; then
        echo "ERROR: No key found at $NODE_KEY_FILE"
        exit 1
      fi

      echo "Downloading credentials from secure server..."
      mkdir -p /root/.kube
      DOWNLOAD_ATTEMPTS=0
      until curl -f -s "${SECURE_SERVER}/config/${NODE_KEY}" -o /root/.kube/config; do
        DOWNLOAD_ATTEMPTS=$((DOWNLOAD_ATTEMPTS + 1))
        if [ $DOWNLOAD_ATTEMPTS -ge 30 ]; then
          echo "ERROR: Timed out waiting for kube.config from secure server."
          exit 1
        fi
        echo "Waiting for kube.config on secure server... (${DOWNLOAD_ATTEMPTS}/30)"
        sleep 5
      done
      DOWNLOAD_ATTEMPTS=0
      until curl -f -s "${SECURE_SERVER}/certs/${NODE_KEY}" -o /tmp/pki.tar.gz; do
        DOWNLOAD_ATTEMPTS=$((DOWNLOAD_ATTEMPTS + 1))
        if [ $DOWNLOAD_ATTEMPTS -ge 30 ]; then
          echo "ERROR: Timed out waiting for pki.tar.gz from secure server."
          exit 1
        fi
        echo "Waiting for pki.tar.gz on secure server... (${DOWNLOAD_ATTEMPTS}/30)"
        sleep 5
      done
      echo "Credentials downloaded from secure server."

      while [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "Control-plane join attempt $ATTEMPT/$MAX_JOIN_ATTEMPTS..."
        kubeadm reset -f || true
        # Re-extract CA files after every reset — kubeadm reset wipes /etc/kubernetes/pki/
        mkdir -p /etc/kubernetes
        tar -xzf /tmp/pki.tar.gz -C /etc/kubernetes
        echo "PKI (CA files) extracted from secure server."
        if eval "$(cat "$JOIN_COMMAND_FILE") --control-plane --v=5"; then
          echo "Successfully joined as control-plane follower."
          rm -f /tmp/pki.tar.gz
          # Self-destruct key — attack window closed
          rm -f "$NODE_KEY_FILE"
          echo "APPROACH_2: Node key deleted after successful join."
          echo "Follower done."
          exit 0
        fi
        echo "Attempt $ATTEMPT failed."
        [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ] && sleep 15
      done
      rm -f /tmp/pki.tar.gz
      ;;

    # ------------------------------------------------------------------
    APPROACH_3)
    # ------------------------------------------------------------------
    # Least-privilege: kubeadm fetches the encrypted CA bundle from the
    # API server using certificate-key — raw PKI keys never touch /share.
      until [ -f "$JOIN_COMMAND_FILE" ] && [ -f "$CERT_KEY_FILE" ]; do
        echo "Waiting for join credentials on /share..."
        sleep 2
      done

      CERT_KEY=$(cat "$CERT_KEY_FILE")

      while [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "Control-plane join attempt $ATTEMPT/$MAX_JOIN_ATTEMPTS..."
        kubeadm reset -f || true
        if eval "$(cat "$JOIN_COMMAND_FILE") --control-plane --certificate-key $CERT_KEY --v=5"; then
          echo "Successfully joined as control-plane follower."
          mkdir -p /root/.kube
          cp /etc/kubernetes/admin.conf /root/.kube/config
          echo "Follower done."
          exit 0
        fi
        echo "Attempt $ATTEMPT failed."
        [ $ATTEMPT -lt $MAX_JOIN_ATTEMPTS ] && sleep 15
      done
      ;;

  esac

  echo "ERROR: Failed to join after $MAX_JOIN_ATTEMPTS attempts."
  kubeadm reset -f || true
  exit 1
fi

# ---------------------------------------------------------------------------
# LEADER PATH
# ---------------------------------------------------------------------------
echo "I am the leader ($HOSTNAME)"

# Invalidate any stale leader_ready so followers wait for this boot's fresh init
rm -f "$LEADER_READY_FILE"

# Phylactery: announces node, updates HAProxy peer list, and (if API server is
# already reachable) cleans any stale entries using the appropriate kubeconfig
mkdir -p /share/phylactery
cp /k8s-helper/haproxy.cfg /share/phylactery/haproxy.cfg
cp /k8s-helper/haproxy.cfg.base /share/phylactery/haproxy.cfg.base

systemctl start phylactery.service
systemctl start keepalived

until [ -f "$PHYLACTERY_READY_FILE" ]; do
  echo "Waiting for phylactery service to be ready..."
  sleep 5
done

# Bind VIP to leader node (HAProxy listens here for the control-plane endpoint)
ip addr add 10.0.0.99/24 dev net0 || echo "VIP already bound"

# ---------------------------------------------------------------------------
# FRESH CLUSTER INITIALIZATION
# Ephemeral Kubernetes always does a full re-init on each boot.
# ---------------------------------------------------------------------------
echo "Initializing Kubernetes cluster (fresh init)..."
kubeadm reset -f || true
kubeadm init \
  --control-plane-endpoint "vip.kubernetes.local:8443" \
  --upload-certs \
  --kubernetes-version v1.32.1 \
  --pod-network-cidr=10.244.0.0/16 \
  --v=5

# Admin credentials on leader — path depends on approach (see below)
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

# Apply CNI
kubectl apply -f /k8s-helper/kube-flannel.yml
kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  -n kube-flannel patch ds kube-flannel-ds --type json \
  -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--iface=net0"}]'

# Wait for etcd server cert (needed by phylactery's etcd membership check)
until [ -f "/etc/kubernetes/pki/etcd/server.crt" ]; do
  echo "Waiting for etcd server cert..."
  sleep 5
done

# ===========================================================================
# CREDENTIAL DISTRIBUTION — behaviour controlled by SECURITY_MODE
# ===========================================================================
case "$SECURITY_MODE" in

  # -------------------------------------------------------------------------
  APPROACH_1)
  # -------------------------------------------------------------------------
  # Copy everything to /share.  Simple but exposes all PKI private keys and
  # the full cluster-admin kubeconfig to anyone with NFS share access.
    echo "--- APPROACH_1: Writing all credentials to /share ---"

    # Full admin kubeconfig
    cp /etc/kubernetes/admin.conf /share/kube.config
    chmod 644 /share/kube.config
    echo "kube.config written."

    # CA-only PKI archive — contains the private CA keys that make APPROACH_1
    # insecure (anyone with NFS access can forge certificates), but deliberately
    # excludes node-specific certs (apiserver.crt, etcd/server.crt, etc.) so
    # followers generate correct certs for their own hostname/IP rather than
    # reusing the leader's certs and ending up with wrong SANs.
    ( cd /etc/kubernetes && tar -czf /share/pki.tar.gz \
        pki/ca.crt pki/ca.key \
        pki/sa.key pki/sa.pub \
        pki/front-proxy-ca.crt pki/front-proxy-ca.key \
        pki/etcd/ca.crt pki/etcd/ca.key )
    chmod 644 /share/pki.tar.gz
    echo "pki.tar.gz (CA files only) written."

    # Bootstrap join token for all nodes
    kubeadm token create --ttl 0 --print-join-command > "$JOIN_COMMAND_FILE"
    chmod 644 "$JOIN_COMMAND_FILE"
    echo "join-command.txt written."
    ;;

  # -------------------------------------------------------------------------
  APPROACH_2)
  # -------------------------------------------------------------------------
  # Upload admin kubeconfig and PKI subset (CA certs/keys only — no node certs)
  # to the secure server using this leader node's key. Write only the minimal
  # join command to /share.  After upload the leader's key can be deleted.
    echo "--- APPROACH_2: Uploading credentials to secure server ---"

    LEADER_KEY=$(cat "$NODE_KEY_FILE" 2>/dev/null || echo "")
    if [ -z "$LEADER_KEY" ]; then
      echo "ERROR: No key found at $NODE_KEY_FILE"
      exit 1
    fi

    # Bootstrap join token — limited scope, acceptable on shared NFS
    kubeadm token create --ttl 0 --print-join-command > "$JOIN_COMMAND_FILE"
    chmod 644 "$JOIN_COMMAND_FILE"
    echo "join-command.txt written."

    # PKI subset archive — CA certs/keys only; node-specific certs excluded
    # (api-server.crt, etcd peer certs) to prevent certificate reuse
    ( cd /etc/kubernetes && tar -czf /tmp/pki.tar.gz \
        pki/ca.crt pki/ca.key \
        pki/sa.key pki/sa.pub \
        pki/front-proxy-ca.crt pki/front-proxy-ca.key \
        pki/etcd/ca.crt pki/etcd/ca.key )

    # Upload to secure server
    echo "Uploading kube.config to secure server..."
    curl -f -s -X POST --data-binary @/etc/kubernetes/admin.conf \
      "${SECURE_SERVER}/upload/kube.config/${LEADER_KEY}" \
      || { echo "ERROR: Failed to upload kube.config"; exit 1; }

    echo "Uploading pki.tar.gz to secure server..."
    curl -f -s -X POST --data-binary @/tmp/pki.tar.gz \
      "${SECURE_SERVER}/upload/pki.tar.gz/${LEADER_KEY}" \
      || { echo "ERROR: Failed to upload pki.tar.gz"; exit 1; }

    rm -f /tmp/pki.tar.gz
    echo "Credentials uploaded to secure server."

    # Self-destruct leader key — attack window closed
    rm -f "$NODE_KEY_FILE"
    echo "APPROACH_2: Leader key deleted after upload."
    ;;

  # -------------------------------------------------------------------------
  APPROACH_3)
  # -------------------------------------------------------------------------
  # Write ONLY least-privilege credentials to /share.
  # Raw PKI keys are encrypted by kubeadm and stored inside etcd; they never
  # appear on the shared filesystem.
    echo "--- APPROACH_3: Writing least-privilege credentials to /share ---"

    # 1. Bootstrap Join Token
    #    Scope: node joining only — cannot query API, read secrets, or admin ops
    echo "Writing bootstrap join token..."
    kubeadm token create --ttl 0 --print-join-command > "$JOIN_COMMAND_FILE"
    chmod 644 "$JOIN_COMMAND_FILE"
    echo "join-command.txt written."

    # 2. Certificate Key
    #    Scope: control-plane join only — decrypts kubeadm's encrypted PKI bundle
    #    Security: raw private keys (ca.key, etcd/ca.key, sa.key) never on /share;
    #    stored encrypted in etcd, retrieved only via authenticated API server call.
    echo "Uploading certificate bundle and writing certificate key..."
    CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
    echo "$CERT_KEY" > "$CERT_KEY_FILE"
    chmod 644 "$CERT_KEY_FILE"
    echo "certificate-key.txt written."

    # 3. Phylactery Service Account — node lifecycle management only
    #    Scope: get/list/patch/delete nodes; get/list/delete pods; create evictions
    #    Cannot: read secrets, deploy workloads, create credentials, admin ops
    echo "Creating phylactery RBAC (node-management only)..."
    kubectl apply -f - <<'RBAC_EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: phylactery
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: phylactery-node-manager
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods/eviction"]
  verbs: ["create"]
- apiGroups: ["apps"]
  resources: ["daemonsets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: phylactery-node-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: phylactery-node-manager
subjects:
- kind: ServiceAccount
  name: phylactery
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: phylactery-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: phylactery
type: kubernetes.io/service-account-token
RBAC_EOF

    # Wait for controller to populate the token
    echo "Waiting for phylactery service account token to be populated..."
    until kubectl get secret phylactery-token -n kube-system \
          -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; do
      sleep 2
    done

    PHYLACTERY_TOKEN=$(kubectl get secret phylactery-token -n kube-system \
      -o jsonpath='{.data.token}' | base64 -d)

    # Build phylactery kubeconfig:
    #   - Embeds the cluster CA *certificate* (public — safe on NFS)
    #   - Uses the scoped SA token (node ops only)
    kubectl config set-cluster kubernetes \
      --certificate-authority=/etc/kubernetes/pki/ca.crt \
      --embed-certs=true \
      --server=https://vip.kubernetes.local:8443 \
      --kubeconfig="$PHYLACTERY_KUBECONFIG"

    kubectl config set-credentials phylactery-sa \
      --token="$PHYLACTERY_TOKEN" \
      --kubeconfig="$PHYLACTERY_KUBECONFIG"

    kubectl config set-context default \
      --cluster=kubernetes \
      --user=phylactery-sa \
      --kubeconfig="$PHYLACTERY_KUBECONFIG"

    kubectl config use-context default --kubeconfig="$PHYLACTERY_KUBECONFIG"
    chmod 644 "$PHYLACTERY_KUBECONFIG"
    echo "phylactery-kubeconfig written."
    ;;

esac

# ---------------------------------------------------------------------------
# Signal followers — they may now begin their join sequence
# ---------------------------------------------------------------------------
touch "$LEADER_READY_FILE"
echo "Leader initialization complete. Followers may now join."
