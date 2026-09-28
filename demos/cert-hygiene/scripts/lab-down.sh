#!/usr/bin/env bash
# Runs on the macOS HOST. Deletes the lab machine and everything in it, including
# the lab's private keys under $HOME/cert-hygiene-certs (they never leave the VM).
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb

if orb list 2>/dev/null | awk '{print $1}' | grep -qx "$LAB_VM"; then
  log "deleting $LAB_VM"
  orb delete "$LAB_VM"
else
  log "$LAB_VM does not exist"
fi
