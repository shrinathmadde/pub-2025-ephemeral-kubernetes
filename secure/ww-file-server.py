#!/usr/bin/env python3
from flask import Flask, send_file, abort, request
import json
import os
import time
from pathlib import Path

app = Flask(__name__)

TOKEN_DIR = "/var/lib/warewulf/tokens"

# --- SECURITY UPDATE ---
# We now store files in a PRIVATE folder, NOT the NFS shared folder.
# This folder should NOT be exported in /etc/exports.
FILES_DIR = "/var/lib/warewulf/private-secrets" 
LOG_FILE = "/var/log/ww-file-server.log"

def log(msg):
    with open(LOG_FILE, 'a') as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}\n")

def validate_token(token):
    token_file = Path(TOKEN_DIR) / f"{token}.json"
    if not token_file.exists():
        return False, "Token not found"
    
    with open(token_file) as f:
        data = json.load(f)
    
    if data.get('expired', False):
        return False, "Token expired"
    
    # Check for timeout (10 mins after first use)
    if data.get('first_use'):
        elapsed = time.time() - data['first_use']
        if elapsed > 600: 
            return False, "Token timed out"
    else:
        # Mark first use time
        data['first_use'] = time.time()
        with open(token_file, 'w') as f:
            json.dump(data, f)
    
    return True, data.get('node', 'unknown')

# --- NEW ENDPOINT: UPLOAD ---
@app.route('/upload/<filename>/<token>', methods=['POST'])
def upload_file(filename, token):
    """
    Allows the Leader node to push secrets to the private vault.
    Usage: curl -X POST --data-binary @file http://Manager:8000/upload/kube.config/MYTOKEN
    """
    # 1. Authenticate
    valid, node = validate_token(token)
    if not valid:
        log(f"UPLOAD DENIED: {token} - {node}")
        abort(403)

    # 2. Sanitize Filename (Prevent directory traversal attacks)
    if ".." in filename or "/" in filename:
        log(f"UPLOAD ILLEGAL NAME: {filename} from {node}")
        abort(400, "Invalid filename")

    # 3. Create Private Directory if it doesn't exist
    Path(FILES_DIR).mkdir(parents=True, exist_ok=True)

    # 4. Save the File
    target_path = Path(FILES_DIR) / filename
    try:
        # request.get_data() reads the raw binary body from curl
        with open(target_path, 'wb') as f:
            f.write(request.get_data())
        
        log(f"UPLOAD SUCCESS: {filename} uploaded by {node}")
        return {'status': 'saved', 'size': os.path.getsize(target_path)}
        
    except Exception as e:
        log(f"UPLOAD ERROR: {str(e)}")
        abort(500, "Write failed")

# --- DOWNLOAD ENDPOINTS (Now read from private-secrets) ---
@app.route('/certs/<token>')
def get_certs(token):
    valid, node = validate_token(token)
    if not valid:
        log(f"DOWNLOAD DENIED (Certs): {token} - {node}")
        abort(403)
    
    log(f"DOWNLOAD CERTS: {node}")
    return send_file(f"{FILES_DIR}/pki.tar.gz")

@app.route('/config/<token>')
def get_config(token):
    valid, node = validate_token(token)
    if not valid:
        log(f"DOWNLOAD DENIED (Config): {token} - {node}")
        abort(403)
    
    log(f"DOWNLOAD CONFIG: {node}")
    return send_file(f"{FILES_DIR}/kube.config")

@app.route('/token/expire', methods=['POST'])
def expire_token():
    token = request.json.get('token')
    token_file = Path(TOKEN_DIR) / f"{token}.json"
    
    if token_file.exists():
        with open(token_file) as f:
            data = json.load(f)
        data['expired'] = True
        with open(token_file, 'w') as f:
            json.dump(data, f)
        log(f"TOKEN EXPIRED: {data.get('node', 'unknown')}")
    
    return {'status': 'ok'}

if __name__ == '__main__':
    # Listen on internal IP (Manager)
    app.run(host='0.0.0.0', port=8000)
