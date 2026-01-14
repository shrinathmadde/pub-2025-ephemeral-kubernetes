#!/usr/bin/env python3
from flask import Flask, send_file, abort, request
import json
import os
import time
from pathlib import Path

app = Flask(__name__)
TOKEN_DIR = "/var/lib/warewulf/tokens"
FILES_DIR = "/var/lib/warewulf/secure-files"
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
    
    if data.get('first_use'):
        elapsed = time.time() - data['first_use']
        if elapsed > 600:  # 10 minutes
            return False, "Token timed out"
    else:
        data['first_use'] = time.time()
        with open(token_file, 'w') as f:
            json.dump(data, f)
    
    return True, data.get('node', 'unknown')

@app.route('/certs/<token>')
def get_certs(token):
    valid, node = validate_token(token)
    if not valid:
        log(f"DENIED: {token} - {node}")
        abort(403)
    
    log(f"CERTS: {node}")
    return send_file(f"{FILES_DIR}/pki.tar.gz")

@app.route('/config/<token>')
def get_config(token):
    valid, node = validate_token(token)
    if not valid:
        log(f"DENIED: {token} - {node}")
        abort(403)
    
    log(f"CONFIG: {node}")
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
        log(f"EXPIRED: {data.get('node', 'unknown')}")
    
    return {'status': 'ok'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
