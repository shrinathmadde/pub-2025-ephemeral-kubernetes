#!/bin/bash
set -e

WW_HOST_IP="${WW_HOST_IP:-10.0.0.3}"

# --- SECURITY UPDATE ---
# We use a PRIVATE folder now, not the NFS shared folder.
PRIVATE_SECRETS="/var/lib/warewulf/private-secrets"
TOKEN_DIR="/var/lib/warewulf/tokens"

echo "Setting up secure file server..."

# 1. Install dependencies
dnf install -y python3-pip
pip3 install flask

# 2. Create directories with strict permissions
echo "Creating private secrets directory..."
mkdir -p "$TOKEN_DIR"
mkdir -p "$PRIVATE_SECRETS"

# Set permission to 700 (Read/Write for Root ONLY). 
# This ensures no other user/service can peek inside.
chmod 700 "$PRIVATE_SECRETS"

# 3. Copy file server script
# Assuming you run this script from the 'secure-server' folder
cp ww-file-server.py /usr/local/bin/ww-file-server.py
chmod +x /usr/local/bin/ww-file-server.py

# 4. Install Systemd Service
cp ww-secure-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable ww-secure-server
systemctl restart ww-secure-server

# 5. Generate tokens (Assumes this script exists in the same folder)
if [ -f "./generate-tokens.sh" ]; then
    ./generate-tokens.sh
else
    echo "WARNING: generate-tokens.sh not found. Please run it manually."
fi

echo "-----------------------------------------------------"
echo "Secure Push Server running on $WW_HOST_IP:8000"
echo "Storage: $PRIVATE_SECRETS (Not exported via NFS)"
echo "-----------------------------------------------------"
