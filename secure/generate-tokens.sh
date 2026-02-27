#!/bin/bash
set -e

TOKEN_DIR="/var/lib/warewulf/tokens"
OVERLAY_DIR="/var/lib/warewulf/overlays/k8s-overlay/rootfs/etc"

mkdir -p "$TOKEN_DIR"
mkdir -p "$OVERLAY_DIR"

# Safely get all nodes by ignoring headers, separators (===), and empty lines
NODES=$(wwctl node list | grep -E '^[a-zA-Z0-9]' | grep -v "^NODE" | awk '{print $1}' | sort -u)

# Safety fallback just in case wwctl output is empty or formatting changes
if [ -z "$NODES" ]; then
    echo "Warning: Could not detect nodes automatically. Using fallback list."
    NODES="control0 control1"
fi

for NODE in $NODES; do
    TOKEN=$(echo -n "${NODE}-$(date +%s)-$(openssl rand -hex 16)" | sha256sum | cut -d' ' -f1)
    
    # Create token file
    cat > "$TOKEN_DIR/${TOKEN}.json" <<EOF
{
  "node": "$NODE",
  "token": "$TOKEN",
  "created": $(date +%s)
}
EOF
    
    # Create per-node overlay file
    cat > "$OVERLAY_DIR/k8s-token.${NODE}" <<EOF
$TOKEN
EOF
    
    echo "Generated token for $NODE"
done

echo "Tokens generated in $TOKEN_DIR"
