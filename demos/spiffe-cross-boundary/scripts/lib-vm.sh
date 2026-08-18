#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"
load_config "$HERE"
require_cmd limactl

vm_running() { limactl list --format '{{.Name}}:{{.Status}}' 2>/dev/null | grep -q "^$1:Running$"; }

vm_start() { # name yaml cpus mem
  local name="$1" yaml="$2" cpus="$3" mem="$4"
  if vm_running "$name"; then log "$name already running"; return 0; fi
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$name"; then
    log "starting existing $name"; limactl start "$name"
  else
    log "creating $name"; limactl start --name="$name" --cpus="$cpus" --memory="${mem%GiB}" --tty=false "$yaml"
  fi
}

vm_shell() { local name="$1"; shift; limactl shell "$name" -- "$@"; }

# vm_addr <name>: the guest's address on the shared network -- the one the OTHER
# box reaches it on. Skips docker0 and Lima's default user-mode NAT range
# (192.168.5.0/24), which is per-guest and identical in every VM, so it is never
# the address to hand the other box.
vm_addr() {
  limactl shell "$1" -- bash -lc \
    'ip -4 -o addr show scope global \
       | awk "\$2 !~ /^docker/ {print \$4}" | cut -d/ -f1 \
       | grep -v "^192\.168\.5\." | head -1'
}
