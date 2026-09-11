#!/usr/bin/env bash
# Runs INSIDE the lab VM. One full snapshot of the current lab into a fresh directory,
# using every collector function once. For exercising the collector and for poking
# at a lab by hand; it is not scenario evidence. Usage: snapshot-once.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"

RUN_DIR="${1:?usage: snapshot-once.sh <out-dir>}"
[ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists; refusing to overwrite"
mkdir -p "$RUN_DIR"
since="$(date -u +%s)"
# shellcheck disable=SC2012
certs="$(ls -dt "$CERTS_ROOT"/*/ | head -n 1)"
[ -n "$certs" ] || die "no cert set under $CERTS_ROOT; run a reset first"

mark snapshot-start
write_versions snapshot-once "$(basename "$certs")"
write_cert trust-anchor "$certs/ca.crt"
write_cert issuer-initial "$certs/issuer.crt"
tick manual
snap_secret manual
snap_trust manual
snap_pod_detail manual restart-target
snap_logs manual
snap_events manual
snap_journal manual "$(( since - 600 ))"
snap_probes
assert_no_keys
# shellcheck disable=SC1010
mark done
log "snapshot written to $RUN_DIR"
