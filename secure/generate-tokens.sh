#!/bin/bash
set -e

TOKEN_DIR="/var/lib/warewulf/tokens"
OVERLAY_DIR="/var/lib/warewulf/overlays/k8s-overlay/rootfs/etc"

mkdir -p "$TOKEN_DIR"
mkdir -p "$OVERLAY_DIR"

# Get all nodes - FIXED to avoid duplicates and header
NODES=$(wwctl node list | awk 'NR>2 && $1!="" {print $1}' | sort -u)

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
