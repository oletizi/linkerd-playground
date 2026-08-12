#!/usr/bin/env bash
# Destroy both boxes. On Linux, removes the libvirt domains and their volumes.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -s)" = "Linux" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib-libvirt.sh"
  for vm in "$CLUSTER_VM" "$EDGE_VM"; do
    if vm_exists "$vm"; then
      log "destroying $vm"
      virsh -c qemu:///system destroy "$vm" >/dev/null 2>&1 || true
      virsh -c qemu:///system undefine "$vm" --remove-all-storage >/dev/null 2>&1 \
        || virsh -c qemu:///system undefine "$vm" >/dev/null 2>&1 || true
    else
      log "$vm not defined"
    fi
    # The seed ISO is not always caught by --remove-all-storage.
    virsh -c qemu:///system vol-delete --pool default "${vm}-seed.iso" >/dev/null 2>&1 || true
    virsh -c qemu:///system vol-delete --pool default "${vm}.qcow2"    >/dev/null 2>&1 || true
  done
else
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib-vm.sh"
  for vm in "$CLUSTER_VM" "$EDGE_VM"; do
    if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
      log "stopping+deleting $vm"; limactl stop -f "$vm" 2>/dev/null || true; limactl delete "$vm" 2>/dev/null || true
    fi
  done
fi
