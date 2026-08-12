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
fi
