

# Ephemeral Kubernetes on Warewulf

This repository provides a proof of concept for an **Ephemeral High-Availability Kubernetes** deployment. It uses **Warewulf 4** to provision stateless nodes (booting from RAM) including at least 3 control plane nodes.

The provided scripts perform an offline installation of Kubernetes and configure a HA setup with **Keepalived** and **HAProxy**. Additionally, a custom service called **Phylactery** ensures that nodes can leave and rejoin the cluster dynamically upon reboot.

### Key Features

* **Speed:** Setting up a full HA cluster from scratch takes less than 90 seconds.
* **Stateless:** Nodes run entirely in RAM (`tmpfs`). A reboot wipes the node clean.
* **Self-Healing:** Custom scripts handle DNS injection, VIP binding, and certificate distribution automatically on boot.
* **Secure:** Uses a secure file server to distribute sensitive configuration (like `admin.conf` and CA keys) instead of open NFS.

---

## 1. Environment Setup

### OpenStack Configuration

*tested on OpenStack with Rocky Linux 9.4*

1. **Network:** Create a network named `private-pxe` (Subnet: `10.0.0.0/24`).
* Disable Gateway.
* Disable DHCP (Warewulf handles DHCP).
* Set Allocation Pool: `10.0.0.1 - 10.0.0.254`.


2. **Cluster Manager VM:** Create a VM (`cluster-manager`) attached to `private-pxe` and your public network (floating IP).
* Allow SSH (Port 22).
* Allow Internal Traffic (All ports on `10.0.0.0/24`).


3. **Nodes:** Create 3+ Control nodes (`control0`, `control1`...) and Worker nodes.
* **Crucial:** Disable "Port Security" on the `private-pxe` ports for all nodes (required for PXE boot and VIPs).



### Warewulf Installation (On Cluster Manager)

```bash
# Install Warewulf
dnf update -y
dnf install -y https://github.com/warewulf/warewulf/releases/download/v4.5.8/warewulf-4.5.8-1.el9.x86_64.rpm
dnf install -y nano git

# Configure Interface
# Edit /etc/warewulf/warewulf.conf:
# - ipaddr: 10.0.0.3 (Manager IP)
# - netmask: 255.255.255.0
# - range: 10.0.0.100 10.0.0.254

# Initialize
wwctl configure --all
systemctl enable --now warewulfd

# Import Base OS
wwctl container import docker://ghcr.io/hpcng/warewulf-rockylinux:9

```

---

## 2. Cluster Configuration

### Step A: Configure NFS & Secure Storage

We use NFS for general file sharing and a secured folder for sensitive keys.

1. **Edit `/etc/warewulf/warewulf.conf**` and add the NFS export.
* *Note: Do not use `fsid=0` to avoid mounting path issues.*


```yaml
nfs:
  enabled: true
  export options: rw,sync,no_root_squash
  mount options: defaults
  mount: true
  path: /share

```


2. **Apply Configuration:**
```bash
wwctl configure -a

```



### Step B: Clone and Prepare Overlay

1. **Clone this repo:**
```bash
git clone https://github.com/YOUR_REPO/pub-2025-ephemeral-kubernetes.git
cd pub-2025-ephemeral-kubernetes

```


2. **Prepare the Overlay:**
```bash
# Create the overlay structure
wwctl overlay create k8s-overlay

# Copy the helper scripts into the overlay
cp -r k8s-helper/* /var/lib/warewulf/overlays/k8s-overlay/

# Ensure scripts are executable
chmod +x /var/lib/warewulf/overlays/k8s-overlay/k8s-helper/*.sh

```


3. **Patch the Installation Script:**
*Critical Step:* Ensure `/var/lib/warewulf/overlays/k8s-overlay/k8s-helper/k8s-install.sh` contains the **Network Wait Loop** and **DNS Fix**.
*Add this to the top of `k8s-install.sh`:*
```bash
# --- FIX: WAIT FOR NETWORK ---
echo "Waiting for network..."
until ip addr show dev net0 | grep -q "inet"; do
  sleep 1
done

# --- FIX: DNS & MOUNT ---
mkdir -p /share
mount -t nfs 10.0.0.3:/share /share || true
if ! grep -q "vip.kubernetes.local" /etc/hosts; then
    echo "10.0.0.99 vip.kubernetes.local" >> /etc/hosts
fi

```



### Step C: Secure Server Setup

To securely store the `kube.config` and PKI keys, we use the Secure Overlay feature.

1. **Create the Secure Directory:**
```bash
mkdir -p /var/lib/warewulf/overlays/k8s-overlay/share/secure-files
chmod 700 /var/lib/warewulf/overlays/k8s-overlay/share/secure-files

```


2. **Configure Script:**
Ensure `USE_SECURE_MODE="true"` is set in `k8s-install.sh`.

### Step D: Build Images & Nodes

1. **Download Kubernetes Images:**
```bash
cd k8s-images
./download-images.sh
./copy-images.sh

```


2. **Add Nodes to Warewulf:**
```bash
# Add Control Nodes (Replace MAC_ADDR and IP)
wwctl node add control0 --hwaddr <MAC> --ipaddr 10.0.0.2 --netdev net0 --netmask 255.255.255.0
wwctl node add control1 --hwaddr <MAC> --ipaddr 10.0.0.4 --netdev net0 --netmask 255.255.255.0

# Set Container & Overlay
wwctl node set control[0-99] --container warewulf-rockylinux:9
wwctl node set control[0-99] -O wwinit,k8s-overlay
wwctl node set control[0-99] --root tmpfs

```


3. **Build Overlays:**
```bash
wwctl overlay build

```



---

## 3. Deployment & Boot Sequence

The cluster deployment relies on a specific race-condition-free boot order.

### Initial Boot

1. **Clean the Share:**
Before starting a fresh cluster, ensure no stale lock files exist.
```bash
rm -f /share/leader /share/leader_ready /share/kube.config

```


2. **Boot the Leader (control0) ONLY:**
```bash
wwctl ssh control0 reboot

```


*Wait until `control0` finishes initialization. You can verify this by running `ls /share` on the manager; look for the file `leader_ready`.*
3. **Boot the Followers:**
```bash
wwctl ssh control[1-99] reboot

```



### Accessing the Cluster

1. **Install Kubectl on Manager:**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/

```


2. **Set Config:**
The leader copies the config to the NFS share automatically.
```bash
export KUBECONFIG=/share/kube.config
kubectl get nodes

```



---

## 4. How It Works (The "Phylactery")

1. **Boot:** Node starts, waits for network, mounts NFS, and injects `10.0.0.99 vip.kubernetes.local` into `/etc/hosts`.
2. **Election:** The first node checks `/share/leader`. If missing, it claims leadership.
3. **Initialization:**
* Leader binds VIP `10.0.0.99`.
* Runs `kubeadm init`.
* Uploads **CA Keys Only** to the Secure Server.
* Creates `/share/leader_ready`.


4. **Joining:**
* Follower nodes see `leader_ready`.
* They download the CA keys.
* They generate their own certificates and join via `kubeadm join`.


5. **Reboot Recovery:**
The `phylactery` service runs on every node. If a node reboots, `phylactery` detects the "stale" node object in Kubernetes (from the previous boot) and removes it, allowing the node to rejoin cleanly with the same name.

## Troubleshooting

**Node stuck at `[api-check]`:**

* Check `/etc/hosts` on the node. Does it have `10.0.0.99`?
* Check `ip addr` on the Leader. Does it have the VIP?

**`mount: No such file`:**

* Check `/etc/exports` on the manager. Ensure `fsid=0` is **NOT** used.

**Script crashes immediately:**

* Ensure `set -e` (Strict Mode) is disabled in the script header to allow the network wait loop to function.
