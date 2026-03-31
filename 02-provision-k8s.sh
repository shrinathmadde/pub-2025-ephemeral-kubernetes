#!/bin/bash
# ==============================================================================
# SCRIPT 2: KUBERNETES NODE PROVISIONING
# ==============================================================================
# Provisions a SINGLE Kubernetes node: generates a join token, registers it
# in Warewulf, builds overlays, restarts DHCP/Warewulf, then reboots the node.
#
# Usage:
#   ./02-provision-k8s.sh <name> <mac> <ip> [role]
#
#   role defaults to "k8s-worker" if omitted.
#   For the control plane pass role=k8s-control.
#
# Called by 04-balancer.sh during initial setup and dynamic transitions.
# ==============================================================================
set -e

SCRIPT_NAME="k8s-provision"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MANAGER_IP=$(get_setting "MANAGER_IP")

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
NODE_NAME="${1:-}"
NODE_MAC="${2:-}"
NODE_IP="${3:-}"
NODE_ROLE="${4:-k8s-worker}"

if [[ -z "$NODE_NAME" || -z "$NODE_MAC" || -z "$NODE_IP" ]]; then
    echo "Usage: $0 <name> <mac> <ip> [role]"
    exit 1
fi

log_separator
log "K8s PROVISION: $NODE_NAME  mac=$NODE_MAC  ip=$NODE_IP  role=$NODE_ROLE"
log_separator

# ==============================================================================
# PHASE 1: Generate Security Token
# ==============================================================================
log "PHASE 1: Generating security token for $NODE_NAME..."

TOKEN_DIR="/var/lib/warewulf/tokens"
OVERLAY_TOKEN_DIR="/var/lib/warewulf/overlays/k8s-overlay/rootfs/etc"
mkdir -p "$TOKEN_DIR" "$OVERLAY_TOKEN_DIR"

TOKEN=$(echo -n "${NODE_NAME}-$(date +%s)-$(openssl rand -hex 16)" | sha256sum | cut -d' ' -f1)

cat > "$TOKEN_DIR/${TOKEN}.json" <<EOF
{
  "node": "$NODE_NAME",
  "token": "$TOKEN",
  "created": $(date +%s)
}
EOF
echo "$TOKEN" > "$OVERLAY_TOKEN_DIR/k8s-token.${NODE_NAME}"
log "  Token generated for $NODE_NAME"

# ==============================================================================
# PHASE 2: Register Node in Warewulf
# ==============================================================================
log "PHASE 2: Registering $NODE_NAME in Warewulf..."

if [ "$NODE_ROLE" = "k8s-control" ]; then
    IMAGE="$K8S_CONTROL_IMAGE"
else
    IMAGE="$K8S_WORKER_IMAGE"
fi
log "  Image: $IMAGE"

sed -i "/\b${NODE_NAME}\b/d" /etc/hosts
echo "$NODE_IP $NODE_NAME" >> /etc/hosts

clean_ssh_known_hosts "$NODE_NAME" "$NODE_IP"

wwctl node add "$NODE_NAME" --netdev net0 --hwaddr "$NODE_MAC" --ipaddr "$NODE_IP" || true
wwctl node set "$NODE_NAME" --container "$IMAGE" --root tmpfs -O "$K8S_OVERLAYS"

# ==============================================================================
# PHASE 3: Build Overlays
# ==============================================================================
log "PHASE 3: Building overlays..."
wwctl overlay build

# ==============================================================================
# PHASE 4: Restart Services and Reboot Node
# ==============================================================================
log "PHASE 4: Restarting DHCP/Warewulf and rebooting $NODE_NAME..."

wwctl configure dhcp
systemctl restart dhcpd warewulfd

log "  Rebooting $NODE_NAME..."
wwctl ssh "$NODE_NAME" reboot

log_separator
log "K8s PROVISION COMPLETE: $NODE_NAME"
log_separator
