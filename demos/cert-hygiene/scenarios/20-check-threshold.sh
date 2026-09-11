#!/usr/bin/env bash
# Scenario K (design section 5): linkerd check's 60-day issuer warning, bracketed. The
# profile installs an issuer valid for 1440h - 10m; K then applies one valid for
# 1440h + 10m. Each step records both checks with their start and end times and the
# issuer's notAfter, so the remaining validity at check time can be computed.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

_k_measure() { # STEP ISSUER_PEM: both checks, timed, and the recorded calculation
  local step="$1" pem="$2" na cs ce ps pe
  na="$(cert_not_after_epoch "$pem")"
  mark k-measure "$step: issuer notAfter $(date -u -d "@$na" +%Y-%m-%dT%H:%M:%SZ)"
  cs="$(date -u +%s)"; capture "k/$step-check.txt" linkerd check --wait 20s; ce="$(date -u +%s)"
  ps="$(date -u +%s)"; capture "k/$step-check-proxy.txt" linkerd check --proxy --wait 20s; pe="$(date -u +%s)"
  printf 'step=%s\nissuer_not_after_epoch=%s\nthreshold_s=5184000\ncheck_started_epoch=%s\ncheck_ended_epoch=%s\ncheck_proxy_started_epoch=%s\ncheck_proxy_ended_epoch=%s\ncheck_remaining_at_start_s=%s\ncheck_proxy_remaining_at_start_s=%s\n' \
    "$step" "$na" "$cs" "$ce" "$ps" "$pe" $(( na - cs )) $(( na - ps )) > "$RUN_DIR/k/$step-calc.txt"
  tick "k-$step"
}

scenario_steps() {
  local plus="$CERTS/plus"
  mkdir -p "$RUN_DIR/k"
  _k_measure minus "$CERTS/issuer.crt"
  make_issuer "$plus" "$K_PLUS_ISSUER_LIFETIME" "$CERTS"
  write_cert issuer-plus "$plus/issuer.crt"
  mark k-apply "issuer-only linkerd upgrade with a ${K_PLUS_ISSUER_LIFETIME} issuer from the same anchor"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$plus/issuer.crt' --identity-issuer-key-file='$plus/issuer.key' | kubectl apply -f -"
  wait_issuer_updated 180
  _k_measure plus "$plus/issuer.crt"
  _write_result k-remaining.txt k_remaining_check "$RUN_DIR" || true
}

run_steps_scenario 20-check-threshold check-threshold "${1:?usage: 20-check-threshold.sh <run-dir>}"
