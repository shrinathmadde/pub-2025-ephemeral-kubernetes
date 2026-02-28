# Ephemeral Kubernetes

This repository provides a proof of concept for an Ephemeral Kubernetes deployment.
It uses Warewulf to provision a set of nodes including at least 3 control nodes.
The provided scripts perform an offline installation of Kubernetes and configure a HA setup with Keepalived and HAProxy.

Moreover, the code includes a service called Phylactery, which ensures that nodes that are rebooted properly rejoin the cluster.

Setting up a cluster from scratch takes less than 90 seconds.

As the nodes are handled via Warewulf, they do not include persistent storage by default.
Persisting data beyond reboots requires additional configuration.

---

## Security Approaches

The install script (`k8s-install-final.sh`) supports three credential distribution models, controlled by a single variable at the top of the file:

```bash
SECURITY_MODE="${SECURITY_MODE:-APPROACH_3}"
```

| Mode | Name | Description |
|---|---|---|
| `APPROACH_1` | NFS-SIMPLE | All credentials (admin kubeconfig, all PKI private keys) written directly to `/share`. Simple, but maximum exposure. |
| `APPROACH_2` | SECURE-SERVER | Per-node SHA-256 keys authenticate against a Flask server on the cluster manager. Sensitive credentials never touch `/share`. |
| `APPROACH_3` | TOKEN-RBAC *(default)* | Only least-privilege tokens go on `/share`. Raw PKI keys stay encrypted inside etcd, never on NFS. |

You can either edit the variable directly in the script, or pass it through the systemd service environment (see [Choosing a Security Mode](#choosing-a-security-mode)).

---

## Installation

### OpenStack
The code was tested in an OpenStack environment but should work with any Warewulf setup (tested with v4.5.8 on Rocky 9.4).
If Warewulf is already installed, move on to [Ephemeral Kubernetes Configuration](#ephemeral-kubernetes-configuration).

To boot images via Warewulf in OpenStack, an image or volume is required that starts into a PXE boot sequence.

Create a new network for the cluster (this might require additional quota)
- Name the network "private-pxe"
- Set Admin State to True
- Set Create Subnet to True
- Name the Subnet "private-pxe-subnet"
- Set the Network Address to "10.0.0.0/24"
- Set Disable Gateway to True
- In Subnet Details set Enable DHCP to False and Allocation Pools to "10.0.0.1,10.0.0.254"

Create a new VM as the manager node
- Name it "cluster-manager"
- Use Rocky 9.4
- Use a flavor with sufficient resources
- Add your ssh key

Create security group
- Create "cluster-manager" security group
- Add a rule for SSH with a CIDR that is reachable from your workstation
- Assign the group to the cluster-manager VM
- Associate a floating IP with the cluster-manager VM
- Ensure that you can login via SSH into the VM

Create the cluster node VMs
- Create at least 3 VMs as control nodes named control0, control1, etc.
- Create zero or more worker nodes named worker0, worker1, etc.
- Set the pxe-boot image or volume for them
- After creating all nodes go to Networks, private-pxe and Ports and disable Port Security for all control and worker nodes

### Warewulf
On the cluster-manager node proceed with the following steps:

- `dnf update -y`
- `dnf install https://github.com/warewulf/warewulf/releases/download/v4.5.8/warewulf-4.5.8-1.el9.x86_64.rpm`
- edit `/etc/warewulf/warewulf.conf` and set ipaddr to the internal IP of the cluster-manager VM, for example, 10.0.0.3, set network mask to 255.255.255.0 and set DHCP range to 10.0.0.1 to 10.0.0.254
- `wwctl configure --all`
- `sudo systemctl enable --now warewulfd`
- Check with `sudo wwctl server status`
- `wwctl container import docker://ghcr.io/hpcng/warewulf-rockylinux:9`
- `wwctl container exec warewulf-rockylinux:9 /bin/sh`
    - `dnf install -y nano`
    - `exit`

Add the nodes in Warewulf
- `wwctl node add control0`
- `wwctl node set --container warewulf-rockylinux:9 control0`
- `wwctl node set --hwaddr <MAC ADDR> control0` The MAC Address can be found under Instances, control0, Interfaces
- `wwctl node set --ipaddr <IP ADDR> control0` The IP Address can be found in the same interface as the MAC Address
- `wwctl node set --netmask 255.255.255.0 control0`
- `wwctl node set --netdev net0 control0`
- `wwctl node set --nettagadd DNS1=1.1.1.1 control0` This sets the nameserver to be used

Do so for all control and worker nodes.
The pattern `control[0-99]` and `worker[0-99]` can be used to affect multiple nodes at once.
- `wwctl configure -a`

In OpenStack reboot the VMs and check console to ensure the nodes properly boot.
- Test that the nodes are running: `ssh control0` or `ssh <IP ADDR>`

### Ephemeral Kubernetes Configuration

Setup an NFS share, which will be used to share tokens and coordinate leader election between the nodes.
- Edit `/etc/warewulf/warewulf.conf` and under nfs add:
```yaml
  - path: /share
    export options: rw,sync,no_root_squash
    mount options: defaults
    mount: true
```
- `wwctl configure -a`
- `wwctl overlay build control0`

Create the overlay to be used by the cluster:
```bash
wwctl overlay create k8s-overlay
```

Clone this repository and cd into it:
```bash
cp -r k8s-overlay /var/lib/warewulf/overlays/k8s-overlay
```

Download and stage the container images:
```bash
cd k8s-images
./download-images.sh    # uses Kubernetes 1.32.1 by default
./copy-images.sh
cd -
```

Add the VIP DNS entry to the hosts overlay:
- Edit `/var/lib/warewulf/overlays/hosts/rootfs/etc/hosts.ww` and add:
  ```
  10.0.0.99 vip.kubernetes.local
  ```
  This sets the DNS entry for the virtual IP used by Keepalived for the HA setup.

Build the node container images:
```bash
cd ww-image-builder
./build-and-import.sh   # may take a few minutes
cd -
```

There are two container images: `k8s-base-ww` (for workers) and `k8s-control-ww` (for control nodes).

```bash
wwctl node set --container k8s-control-ww control[0-99]
wwctl node set --container k8s-base-ww worker[0-99]

# Assign the k8s overlay to all nodes
wwctl node set -O wwinit,k8s-overlay control[0-99]
wwctl node set -O wwinit,k8s-overlay worker[0-99]

# Set rootfs to tmpfs so containerd's pivot_root works
wwctl node set --root tmpfs control[0-99]
wwctl node set --root tmpfs worker[0-99]
```

---

## Choosing a Security Mode

Open `k8s-overlay/k8s-helper/k8s-install-final.sh` and set the `SECURITY_MODE` variable near the top of the file, then copy the overlay and rebuild before rebooting nodes.

Alternatively, pass it via the systemd service by editing `k8s-overlay/etc/systemd/system/k8s-install.service` and adding:
```ini
[Service]
Environment=SECURITY_MODE=APPROACH_2
```

### Approach 1 — NFS-SIMPLE

No extra setup required. This is the original design.

Set the mode:
```bash
# In k8s-install-final.sh, line near the top:
SECURITY_MODE="${SECURITY_MODE:-APPROACH_1}"
```

Copy overlay and rebuild:
```bash
cp -r k8s-overlay /var/lib/warewulf/overlays/k8s-overlay
wwctl configure -a
wwctl overlay build
```

Deploy:
```bash
wwctl ssh control[0-99] reboot
wwctl ssh worker[0-99] reboot
```

After ~90 seconds, the following files appear in `/share`:
- `leader` — hostname of the elected leader
- `leader_ready` — signals that followers may join
- `kube.config` — full cluster-admin kubeconfig
- `pki.tar.gz` — complete PKI archive including all private keys
- `join-command.txt` — kubeadm bootstrap join command

**Access kubectl from the cluster manager:**
```bash
# Install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
export KUBECONFIG=/share/kube.config
kubectl get nodes
```

---

### Approach 2 — SECURE-SERVER

This approach runs a Flask-based file server on the cluster manager. Sensitive credentials are stored in a private directory (`/var/lib/warewulf/private-secrets`) and are never written to `/share`. Each node authenticates using a unique SHA-256 key delivered through its Warewulf overlay.

#### 1. Install the secure file server on the cluster manager

```bash
pip3 install flask

# Copy the server script
cp secure/ww-file-server.py /usr/local/bin/ww-file-server.py

# Install and enable the systemd service
cp secure/systemd/ww-file-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ww-file-server.service

# Verify it is running
systemctl status ww-file-server.service
# Server listens on 0.0.0.0:8000; access logs at /var/log/ww-file-server.log
```

#### 2. Generate per-node keys

Run `generate-tokens.sh` **on the cluster manager** after all nodes have been added to Warewulf:

```bash
bash secure/generate-tokens.sh
```

This script:
- Reads the node list from `wwctl node list`
- Creates a unique SHA-256 key for each node under `/var/lib/warewulf/tokens/<KEY>.json`
- Writes each node's key into the overlay at `/var/lib/warewulf/overlays/k8s-overlay/rootfs/etc/k8s-token.<NODENAME>`

Verify the generated files:
```bash
ls /var/lib/warewulf/tokens/
ls /var/lib/warewulf/overlays/k8s-overlay/rootfs/etc/k8s-token.*
```

#### 3. Set the security mode and deploy

```bash
# In k8s-install-final.sh:
SECURITY_MODE="${SECURITY_MODE:-APPROACH_2}"
```

Copy overlay and rebuild (must be done **after** generating keys so the overlay contains them):
```bash
cp -r k8s-overlay /var/lib/warewulf/overlays/k8s-overlay
wwctl configure -a
wwctl overlay build
```

Deploy:
```bash
wwctl ssh control[0-99] reboot
wwctl ssh worker[0-99] reboot
```

After ~90 seconds, only one file appears in `/share`:
- `join-command.txt` — bootstrap join token (node-joining scope only)

The sensitive files (`kube.config`, `pki.tar.gz`) are stored exclusively in `/var/lib/warewulf/private-secrets` on the cluster manager.

**Access kubectl from the cluster manager** (credentials are on the manager, not on NFS):
```bash
# Copy the config from the private-secrets vault
cp /var/lib/warewulf/private-secrets/kube.config /root/.kube/config
kubectl get nodes
```

#### Key lifecycle and rotation

After a node successfully joins the cluster it deletes its own key file (`/etc/k8s-key.<HOSTNAME>`). When the node reboots, Warewulf re-provisions the overlay and the key is delivered again, enabling seamless rejoin.

To rotate keys (e.g., after a suspected compromise):
```bash
# Remove old keys
rm -f /var/lib/warewulf/tokens/*.json
rm -f /var/lib/warewulf/overlays/k8s-overlay/rootfs/etc/k8s-token.*

# Regenerate
bash secure/generate-tokens.sh

# Rebuild overlays so nodes get new keys on next boot
wwctl overlay build
```

---

### Approach 3 — TOKEN-RBAC (default)

No server or key generation required. Only three least-privilege credential files are written to `/share`; raw PKI private keys are encrypted by kubeadm and stored inside etcd, never accessible on NFS.

Set the mode (or leave it as the default):
```bash
# In k8s-install-final.sh:
SECURITY_MODE="${SECURITY_MODE:-APPROACH_3}"
```

Copy overlay and rebuild:
```bash
cp -r k8s-overlay /var/lib/warewulf/overlays/k8s-overlay
wwctl configure -a
wwctl overlay build
```

Deploy:
```bash
wwctl ssh control[0-99] reboot
wwctl ssh worker[0-99] reboot
```

After ~90 seconds, the following files appear in `/share`:
- `leader` / `leader_ready` — leader election signals
- `join-command.txt` — bootstrap token (node joining only; cannot query API or read secrets)
- `certificate-key.txt` — decrypts the kubeadm PKI bundle from the API server (control-plane join only; raw private keys never appear here)
- `phylactery-kubeconfig` — service account kubeconfig scoped to node lifecycle operations only (list/drain/delete nodes; no path to privilege escalation)

**Access kubectl from the cluster manager** (admin config is on the leader node only):
```bash
ssh control0   # whichever node is the leader
kubectl get nodes
```

Or copy it off the leader after the cluster is ready:
```bash
ssh control0 cat /root/.kube/config > /root/.kube/config
kubectl get nodes
```

---

## Reconfigure and Deploy (all approaches)

After making any overlay changes (security mode, YAML manifests, etc.):

```bash
wwctl configure -a
wwctl overlay build
wwctl ssh control[0-99] reboot
wwctl ssh worker[0-99] reboot
```

The cluster is recreated from scratch. The `rebuild-and-restart.sh` script automates clearing `/share` and rebooting all nodes.

---

## How It Works

When nodes start:
1. The `k8s-install` systemd service runs `/k8s-helper/k8s-install-final.sh` on every node.
2. The first control node to reach the leader-election point wins by atomically creating `/share/leader` (noclobber). It becomes the **leader**.
3. The leader and all other control nodes start the **Phylactery** service, which:
   - Announces the node's hostname and IP into `/share/phylactery/` for HAProxy peer discovery.
   - Removes any stale entry for this node from the Kubernetes node list and etcd member list (from a previous boot), using a kubeconfig appropriate to the active security mode.
   - Starts an HTTP server on port 9999 so other nodes can trigger a HAProxy config reload.
4. The leader deletes any stale `leader_ready` file, runs `kubeadm init`, binds the VIP (`10.0.0.99`), applies the Flannel CNI, and then distributes credentials according to `SECURITY_MODE`:
   - **APPROACH_1**: copies admin kubeconfig and full PKI to `/share`.
   - **APPROACH_2**: uploads admin kubeconfig and PKI subset to the secure file server; writes only the bootstrap join command to `/share`.
   - **APPROACH_3**: writes a scoped bootstrap token, a kubeadm certificate key, and a Phylactery SA kubeconfig to `/share`; raw PKI keys stay encrypted in etcd.
5. The leader touches `/share/leader_ready`.
6. Control-plane followers and worker nodes see `leader_ready` and join the cluster using the credentials appropriate to the active mode.

When a node reboots:
- Warewulf re-provisions it from the base image (including any Warewulf overlay keys for APPROACH_2).
- Phylactery removes the stale cluster entries.
- The node rejoins using the current credentials on `/share` (or the secure server for APPROACH_2).
- For APPROACH_2, the node key is re-delivered by Warewulf and deleted again after a successful join.

---

## Limitations

- etcd supports recovery from up to `(N-1)/2` nodes failing. For a 3-node cluster that is 1 node. If 2 out of 3 nodes fail, the cluster cannot recover automatically (see https://etcd.io/docs/v3.5/op-guide/recovery/). In this case, reboot all nodes to fully reset the cluster.
- The cluster is entirely ephemeral (RAM-based tmpfs). Any in-cluster data (PVCs, ConfigMaps, etc.) is lost on full cluster reboot unless backed by external persistent storage.
- For APPROACH_2, the secure file server must be running on the cluster manager before nodes boot. If the server is down, followers will wait indefinitely for credential download.
