#!/usr/bin/env bash
# One-time host setup for the Linux single-host topology (both boxes as libvirt
# VMs). Run ONCE, as root:
#
#     sudo bash scripts/host-setup.sh
#
# Then LOG OUT AND BACK IN — group membership is only picked up by a new login
# session. Everything after this runs as your normal user.
#
# To undo: sudo apt-get purge libvirt-daemon-system libvirt-clients virtinst \
#            cloud-image-utils && sudo gpasswd -d "$USER" libvirt
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run me as root: sudo bash $0" >&2; exit 1; }

TARGET_USER="${SUDO_USER:-${1:-}}"
[ -n "$TARGET_USER" ] || { echo "cannot tell which user to grant libvirt access to; pass it as an argument" >&2; exit 1; }

echo "== installing libvirt/KVM =="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y libvirt-daemon-system libvirt-clients virtinst cloud-image-utils qemu-system-x86

echo "== enabling libvirtd and the default network =="
systemctl enable --now libvirtd
virsh net-autostart default >/dev/null 2>&1 || true
virsh net-start default >/dev/null 2>&1 || true
virsh net-info default | sed -n '1,4p'

echo "== storage pool =="
# Distros differ: some ship a pool called 'default', Ubuntu 26.04 ships 'images',
# and some ship none. The demo discovers the name; here we just guarantee one exists.
if ! virsh pool-list --name | grep -q .; then
  echo "no storage pool defined; creating 'default' at /var/lib/libvirt/images"
  virsh pool-define-as default dir --target /var/lib/libvirt/images
  virsh pool-build default || true
  virsh pool-start default
  virsh pool-autostart default
fi
virsh pool-list

echo "== granting ${TARGET_USER} libvirt access =="
usermod -aG libvirt,kvm "$TARGET_USER"

cat <<EOF

Host setup complete.

  !! LOG OUT AND BACK IN NOW !!

Group membership (libvirt, kvm) only applies to new login sessions, so until you
do, 'just demo spiffe-cross-boundary cluster-up' will fail with a permission
error on /var/run/libvirt/libvirt-sock.

Verify with:   virsh -c qemu:///system list --all
EOF
