#!/usr/bin/env bash
# Scenario R (design section 2): slice 1's issuer expiry (#5), re-run. The identity
# issuer expires mid-run while the trust anchor and its key stay valid; T_mark is the
# issuer's notAfter. After a 1800 s post-expiry window, recovery signs a replacement
# issuer from the SAME anchor, applies it the documented way, and then maps endpoint
# state through four gated stages: no restarts; client A; server; everything else.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  cert_not_after_epoch "$CERTS/issuer.crt"
}

scenario_recover() {
  local rep="$CERTS/replacement"
  # The replacement is signed by the EXISTING anchor; nothing here touches the trust
  # roots. The credential plan (A/I1 -> A/I2) verifies both.
  make_issuer "$rep" "$REPLACEMENT_ISSUER_LIFETIME" "$CERTS"
  write_cert issuer-replacement "$rep/issuer.crt"
  mark recover-apply "linkerd upgrade with the replacement issuer; no trust-anchor flag"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$rep/issuer.crt' --identity-issuer-key-file='$rep/issuer.key' | kubectl apply -f -"
  wait_issuer_updated 180
  snap_events issuer-updated
  snap_controlplane recover-applied
  restart_stages
}

run_scenario 05-issuer-expiry issuer-short "${1:?usage: 05-issuer-expiry.sh <run-dir>}"
