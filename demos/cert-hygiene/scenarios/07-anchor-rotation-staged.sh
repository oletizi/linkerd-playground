#!/usr/bin/env bash
# Scenario S-staged (design section 7): the 11 steps of Linkerd's manual trust-anchor
# rotation guide, exactly, from a valid anchor. Each restart step restarts every lab
# Deployment and is gated and sampled; a tick follows every step. Launch with
# scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

_s_upgrade() { # NN ARGS...: linkerd upgrade ARGS | kubectl apply -f -, then control-plane rollouts
  local nn="$1" q=""
  shift
  [ $# -eq 0 ] || q="$(printf ' %q' "$@")"
  capture "steps/s$nn-upgrade.txt" bash -o pipefail -c "linkerd upgrade$q | kubectl apply -f -"
  capture_cp_rollouts "steps/s$nn-rollout.txt"
}

_s_restart() { # NN: restart every meshed lab workload, gated and sampled
  local all=()
  snap_before_restart "pre-s$1"
  mapfile -t all < <(lab_deployments)
  restart_and_gate "s$1-restart" "${all[@]}"
}

scenario_steps() {
  local new="$CERTS/new"
  observe_until $(( $(date -u +%s) + FAULT_LEAD_S )) pre
  mkdir -p "$RUN_DIR/steps"

  mark s01 "create a new trust anchor"
  make_trust_anchor "$new" "$NEW_ANCHOR_LIFETIME"
  write_cert trust-anchor-new "$new/ca.crt"
  tick s01-new-anchor

  mark s02 "bundle it with the old one (step certificate bundle)"
  step certificate bundle "$new/ca.crt" "$CERTS/ca.crt" "$CERTS/bundle.crt"
  write_cert trust-bundle "$CERTS/bundle.crt"
  tick s02-bundle

  mark s03 "linkerd upgrade --identity-trust-anchors-file=bundle.crt"
  _s_upgrade 03 --identity-trust-anchors-file="$CERTS/bundle.crt"
  tick s03-upgrade-bundle

  mark s04 "restart the meshed workloads"
  _s_restart 04
  tick s04-restart

  mark s05 "linkerd check --proxy"
  capture steps/s05-check-proxy.txt linkerd check --proxy --wait 20s
  tick s05-check

  mark s06 "create a new issuer signed by the new anchor"
  make_issuer "$CERTS/issuer-new" "$REPLACEMENT_ISSUER_LIFETIME" "$new"
  write_cert issuer-new "$CERTS/issuer-new/issuer.crt"
  tick s06-new-issuer

  mark s07 "apply the new issuer (issuer-only linkerd upgrade)"
  _s_upgrade 07 --identity-issuer-certificate-file="$CERTS/issuer-new/issuer.crt" \
    --identity-issuer-key-file="$CERTS/issuer-new/issuer.key"
  wait_issuer_updated 180
  tick s07-apply-issuer

  mark s08 "restart the meshed workloads"
  _s_restart 08
  tick s08-restart

  mark s09 "linkerd check --proxy"
  capture steps/s09-check-proxy.txt linkerd check --proxy --wait 20s
  tick s09-check

  mark s10 "linkerd upgrade --identity-trust-anchors-file=ca-new.crt"
  _s_upgrade 10 --identity-trust-anchors-file="$new/ca.crt"
  tick s10-new-anchor-only

  mark s11 "restart the meshed workloads, and run linkerd check --proxy"
  _s_restart 11
  capture steps/s11-check-proxy.txt linkerd check --proxy --wait 20s
  tick s11-restart-check
}

run_steps_scenario 07-anchor-rotation-staged long "${1:?usage: 07-anchor-rotation-staged.sh <run-dir>}"
