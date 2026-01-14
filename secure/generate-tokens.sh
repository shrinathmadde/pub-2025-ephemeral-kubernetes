#!/bin/bash
set -e

TOKEN_DIR="/var/lib/warewulf/tokens"
OVERLAY_DIR="/var/lib/warewulf/overlays/k8s-overlay/rootfs/etc"

mkdir -p "$TOKEN_DIR"
mkdir -p "$OVERLAY_DIR"

# Get all nodes
NODES=$(wwctl node list | tail -n +3 | awk '{print $1}')

for NODE in $NODES; do
    TOKEN=$(echo -n "${NODE}-$(date +%s)-$(openssl rand -hex 16)" | sha256sum | cut -d' ' -f1)
    
    # Create token file
    cat > "$TOKEN_DIR/${TOKEN}.json" <<EOF
{
  "node": "$NODE",
  "token": "$TOKEN",
  "created": $(date +%s),
  "expired": false
}
EOF
    
    # Create per-node overlay file
    cat > "$OVERLAY_DIR/k8s-token.${NODE}" <<EOF
$TOKEN
EOF
    
    echo "Generated token for $NODE"
done

echo "Tokens generated in $TOKEN_DIR"
