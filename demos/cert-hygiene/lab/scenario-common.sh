#!/usr/bin/env bash
# The shared scenario timeline. Two entry points:
#   run_scenario SCENARIO PROFILE RUN_DIR        timed: a T_mark, the expiry or fault
#   run_steps_scenario SCENARIO PROFILE RUN_DIR  step-driven: no T_mark (K, S-staged)
# A timed scenario defines scenario_mark_epoch (echo T_mark as epoch) and
# scenario_recover, and may redefine the hooks scenario_fault, scenario_post_actions and
# scenario_tick_extra NAME (design section 1.2). A step-driven scenario defines
# scenario_steps. Scripts record observations and judge only validity -- never hypotheses.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/gates.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/stages.sh"

CONTROL_RUNS="$DEMO/runs/00-baseline-control"
PROBES=(probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream)

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

# ---- hooks (design section 1.2): a scenario file redefines them after sourcing this ----
scenario_fault() { # at T_mark. Default: nothing; in the expiry scenarios the expiry is the fault.
  :
}
scenario_post_actions() { # at T_mark + 60s. Default: a new workload, and a rollout of an existing one.
  capture post-actions/probe-new.txt bash "$LAB_DIR/deploy.sh" probe-new
  mark applied probe-new
  capture post-actions/restart-target.txt kubectl -n "$LAB_NS" rollout restart deploy/restart-target
  mark rolled restart-target
}
scenario_post_window_end() { # the epoch the post window ends. Default: T_mark + POST_EXPIRY_WINDOW_S.
  echo $(( T_MARK + POST_EXPIRY_WINDOW_S ))
}
# scenario_tick_extra NAME has no default: tick calls it only when a scenario defines it.

_min() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; } # A B

# _discovery_setup: a run launched with scripts/run.sh --discovery carries discovery.txt.
# Mark it (evaluate_validity never counts it as evidence) and, with --short, lower the
# observation windows to the DISCOVERY_* settings. A run outside runs/_discovery/ refuses.
_discovery_setup() {
  local f="$RUN_DIR/discovery.txt"
  [ -f "$f" ] || return 0
  case "$RUN_DIR" in
    runs/_discovery/*|*/runs/_discovery/*) ;;
    *) die "$f in a run outside runs/_discovery/: evidence runs refuse discovery overrides" ;;
  esac
  mark discovery "discovery run, never evidence: $(paste -sd' ' "$f")"
  grep -qx 'short_windows=yes' "$f" || return 0
  POST_EXPIRY_WINDOW_S="$(_min "$POST_EXPIRY_WINDOW_S" "$DISCOVERY_POST_WINDOW_S")"
  RECOVER_WINDOW_S="$(_min "$RECOVER_WINDOW_S" "$DISCOVERY_RECOVER_WINDOW_S")"
  W_POST_WINDOW_S="$(_min "$W_POST_WINDOW_S" "$DISCOVERY_W_POST_WINDOW_S")"
  W_RECONNECT_WINDOW_S="$(_min "$W_RECONNECT_WINDOW_S" "$DISCOVERY_W_RECONNECT_WINDOW_S")"
  printf 'short_windows=applied\nPOST_EXPIRY_WINDOW_S=%s\nRECOVER_WINDOW_S=%s\nW_POST_WINDOW_S=%s\nW_RECONNECT_WINDOW_S=%s\n' \
    "$POST_EXPIRY_WINDOW_S" "$RECOVER_WINDOW_S" "$W_POST_WINDOW_S" "$W_RECONNECT_WINDOW_S" > "$RUN_DIR/discovery-windows.txt"
  mark discovery-windows "$(paste -sd' ' "$RUN_DIR/discovery-windows.txt")"
}

_on_exit() { # RC: mark an aborted run, keep what evidence exists, and record in
  # validity.txt why it does not count. Nothing here may fail the trap.
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

_scenario_setup() { # SCENARIO PROFILE RUN_DIR TIMED(yes|no)
  SCENARIO="$1"
  local profile="$2" timed="$4" sampled max comp
  RUN_DIR="$3"
  [ -f "$RUN_DIR/git-state.txt" ] || die "$RUN_DIR/git-state.txt missing: launch scenarios with scripts/run.sh"
  [ ! -e "$RUN_DIR/timeline.log" ] || die "$RUN_DIR already has a timeline; runs are never resumed"
  trap '_on_exit $?' EXIT
  START_EPOCH="$(date -u +%s)"
  load_profile "$profile"
  _discovery_setup
  CERT_SET="$SCENARIO-$(basename "$RUN_DIR")"
  CERTS="$CERTS_ROOT/$CERT_SET"

  mark reset "profile=$profile cert_set=$CERT_SET"
  bash "$LAB_DIR/reset.sh" "$profile" "$CERT_SET" > "$RUN_DIR/install.log" 2>&1 || die "reset failed; see install.log"
  write_cert trust-anchor "$CERTS/ca.crt"
  write_cert issuer-initial "$CERTS/issuer.crt"
  if [ -n "$WEBHOOK_CERT_LIFETIMES" ]; then
    write_cert webhook-ca "$CERTS/webhooks/ca.crt"
    for comp in "${WEBHOOK_COMPONENTS[@]}"; do write_cert "webhook-$comp" "$CERTS/webhooks/$comp.crt"; done
  fi
  # V's certificate state (design section 8): the tap serving certificate, and the lab
  # webhook CA it is signed by when WEBHOOK_CERT_LIFETIMES did not already record it. No
  # hook covers this setup step, so it is here rather than in a scenario file.
  if [ -n "$TAP_CERT_LIFETIME" ]; then
    [ -f "$RUN_DIR/certs/webhook-ca.pem" ] || write_cert webhook-ca "$CERTS/webhooks/ca.crt"
    write_cert tap "$CERTS/webhooks/tap.crt"
  fi
  bash "$LAB_DIR/deploy.sh" baseline >> "$RUN_DIR/install.log" 2>&1 || die "baseline deploy failed; see install.log"
  write_versions "$SCENARIO" "$CERT_SET"
  if [ "$timed" = yes ]; then
    T_MARK="$(scenario_mark_epoch)"
    mark t_mark "epoch=$T_MARK utc=$(date -u -d "@$T_MARK" +%Y-%m-%dT%H:%M:%SZ)"
  fi

  wait_probes_ok 180 || die "probes did not all report ok within 180s of deploy"
  tick baseline
  snap_secret baseline
  snap_pod_detail baseline restart-target
  sampled="$(awk -F= '/^sampled_at_epoch=/ { print $2 }' "$RUN_DIR/metrics/baseline.txt")"
  max=$(( $(duration_to_seconds "$LEAF_LIFETIME") + 25 ))   # + Linkerd's 20s clock-skew allowance + 5s slack
  _write_result leaf-lifetime.txt leaf_lifetime_check "$LEAF_EXPIRY_METRIC" "$sampled" "$max" "$RUN_DIR/metrics/baseline.txt" \
    || die "a workload leaf outlives LEAF_LIFETIME=$LEAF_LIFETIME; see leaf-lifetime.txt"
  if [ "$timed" = yes ]; then
    [ $(( T_MARK - $(date -u +%s) )) -ge $(( $(duration_to_seconds "$LEAF_LIFETIME") + 60 )) ] \
      || die "under LEAF_LIFETIME+60s left before T_mark at baseline; lengthen the lifetime that sets T_mark"
  fi
}

_scenario_timeline() { # pre ticks, the fault at T_mark, post-actions, the post window
  observe_until $(( T_MARK - 60 )) pre
  sleep_until $(( T_MARK - 60 )); tick fault-minus60
  sleep_until $(( T_MARK - 10 )); tick fault-minus10
  sleep_until "$T_MARK"; mark fault; scenario_fault
  sleep_until $(( T_MARK + 10 )); tick fault-plus10
  snap_events fault-plus10
  sleep_until $(( T_MARK + 60 )); scenario_post_actions
  observe_until "$(scenario_post_window_end)" post post_expiry_hook
}

_scenario_finish() { # the verify tick, final snapshots, results, validity
  local d
  tick verify
  snap_secret verify
  snap_pod_detail verify probe-new
  snap_pod_detail verify restart-target
  for d in $(lab_deployments); do
    capture "pods/verify-rollout-$d.txt" kubectl -n "$LAB_NS" rollout status "deploy/$d" --timeout=120s
  done
  snap_logs final
  snap_events final
  snap_journal final "$START_EPOCH"
  snap_probes final   # the run's closing probe snapshot; _all_probe_lines merges it with
  # every other probes/<label>/ snapshot for control_criteria_check and scripts/probe-lines.sh
  _write_result credential-plan.txt credential_plan_check "$RUN_DIR" "$SCENARIO" || true
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

run_scenario() { # SCENARIO PROFILE RUN_DIR
  _scenario_setup "$1" "$2" "$3" yes
  _scenario_timeline
  snap_secret pre-recover
  snap_trust pre-recover
  snap_logs pre-recover
  snap_events pre-recover
  mark recover
  scenario_recover
  _scenario_finish
}

run_steps_scenario() { # SCENARIO PROFILE RUN_DIR
  _scenario_setup "$1" "$2" "$3" no
  mark steps
  scenario_steps
  _scenario_finish
}
