#!/bin/bash
# ==============================================================================
# SCRIPT 1: BASE INSTALLATION
# ==============================================================================
# Runs ONCE on the Warewulf manager node.
# Handles: system prep, SSH keys, Warewulf install + config, Git clone,
#          K8s image build, Slurm image build, security server, overlays.
#
# After this script completes, run:
#   ./02-provision-k8s.sh    (provisions K8s nodes)
#   ./03-provision-slurm.sh  (provisions Slurm nodes)
#   ./04-balancer.sh         (starts dynamic node transitions)
# ==============================================================================
set -e

SCRIPT_NAME="base-install"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Read settings from node-config.conf
MANAGER_IP=$(get_setting "MANAGER_IP")
MANAGER_IFACE=$(get_setting "MANAGER_IFACE")
MANAGER_NETMASK=$(get_setting "MANAGER_NETMASK")
MANAGER_SUBNET=$(get_setting "MANAGER_SUBNET")
DHCP_START=$(get_setting "DHCP_START")
DHCP_END=$(get_setting "DHCP_END")
SLURM_VERSION=$(get_setting "SLURM_VERSION")
SECURITY_MODE=$(get_setting "SECURITY_MODE")
REPO_URL=$(get_setting "REPO_URL")
REPO_BRANCH=$(get_setting "REPO_BRANCH")

WORKING_DIR="/root"
CLONE_DIR="pub-2025-ephemeral-kubernetes"

log_separator
log "SCRIPT 1: BASE INSTALLATION"
log "  Manager IP:    $MANAGER_IP"
log "  Slurm Version: $SLURM_VERSION"
log "  Security Mode: $SECURITY_MODE"
log_separator

# ==============================================================================
# PHASE 1: System Prep & SSH Keys
# ==============================================================================
log "PHASE 1: System preparation..."
cd "$WORKING_DIR"
dnf update -y
dnf install -y git nano tcpdump podman podman-docker

if [ ! -f /root/.ssh/id_rsa ]; then
    log "Generating SSH keys for manager..."
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
fi

rm -rf "$CLONE_DIR"
git clone -b "$REPO_BRANCH" --single-branch "$REPO_URL" "$CLONE_DIR"
log "Git repo cloned."

# ==============================================================================
# PHASE 2: Network & Warewulf Setup
# ==============================================================================
log "PHASE 2: Warewulf configuration..."

nmcli con add type ethernet ifname "$MANAGER_IFACE" con-name "$MANAGER_IFACE" \
    ipv4.method manual ipv4.addresses "$MANAGER_IP/24" || true
nmcli con up "$MANAGER_IFACE"

dnf install -y https://github.com/warewulf/warewulf/releases/download/v4.5.8/warewulf-4.5.8-1.el9.x86_64.rpm

cat << EOF > /etc/warewulf/warewulf.conf
WW_INTERNAL: 45
ipaddr: $MANAGER_IP
netmask: $MANAGER_NETMASK
network: $MANAGER_SUBNET
warewulf:
  port: 9873
  secure: false
  update interval: 60
  autobuild overlays: true
  host overlay: true
  syslog: false
  datastore: /usr/share
  grubboot: false
dhcp:
  enabled: true
  template: static
  range start: $DHCP_START
  range end: $DHCP_END
  systemd name: dhcpd
tftp:
  enabled: true
  tftproot: /var/lib/tftpboot
  systemd name: tftp
  ipxe:
    "00:00": undionly.kpxe
    "00:07": ipxe-snponly-x86_64.efi
    "00:09": ipxe-snponly-x86_64.efi
    00:0B: arm64-efi/snponly.efi
nfs:
  enabled: true
  export paths:
  - path: /home
    export options: rw,sync
    mount options: defaults
    mount: true
  - path: /share
    export options: rw,sync,no_root_squash
    mount options: defaults
    mount: true
  systemd name: nfs-server
ssh:
  key types: [rsa, dsa, ecdsa, ed25519]
container mounts:
- source: /etc/resolv.conf
  dest: /etc/resolv.conf
  readonly: true
paths:
  bindir: /usr/bin
  sysconfdir: /etc
  localstatedir: /var/lib
  ipxesource: /usr/share/ipxe
  srvdir: /var/lib
  firewallddir: /usr/lib/firewalld/services
  systemddir: /usr/lib/systemd/system
  wwoverlaydir: /var/lib/warewulf/overlays
  wwchrootdir: /var/lib/warewulf/chroots
  wwprovisiondir: /var/lib/warewulf/provision
  wwclientdir: /warewulf
wwclient: null
EOF

wwctl configure --all --yes
systemctl enable --now warewulfd
log "Warewulf configured and running."

# ==============================================================================
# PHASE 3: Build K8s OS Images
# ==============================================================================
log "PHASE 3: Building Kubernetes OS images..."
cd "$WORKING_DIR/$CLONE_DIR/k8s-images"
chmod +x *.sh
./download-images.sh
./copy-images.sh

cd ../ww-image-builder
chmod +x *.sh
./build-and-import.sh
log "Kubernetes images built."

# ==============================================================================
# PHASE 4: Build Slurm OS Images
# ==============================================================================
log "PHASE 4: Building Slurm OS images..."

SLURM_IMAGE_NAME="slurm-compute-ww"
SLURM_CTRL_IMAGE_NAME="slurm-ctrl-ww"

# --- Slurm compute image ---
wwctl container import docker://ghcr.io/warewulf/warewulf-rockylinux:9 "$SLURM_IMAGE_NAME" || true

wwctl container shell "$SLURM_IMAGE_NAME" <<CONTAINER_EOF
    dnf install -y epel-release
    /usr/bin/crb enable

    dnf install -y \
        munge munge-libs munge-devel \
        rpm-build gcc openssl openssl-devel \
        autoconf automake libtool \
        pam-devel numactl numactl-devel \
        hwloc hwloc-devel lua lua-devel \
        readline-devel rrdtool-devel ncurses-devel \
        libibmad libibumad perl-ExtUtils-MakeMaker \
        mariadb-devel man2html \
        wget bzip2 make \
        iproute net-tools openssh-server openssh-clients \
        python3 python3-pip \
        nfs-utils

    cd /tmp
    wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2
    rpmbuild -ta slurm-${SLURM_VERSION}.tar.bz2
    dnf localinstall -y /root/rpmbuild/RPMS/x86_64/slurm-*.rpm || true

    systemctl enable munge
    systemctl enable slurmd
    systemctl enable sshd

    rm -rf /tmp/slurm-* /root/rpmbuild
    dnf clean all
CONTAINER_EOF

log "Slurm compute image built."

# --- Slurm controller image ---
wwctl container import docker://ghcr.io/warewulf/warewulf-rockylinux:9 "$SLURM_CTRL_IMAGE_NAME" || true

wwctl container shell "$SLURM_CTRL_IMAGE_NAME" <<CONTAINER_EOF
    dnf install -y epel-release
    /usr/bin/crb enable

    dnf install -y \
        munge munge-libs munge-devel \
        rpm-build gcc openssl openssl-devel \
        autoconf automake libtool \
        pam-devel numactl numactl-devel \
        hwloc hwloc-devel lua lua-devel \
        readline-devel rrdtool-devel ncurses-devel \
        libibmad libibumad perl-ExtUtils-MakeMaker \
        mariadb-devel man2html \
        wget bzip2 make \
        iproute net-tools openssh-server openssh-clients \
        python3 python3-pip \
        nfs-utils

    cd /tmp
    wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2
    rpmbuild -ta slurm-${SLURM_VERSION}.tar.bz2
    dnf localinstall -y /root/rpmbuild/RPMS/x86_64/slurm-*.rpm || true

    systemctl enable munge
    systemctl enable slurmctld
    systemctl enable sshd

    rm -rf /tmp/slurm-* /root/rpmbuild
    dnf clean all
CONTAINER_EOF

log "Slurm controller image built."

# ==============================================================================
# PHASE 5: Security Server & Token Generation
# ==============================================================================
log "PHASE 5: Setting up security server..."
cd "$WORKING_DIR/$CLONE_DIR/secure"
chmod +x *.sh
./secure-setup.sh
./generate-tokens.sh
systemctl daemon-reload
systemctl enable --now ww-secure-server
systemctl restart ww-secure-server
log "Security server running."

# ==============================================================================
# PHASE 6: SSH Key Injection into Warewulf wwinit Overlay
# ==============================================================================
log "PHASE 6: Injecting SSH keys into wwinit overlay..."
mkdir -p /var/lib/warewulf/overlays/wwinit/rootfs/root/.ssh/
cp /root/.ssh/id_rsa.pub /var/lib/warewulf/overlays/wwinit/rootfs/root/.ssh/authorized_keys
chmod 600 /var/lib/warewulf/overlays/wwinit/rootfs/root/.ssh/authorized_keys

# ==============================================================================
# PHASE 7: K8s Overlay Preparation
# ==============================================================================
log "PHASE 7: Preparing Kubernetes overlay..."
mkdir -p /var/lib/warewulf/overlays/k8s-overlay/rootfs/
cp -r "$WORKING_DIR/$CLONE_DIR/k8s-overlay/"* /var/lib/warewulf/overlays/k8s-overlay/rootfs/
cp "$WORKING_DIR/$CLONE_DIR/k8s-overlay/k8s-helper/k8s-install-final.sh" \
   /var/lib/warewulf/overlays/k8s-overlay/rootfs/k8s-helper/k8s-install.sh

sed -i "s/10.0.0.3/$MANAGER_IP/g" \
    /var/lib/warewulf/overlays/k8s-overlay/rootfs/k8s-helper/k8s-install.sh
sed -i "s/SECURITY_MODE=\"\${SECURITY_MODE:-APPROACH_3}\"/SECURITY_MODE=\"\${SECURITY_MODE:-$SECURITY_MODE}\"/g" \
    /var/lib/warewulf/overlays/k8s-overlay/rootfs/k8s-helper/k8s-install.sh

find /var/lib/warewulf/overlays/k8s-overlay/ -name "*.sh" -exec chmod +x {} +
log "K8s overlay ready."

# ==============================================================================
# PHASE 8: Slurm Overlay Preparation
# ==============================================================================
log "PHASE 8: Preparing Slurm overlay..."

SLURM_OVERLAY_DIR="/var/lib/warewulf/overlays/slurm-overlay"
SLURM_OVERLAY_ROOT="$SLURM_OVERLAY_DIR/rootfs"

rm -rf "$SLURM_OVERLAY_DIR"
mkdir -p "$SLURM_OVERLAY_ROOT/etc/slurm"
mkdir -p "$SLURM_OVERLAY_ROOT/etc/munge"
mkdir -p "$SLURM_OVERLAY_ROOT/opt/slurm"

# Generate munge key
MUNGE_KEY_FILE="/etc/munge/munge.key"
if [ ! -f "$MUNGE_KEY_FILE" ]; then
    dnf install -y munge || true
    create-munge-key -f
fi
cp "$MUNGE_KEY_FILE" "$SLURM_OVERLAY_ROOT/etc/munge/munge.key"
chmod 400 "$SLURM_OVERLAY_ROOT/etc/munge/munge.key"

# cgroup.conf
cat << EOF > "$SLURM_OVERLAY_ROOT/etc/slurm/cgroup.conf"
CgroupAutomount=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
EOF

# slurm-install.sh (boot-time script for Slurm nodes)
cat << 'SCRIPT_EOF' > "$SLURM_OVERLAY_ROOT/opt/slurm/slurm-install.sh"
#!/bin/bash
set -e
HOSTNAME=$(hostname)
echo "[slurm-install] Starting Slurm setup on $HOSTNAME..."

chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

mkdir -p /var/spool/slurmd /var/spool/slurmctld /var/log
chown slurm:slurm /var/spool/slurmd 2>/dev/null || true
chown slurm:slurm /var/spool/slurmctld 2>/dev/null || true

echo "[slurm-install] Starting munge..."
systemctl restart munge
sleep 2

if ! munge -n | unmunge > /dev/null 2>&1; then
    echo "[slurm-install] ERROR: Munge verification failed!"
    exit 1
fi
echo "[slurm-install] Munge verified."

ROLE="${NODE_ROLE:-slurm-compute}"

if [ "$ROLE" = "slurm-controller" ]; then
    echo "[slurm-install] Starting slurmctld (controller)..."
    systemctl restart slurmctld
    systemctl enable slurmctld
    echo "[slurm-install] Slurmctld started."
else
    echo "[slurm-install] Starting slurmd (compute)..."
    systemctl restart slurmd
    systemctl enable slurmd
    echo "[slurm-install] Slurmd started. Registering with controller..."

    for i in $(seq 1 30); do
        if sinfo > /dev/null 2>&1; then
            echo "[slurm-install] Controller reachable. Node $HOSTNAME is active."
            scontrol update NodeName=$HOSTNAME State=IDLE || true
            break
        fi
        echo "[slurm-install] Waiting for controller... ($i/30)"
        sleep 5
    done
fi

echo "[slurm-install] Slurm setup complete on $HOSTNAME."
SCRIPT_EOF

chmod +x "$SLURM_OVERLAY_ROOT/opt/slurm/slurm-install.sh"

# NOTE: slurm.conf is NOT generated here. It is generated by 03-provision-slurm.sh
# because it needs to include all slurm compute nodes + dynamic nodes.

log "Slurm overlay structure ready (slurm.conf will be generated by provision script)."

# ==============================================================================
# PHASE 9: Update /etc/hosts on Manager
# ==============================================================================
log "PHASE 9: Updating manager /etc/hosts..."
update_manager_hosts

# ==============================================================================
# DONE
# ==============================================================================
log_separator
log "BASE INSTALLATION COMPLETE"
log ""
log "Next steps:"
log "  1. Edit node-config.conf with your actual MAC addresses and IPs"
log "  2. Run: ./02-provision-k8s.sh"
log "  3. Run: ./03-provision-slurm.sh"
log "  4. Run: ./04-balancer.sh"
log_separator
