#!/bin/bash
set -e

WW_HOST_IP="${WW_HOST_IP:-10.0.0.15}"
SECURE_FILES="/var/lib/warewulf/secure-files"

echo "Setting up secure file server..."

# Install dependencies
dnf install -y python3-pip
pip3 install flask

# Create directories
mkdir -p /var/lib/warewulf/tokens
mkdir -p "$SECURE_FILES"

# Copy file server
cp ww-file-server.py /usr/local/bin/
chmod +x /usr/local/bin/ww-file-server.py

# Install service
cp systemd/ww-file-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable ww-file-server
systemctl restart ww-file-server

# Generate tokens
./generate-tokens.sh

echo "Secure file server running on $WW_HOST_IP:8000"
echo "Tokens generated for all nodes"
