#!/usr/bin/env bash
# The shared scenario timeline (design spec section 4.3). A scenario file defines
#   scenario_mark_epoch  -- echo T_mark (epoch): the issuer's notAfter in #5
#   scenario_recover     -- runs between the pre-recover snapshots and the verify tick
# then calls run_scenario. Scripts record observations and judge only whether the
# run is valid evidence -- never hypotheses H1-H8.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"

CONTROL_RUNS="$DEMO/runs/00-baseline-control"
PROBES=(probe-http probe-tcp-new probe-tcp-stream)

sleep_until() { # EPOCH
  local now
  now="$(date -u +%s)"
  if [ "$1" -gt "$now" ]; then sleep $(( $1 - now )); fi
}

cert_not_before_epoch() { # PEM_FILE
  local start
  start="$(openssl x509 -noout -startdate -in "$1")" || die "cannot read $1"
  date -u -d "${start#notBefore=}" +%s
}

probes_ok_now() { # every probe's latest line is an ok exchange
  local p
  for p in "${PROBES[@]}"; do
    kubectl -n "$LAB_NS" logs "deploy/$p" -c probe --tail=1 2>/dev/null \
      | grep -qE ' seq=[0-9]+( conn=[^ ]+)? ok( |$)' || return 1
  done
}

wait_probes_ok() { # TIMEOUT_S
  local deadline=$(( $(date -u +%s) + $1 ))
  until probes_ok_now; do
    [ "$(date -u +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

observe_until() { # END_EPOCH PREFIX [HOOK]: one tick every OBSERVE_INTERVAL_S before END
  local end="$1" prefix="$2" hook="${3:-}" n=1 next
  next="$(date -u +%s)"
  while [ "$next" -lt "$end" ]; do
    sleep_until "$next"
    tick "$prefix-$n"
    if [ -n "$hook" ]; then "$hook" "$prefix-$n"; fi
    n=$((n + 1))
    next=$(( next + OBSERVE_INTERVAL_S ))
  done
}

post_expiry_hook() { # NAME: evidence of why the post-expiry pods are (not) Ready
  snap_pod_detail "$1" probe-new
  snap_pod_detail "$1" restart-target
  capture "pods/$1-rollout.txt" kubectl -n "$LAB_NS" rollout status deploy/restart-target --timeout=1s
}

_on_exit() { # RC: mark an aborted run, keep what evidence exists, and record in
  # validity.txt why it does not count (spec section 5). Nothing here may fail the
  # trap: the shell must still exit with RC.
  local rc="$1"
  [ "$rc" -ne 0 ] || return 0
  [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ] || return 0
  mark aborted "exit $rc, see harness.log"
  snap_logs aborted
  snap_events aborted
  snap_probes aborted
  if [ ! -e "$RUN_DIR/validity.txt" ]; then
    evaluate_validity "$RUN_DIR" "$SCENARIO" "$LINKERD_EDGE_VERSION" "$CONTROL_RUNS" || true
  fi
}

_write_result() { # FILE CMD...: "result=ok|fail", then the command's output
  local file="$RUN_DIR/$1" body r=ok
  shift
  body="$("$@")" || r=fail
  { echo "result=$r"; printf '%s\n' "$body"; } > "$file"
  [ "$r" = ok ]
}

run_scenario() { # SCENARIO PROFILE RUN_DIR
  SCENARIO="$1"
  local profile="$2" start sampled max
  RUN_DIR="$3"
  load_profile "$profile"
  [ -f "$RUN_DIR/git-state.txt" ] || die "$RUN_DIR/git-state.txt missing: launch scenarios with scripts/run.sh"
  [ ! -e "$RUN_DIR/timeline.log" ] || die "$RUN_DIR already has a timeline; runs are never resumed"
  trap '_on_exit $?' EXIT
  start="$(date -u +%s)"
  CERT_SET="$SCENARIO-$(basename "$RUN_DIR")"
  CERTS="$CERTS_ROOT/$CERT_SET"

  mark reset "profile=$profile cert_set=$CERT_SET"
  bash "$LAB_DIR/reset.sh" "$profile" "$CERT_SET" > "$RUN_DIR/install.log" 2>&1 || die "reset failed; see install.log"
  write_cert trust-anchor "$CERTS/ca.crt"
  write_cert issuer-initial "$CERTS/issuer.crt"
  bash "$LAB_DIR/deploy.sh" baseline >> "$RUN_DIR/install.log" 2>&1 || die "baseline deploy failed; see install.log"
  write_versions "$SCENARIO" "$CERT_SET"
  T_MARK="$(scenario_mark_epoch)"
  mark t_mark "epoch=$T_MARK utc=$(date -u -d "@$T_MARK" +%Y-%m-%dT%H:%M:%SZ)"

  wait_probes_ok 180 || die "probes did not all report ok within 180s of deploy"
  tick baseline
  snap_secret baseline
  snap_trust baseline
  snap_pod_detail baseline restart-target
  sampled="$(awk -F= '/^sampled_at_epoch=/ { print $2 }' "$RUN_DIR/metrics/baseline.txt")"
  max=$(( $(duration_to_seconds "$LEAF_LIFETIME") + 25 ))   # + Linkerd's 20s clock-skew allowance + 5s slack
  _write_result leaf-lifetime.txt leaf_lifetime_check "$LEAF_EXPIRY_METRIC" "$sampled" "$max" "$RUN_DIR/metrics/baseline.txt" \
    || die "a workload leaf outlives LEAF_LIFETIME=$LEAF_LIFETIME; see leaf-lifetime.txt"
  [ $(( T_MARK - $(date -u +%s) )) -ge $(( $(duration_to_seconds "$LEAF_LIFETIME") + 60 )) ] \
    || die "under LEAF_LIFETIME+60s left before T_mark at baseline; raise ISSUER_LIFETIME"

  observe_until $(( T_MARK - 60 )) pre
  sleep_until $(( T_MARK - 60 )); tick fault-minus60
  sleep_until $(( T_MARK - 10 )); tick fault-minus10
  sleep_until $(( T_MARK + 10 )); tick fault-plus10
  snap_events fault-plus10

  sleep_until $(( T_MARK + 60 ))
  capture post-actions/probe-new.txt bash "$LAB_DIR/deploy.sh" probe-new
  mark applied probe-new
  capture post-actions/restart-target.txt kubectl -n "$LAB_NS" rollout restart deploy/restart-target
  mark rolled restart-target
  observe_until $(( T_MARK + POST_EXPIRY_WINDOW_S )) post post_expiry_hook

  snap_secret pre-recover
  snap_trust pre-recover
  snap_logs pre-recover
  snap_events pre-recover
  mark recover
  scenario_recover

  tick verify
  snap_secret verify
  snap_trust verify
  snap_pod_detail verify probe-new
  snap_pod_detail verify restart-target
  capture pods/verify-rollout-restart-target.txt kubectl -n "$LAB_NS" rollout status deploy/restart-target --timeout=120s
  capture pods/verify-rollout-probe-new.txt kubectl -n "$LAB_NS" rollout status deploy/probe-new --timeout=120s

  snap_logs final
  snap_events final
  snap_journal final "$start"
  snap_probes final   # control_criteria_check reads probes/final/
  _write_result trust-invariant.txt trust_invariant_check \
    "$RUN_DIR/trust/baseline.txt" "$RUN_DIR/trust/pre-recover.txt" "$RUN_DIR/trust/verify.txt" || true
  if [ "$SCENARIO" = 00-baseline-control ]; then
    _write_result control-criteria.txt control_criteria_check "$RUN_DIR" || true
  fi
  assert_no_keys
  # shellcheck disable=SC1010
  mark done
  if evaluate_validity "$RUN_DIR" "$SCENARIO" "$LINKERD_EDGE_VERSION" "$CONTROL_RUNS"; then
    log "evidence_valid=yes"
  else
    log "run finished but is NOT valid evidence:"
    cat "$RUN_DIR/validity.txt" >&2
  fi
}
