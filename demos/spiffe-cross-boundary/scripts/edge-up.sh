#!/usr/bin/env bash
# Box B (the on-prem store). On Linux this is a libvirt VM on virbr0 -- the
# recommended topology. On macOS it falls back to Lima.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -s)" = "Linux" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib-libvirt.sh"     # NB: resets HERE to the demo root
  vm_create "$EDGE_VM" "$EDGE_ADDR" "$EDGE_CPUS" "${EDGE_MEM_MIB:-2048}" "${EDGE_DISK_GB:-20}" \
    curl iptables jq docker.io
  vm_wait_ready "$EDGE_VM" "$EDGE_ADDR"
  vm_push_repo "$EDGE_ADDR"
  write_ssh_config
  vm_ssh "$EDGE_ADDR" 'uname -m && echo edge-vm-ready'
else
  # shellcheck source=/dev/null
  . "$SCRIPTS/lib-vm.sh"          # NB: resets HERE to the demo root
  vm_start "$EDGE_VM" "$HERE/provisioners/lima/edge.yaml" "$EDGE_CPUS" "$EDGE_MEM"
  vm_shell "$EDGE_VM" bash -lc 'uname -m && echo edge-vm-ready'
fi
