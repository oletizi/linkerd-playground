#!/usr/bin/env bash
# Box A (Kubernetes cluster). On Linux this is a libvirt VM on virbr0 -- the
# recommended topology. On macOS it falls back to Lima.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -s)" = "Linux" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib-libvirt.sh"     # NB: resets HERE to the demo root
  vm_create "$CLUSTER_VM" "$CLUSTER_NODE_ADDR" "$CLUSTER_CPUS" "${CLUSTER_MEM_MIB:-6144}" "${CLUSTER_DISK_GB:-40}" \
    curl iptables jq
  vm_wait_ready "$CLUSTER_VM" "$CLUSTER_NODE_ADDR"
  vm_push_repo "$CLUSTER_NODE_ADDR"
  write_ssh_config
  vm_ssh "$CLUSTER_NODE_ADDR" 'uname -m && echo cluster-vm-ready'
else
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib-vm.sh"          # NB: resets HERE to the demo root
  vm_start "$CLUSTER_VM" "$HERE/provisioners/lima/cluster.yaml" "$CLUSTER_CPUS" "$CLUSTER_MEM"
  vm_shell "$CLUSTER_VM" bash -lc 'uname -m && echo cluster-vm-ready'
  # Lima assigns the address; unlike the libvirt path there is no reservation to
  # pin it, so report it rather than leaving the reader to go looking.
  addr="$(vm_addr "$CLUSTER_VM")"
  [ -n "$addr" ] || die "$CLUSTER_VM has no address on a shared network.
  The two boxes cannot reach each other, so the demo cannot run. The VM should
  have been created with the 'user-v2' network declared in provisioners/lima/."
  log "$CLUSTER_VM is at $addr -- set CLUSTER_NODE_ADDR=$addr in config.local.env"
fi
