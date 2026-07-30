#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-vm.sh"
for vm in "$CLUSTER_VM" "$EDGE_VM"; do
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
    log "stopping+deleting $vm"; limactl stop -f "$vm" 2>/dev/null || true; limactl delete "$vm" 2>/dev/null || true
  fi
done
