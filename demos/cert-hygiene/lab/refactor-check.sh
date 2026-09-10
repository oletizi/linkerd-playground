#!/usr/bin/env bash
# Runs INSIDE the lab VM. Runs the SPIFFE demo's three cluster-side scripts on a clean
# box and records what they print, so the lib/ refactor can be compared against the
# behaviour it replaced (design spec section 1.4). Usage: refactor-check.sh <out-dir>
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

out="${1:?usage: refactor-check.sh <out-dir>}"
[ ! -e "$out" ] || die "$out already exists; refusing to overwrite recorded output"
mkdir -p "$out"
spiffe="$ROOT/demos/spiffe-cross-boundary/cluster"

run_step() { # name script
  local name="$1" script="$2" rc=0
  log "running $name"
  bash "$script" > "$out/$name.log" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$out/$name.log"
  [ "$rc" -eq 0 ] || die "$name failed (exit $rc); see $out/$name.log"
}

run_step gen-certs "$spiffe/gen-certs.sh"
run_step install-k3s "$spiffe/install-k3s.sh"
run_step install-linkerd "$spiffe/install-linkerd.sh"

rc=0
linkerd check > "$out/linkerd-check.txt" 2>&1 || rc=$?
printf '[exit %s]\n' "$rc" >> "$out/linkerd-check.txt"
linkerd version > "$out/linkerd-version.txt" 2>&1
kubectl get pods -A > "$out/pods.txt"
log "recorded SPIFFE cluster-side behaviour in $out"
