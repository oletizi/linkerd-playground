#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vm.sh"
vm_start "$EDGE_VM" "$HERE/../provisioners/lima/edge.yaml" "$EDGE_CPUS" "$EDGE_MEM"
vm_shell "$EDGE_VM" -- bash -lc 'uname -m && echo edge-vm-ready'
