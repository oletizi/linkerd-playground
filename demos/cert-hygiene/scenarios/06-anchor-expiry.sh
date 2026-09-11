#!/usr/bin/env bash
# Scenario A (design section 6): a 20-minute trust anchor expires while its 120-minute
# issuer is still within its dates. T_mark is the anchor's notAfter. Recovery follows
# Linkerd's root-and-issuer replacement in named stages: apply; no manual restarts
# (with a canary that can only become Ready on a new-anchor leaf); an identity and
# control-plane restart only if needed; gated workload restarts; verify.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

A_APPLY_EPOCH=0

scenario_mark_epoch() {
  cert_not_after_epoch "$CERTS/ca.crt"
}

_a_canary_state() { # one line "state=<proven|no-proxy|waiting> pod=... proxy=... trust=... ready=... started=... refresh=..."
  # proven: Ready, injected (a linkerd-proxy container), carrying the current trust bundle,
  # and its proxy obtained a leaf after the pod started. Only then does Ready mean identity
  # issued a new-anchor leaf; a pod admitted without a proxy is Ready at once.
  local js pod="" start="" proxy="" trust="" ready="" refresh state=waiting
  js="$(kubectl -n "$LAB_NS" get pods -l app=identity-canary -o json 2>/dev/null || true)"
  if [ -z "$js" ]; then echo "state=waiting pod=- reason=pod-list-unreadable"; return 0; fi
  read -r pod start proxy trust ready < <(jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | first // empty
      | [ .metadata.name,
          ((.status.startTime // "") | if . == "" then "0" else (fromdateiso8601 | tostring) end),
          (if ([.spec.initContainers[]?.name, .spec.containers[].name] | index("linkerd-proxy")) then "yes" else "no" end),
          (.metadata.annotations["linkerd.io/trust-root-sha256"] // "-"),
          (([.status.conditions[]? | select(.type == "Ready") | .status] | first) // "False") ] | join(" ")' \
      <<< "$js" 2>/dev/null) || true
  if [ -z "$pod" ]; then echo "state=waiting pod=-"; return 0; fi
  refresh="$(_leaf_state "$pod" | awk '{ print $1 }')"
  if [ "$proxy" = no ]; then
    state=no-proxy
  elif [ "$ready" = True ] && [ "$(_trust_yn "$trust" "$(_trust_now)")" = yes ] \
      && awk -v r="$refresh" -v s="$start" 'BEGIN { exit !(r != "-" && r + 0 > s + 0) }'; then
    state=proven
  fi
  echo "state=$state pod=$pod proxy=$proxy trust=$trust ready=$ready started=$start refresh=$refresh"
}

_a_canary_ready() { # STAGE TIMEOUT_S: ticks until identity-canary is proven (0) or TIMEOUT_S passes (1)
  local stage="$1" deadline=$(( $(date -u +%s) + $2 )) n=1 t0 s
  t0="$(date -u +%s)"
  while :; do
    tick "$stage-$n"
    capture "recover/$stage-canary-$n.txt" kubectl -n "$LAB_NS" get pods -l app=identity-canary -o wide
    s="$(_a_canary_state)"
    echo "$s" > "$RUN_DIR/recover/$stage-canary-$n-state.txt"
    case "$s" in
      state=proven*)
        mark a-canary "$stage: Ready with a new-anchor leaf $(( $(date -u +%s) - t0 ))s into the stage: $s"
        return 0 ;;
      state=no-proxy*)
        mark a-canary "$stage: admitted without a proxy, so its readiness proves nothing; re-applying: $s"
        # shellcheck disable=SC2016
        capture "recover/$stage-canary-reapply-$n.txt" bash -c \
          'kubectl -n "$1" delete deploy identity-canary --wait=true && bash "$2/deploy.sh" identity-canary' _ "$LAB_NS" "$LAB_DIR" ;;
    esac
    if [ "$(date -u +%s)" -ge "$deadline" ]; then mark a-canary "$stage: not proven after $2 s: $s"; return 1; fi
    n=$((n + 1))
    sleep "$OBSERVE_INTERVAL_S"
  done
}

_a_stage3() { # identity, then every control-plane Deployment with a pod older than the apply
  local d sel stale=()
  mark a-stage3 "identity-canary not Ready after stage 2: restart linkerd-identity, then control-plane components started before the apply"
  capture recover/a-stage3-identity.txt kubectl -n linkerd rollout restart deploy/linkerd-identity
  capture recover/a-stage3-identity-rollout.txt kubectl -n linkerd rollout status deploy/linkerd-identity --timeout=300s
  while read -r d sel; do
    [ "$d" != linkerd-identity ] || continue
    if kubectl -n linkerd get pods -l "$sel" -o json \
        | jq -e --argjson a "$A_APPLY_EPOCH" '[.items[] | select(.status.startTime != null and ((.status.startTime | fromdateiso8601) < $a))] | length > 0' > /dev/null; then
      stale+=("$d")
    fi
  done < <(kubectl -n linkerd get deploy -o json \
    | jq -r '.items[] | "\(.metadata.name) \(.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))"')
  printf 'apply_epoch=%s\nstarted_before_apply=%s\n' "$A_APPLY_EPOCH" "${stale[*]:-none}" > "$RUN_DIR/recover/a-stage3-stale.txt"
  if [ "${#stale[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016
    capture recover/a-stage3-control-plane.txt bash -c \
      'for d in "$@"; do kubectl -n linkerd rollout restart "deploy/$d" && kubectl -n linkerd rollout status "deploy/$d" --timeout=300s || exit 1; done' _ "${stale[@]}"
  else
    printf 'no other control-plane Deployment has a pod started before the apply\n' > "$RUN_DIR/recover/a-stage3-control-plane.txt"
  fi
  snap_controlplane a-stage3-after
  _a_canary_ready a-stage3 "$RECOVER_WINDOW_S" || true
}

scenario_recover() {
  local new="$CERTS/new" all=()
  # Stage 1: apply a new anchor and issuer, the documented way for an expired root.
  make_trust_anchor "$new" "$NEW_ANCHOR_LIFETIME"
  make_issuer "$new" "$REPLACEMENT_ISSUER_LIFETIME" "$new"
  write_cert trust-anchor-new "$new/ca.crt"
  write_cert issuer-replacement "$new/issuer.crt"
  snap_controlplane a-stage1-before
  A_APPLY_EPOCH="$(date -u +%s)"
  mark a-stage1-apply "linkerd upgrade with a new anchor and issuer, --force"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$new/issuer.crt' --identity-issuer-key-file='$new/issuer.key' --identity-trust-anchors-file='$new/ca.crt' --force | kubectl apply -f -"
  capture_cp_rollouts recover/a-stage1-rollout.txt
  snap_controlplane a-stage1-after
  tick a-stage1
  # Stage 2: no manual restarts; the canary shows whether identity issues new-anchor leaves.
  mark a-stage2 "no manual restarts for ${RECOVER_WINDOW_S}s; identity-canary applied"
  capture recover/a-stage2-canary.txt bash "$LAB_DIR/deploy.sh" identity-canary
  if _a_canary_ready a-stage2 "$RECOVER_WINDOW_S"; then
    snap_logs a-stage2
    snap_events a-stage2
    mark a-stage3 "not needed: identity-canary became Ready in stage 2"
  else
    snap_logs a-stage2
    snap_events a-stage2
    _a_stage3
  fi
  # Stage 4: restart every meshed lab workload, as the guide directs; gated and sampled.
  snap_before_restart pre-a-stage4
  mapfile -t all < <(lab_deployments)
  restart_and_gate a-stage4 "${all[@]}"
  tick a-stage4
  # Stage 5: verify with linkerd check -- the verify tick that follows.
  mark a-stage5 "verify with linkerd check (the verify tick)"
}

run_scenario 06-anchor-expiry anchor-short "${1:?usage: 06-anchor-expiry.sh <run-dir>}"
