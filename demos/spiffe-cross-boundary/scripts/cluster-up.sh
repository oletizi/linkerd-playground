#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vm.sh"
# NB: lib-vm.sh resets HERE to the demo root, so paths below are relative to that.
vm_start "$CLUSTER_VM" "$HERE/provisioners/lima/cluster.yaml" "$CLUSTER_CPUS" "$CLUSTER_MEM"
vm_shell "$CLUSTER_VM" bash -lc 'uname -m && echo cluster-vm-ready'
