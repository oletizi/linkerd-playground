#!/usr/bin/env bash
# Runs on the macOS HOST. Writes config.local.env from the addresses OrbStack has
# actually assigned, so nobody transcribes an address or pastes a pipeline.
#
# Re-run it every time the machines are recreated: config.local.env is gitignored,
# so it outlives the boxes it names, and a stale one is copied into the fresh
# guests where it fails much later as "cannot reach the cluster node".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$DEMO/../.." && pwd)/lib/common.sh"

command -v orb >/dev/null 2>&1 || die "orb not found. This script is for the OrbStack topology
  (see README-ORBSTACK.md); on libvirt, cluster-up/edge-up assign the addresses."

CLUSTER_VM="${CLUSTER_VM:-linkerd-cluster}"
EDGE_VM="${EDGE_VM:-linkerd-edge}"

# One `orb list` for both, so the two addresses cannot come from different moments.
listing="$(orb list 2>/dev/null || true)"
addr_of() { printf '%s\n' "$listing" | awk -v n="$1" '$1==n && $2=="running" {print $NF}'; }

cluster_addr="$(addr_of "$CLUSTER_VM")"
edge_addr="$(addr_of "$EDGE_VM")"

for pair in "$CLUSTER_VM:$cluster_addr" "$EDGE_VM:$edge_addr"; do
  name="${pair%%:*}"; addr="${pair#*:}"
  [ -n "$addr" ] || die "no running OrbStack machine called '$name'.
  Create the machines first (README-ORBSTACK.md step 1). Current machines:
$(printf '%s\n' "$listing" | sed 's/^/    /')"
done

out="$DEMO/config.local.env"
printf 'CLUSTER_NODE_ADDR=%s\nEDGE_ADDR=%s\n' "$cluster_addr" "$edge_addr" > "$out"

log "wrote $out"
sed 's/^/  /' "$out"
log "now copy the repo into both machines (README-ORBSTACK.md step 3) so they get this file"
