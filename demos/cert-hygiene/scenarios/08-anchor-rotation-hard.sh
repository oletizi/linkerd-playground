#!/usr/bin/env bash
# Scenario S-hard (design section 7): the trust anchor and issuer are replaced in one
# step (--force, no bundle) at T_mark. No restarts until every unrestarted endpoint's
# old leaf has expired and failed, or it renewed, within S_HARD_STAGE1_TIMEOUT_S; then
# the matrix stages: client A, server, everything else. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

# shellcheck disable=SC2034
POST_EXPIRY_WINDOW_S=0   # no post window: stage 1 is condition-driven
S_SWAP_EPOCH=0

scenario_mark_epoch() {
  echo $(( $(date -u +%s) + FAULT_LEAD_S ))
}

scenario_fault() { # the hard swap
  local new="$CERTS/new"
  make_trust_anchor "$new" "$NEW_ANCHOR_LIFETIME"
  make_issuer "$new" "$REPLACEMENT_ISSUER_LIFETIME" "$new"
  write_cert trust-anchor-new "$new/ca.crt"
  write_cert issuer-new "$new/issuer.crt"
  S_SWAP_EPOCH="$(date -u +%s)"
  mark s-hard-swap "linkerd upgrade with a new anchor and issuer in one step, --force, no bundle"
  capture swap/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-trust-anchors-file='$new/ca.crt' --identity-issuer-certificate-file='$new/issuer.crt' --identity-issuer-key-file='$new/issuer.key' --force | kubectl apply -f -"
  capture_cp_rollouts swap/rollout.txt
  snap_controlplane swap-after
}

scenario_post_actions() { mark post-actions-none "S-hard: no post-actions"; }

_s_hard_stage1() { # no restarts until every endpoint meets the stage-1 condition, or timeout
  local deadline=$(( S_SWAP_EPOCH + S_HARD_STAGE1_TIMEOUT_S )) n=1 f="$RUN_DIR/s-hard/stage1.txt"
  local tmp met result role d pod now state
  mkdir -p "$RUN_DIR/s-hard"
  tmp="$(mktemp -d)"
  mark stage "s-hard stage 1: no restarts until each endpoint's old leaf has expired and failed, or it renewed (timeout ${S_HARD_STAGE1_TIMEOUT_S}s after the swap)"
  while :; do
    tick "stage1-$n"
    now="$(awk -F= '$1 == "sampled_at_epoch" { print $2 }' "$RUN_DIR/metrics/stage1-$n.txt")"
    kubectl -n "$LAB_NS" logs "$(_current_pod probe-tcp-new)" -c probe > "$tmp/clientA" 2>&1 || true
    kubectl -n "$LAB_NS" logs "$(_current_pod probe-tcp-new-b)" -c probe > "$tmp/clientB" 2>&1 || true
    sort "$tmp/clientA" "$tmp/clientB" > "$tmp/server"   # time order: the first failure is the earliest
    met=yes
    for role in clientA:probe-tcp-new clientB:probe-tcp-new-b server:server; do
      d="${role#*:}"; pod="$(_current_pod "$d")"
      pod_section "$RUN_DIR/metrics/fault-minus10.txt" "$pod" > "$tmp/before"
      pod_section "$RUN_DIR/metrics/stage1-$n.txt" "$pod" > "$tmp/now"
      kubectl -n "$LAB_NS" logs "$pod" -c linkerd-proxy --timestamps > "$tmp/proxy-${role%%:*}" 2>&1 || true
      if ! state="$(s_hard_endpoint_state "$S_SWAP_EPOCH" "$now" "$tmp/before" "$tmp/now" "$tmp/${role%%:*}" "$tmp/proxy-${role%%:*}")"; then met=no; fi
      printf 'tick=stage1-%s role=%s pod=%s %s\n' "$n" "${role%%:*}" "$pod" "$state" >> "$f"
    done
    if [ "$met" = yes ]; then result=met; break; fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then result=timeout; break; fi
    n=$((n + 1))
    sleep "$OBSERVE_INTERVAL_S"
  done
  rm -rf "$tmp"
  { echo "result=$result"; echo "swap_epoch=$S_SWAP_EPOCH"; echo "timeout_s=$S_HARD_STAGE1_TIMEOUT_S"; cat "$f"; } \
    > "$RUN_DIR/s-hard/stage1-condition.txt"
  mark stage "s-hard stage 1: $result"
}

scenario_recover() {
  _s_hard_stage1
  stage_samples stage1-norestart
  matrix_restart_stages
}

run_scenario 08-anchor-rotation-hard long "${1:?usage: 08-anchor-rotation-hard.sh <run-dir>}"
