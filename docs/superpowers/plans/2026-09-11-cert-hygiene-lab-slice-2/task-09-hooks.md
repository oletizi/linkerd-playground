# Task 9: Scenario hooks

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 1.2. `run_scenario` keeps `scenario_mark_epoch` and `scenario_recover` and gains three optional hooks, each with a default that a scenario file overrides by redefining the function after sourcing `scenario-common.sh`:
- `scenario_fault`, run at T_mark. Default: nothing, since for the expiry scenarios the expiry itself is the fault. O stops identity here; S-hard swaps the anchor.
- `scenario_post_actions`, run at T_mark + 60 s. Default: today's behaviour (apply `probe-new`, roll `restart-target`). W replaces it with admission probes.
- `scenario_tick_extra NAME`, extra per-tick capture. No default: `tick` calls it only when a scenario defines it. W repeats its admission probes on every tick.

The timeline is split into setup, timeline and finish phases, so that a second entry point, `run_steps_scenario`, can serve the scenarios with no T_mark (K, S-staged): setup, then the scenario's `scenario_steps`, then the same finish. `scenario-common.sh` is rewritten in full here; it carries every change from Tasks 1, 3, 4, 5, 6 and 8.

Two more pieces live here, because they belong to the timeline:
- **Discovery runs.** A run launched with `scripts/run.sh --discovery` carries `discovery.txt` (Task 8). `_discovery_setup` marks it in the timeline, and it refuses to run if the run directory is outside `runs/_discovery/`. With `--short`, it lowers `POST_EXPIRY_WINDOW_S`, `RECOVER_WINDOW_S` and `W_POST_WINDOW_S` to the `DISCOVERY_*` settings, never raising any of them. It records the values in `discovery-windows.txt` and a `discovery-windows` marker, and `versions.txt` records them as `config_…`. Evidence runs refuse the override twice: `run.sh` refuses `--short` without `--discovery`, and `_discovery_setup` refuses `discovery.txt` outside `runs/_discovery/`.
- **The end of the post window** is a fourth, internal hook, `scenario_post_window_end`. Its default is T_mark + `POST_EXPIRY_WINDOW_S`; W overrides it to end at T3 + `W_POST_WINDOW_S` (design § 3). `tick` records `TICK_START_EPOCH`, the moment its checks began, for hooks that must compare against it.

The task ends with the discovery smoke run of the control (moved here from Task 8), which exercises the restructured timeline, the stages and the gates end to end.

**Files:**
- Modify (full rewrite): `demos/cert-hygiene/lab/scenario-common.sh`
- Modify: `demos/cert-hygiene/lab/collect.sh` (`tick` records `TICK_START_EPOCH` and calls `scenario_tick_extra`)
- Modify: `demos/cert-hygiene/config.example.env` (discovery windows; `W_POST_WINDOW_S`)
- Create (discovery, committed): `demos/cert-hygiene/runs/_discovery/<stamp>-00-baseline-control/`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces:
  - `run_scenario SCENARIO PROFILE RUN_DIR`: `_scenario_setup` (timed) → `_scenario_timeline` → pre-recover snapshots → `mark recover` → `scenario_recover` → `_scenario_finish`.
  - `run_steps_scenario SCENARIO PROFILE RUN_DIR`: `_scenario_setup` (untimed: no `T_MARK`, no `t_mark` line) → `mark steps` → `scenario_steps` → `_scenario_finish`.
  - Hooks with their defaults: `scenario_fault`, `scenario_post_actions`, `scenario_post_window_end` (echoes an epoch); optional `scenario_tick_extra NAME`.
  - `TICK_START_EPOCH` (set by `tick` before its checks start); `_discovery_setup`; `discovery-windows.txt` (`short_windows=applied` and the three values) in short discovery runs; timeline markers `discovery …` and `discovery-windows …`.
  - Config: `W_POST_WINDOW_S=600` (W's post-expiry window after T3, design § 3); `DISCOVERY_POST_WINDOW_S=420`, `DISCOVERY_RECOVER_WINDOW_S=120`, `DISCOVERY_W_POST_WINDOW_S=120`.
  - Globals a scenario may read: `SCENARIO`, `RUN_DIR`, `CERTS`, `CERT_SET`, `T_MARK` (timed only), `START_EPOCH`, `PROFILE` and the profile's lifetimes.
  - Timeline markers, in order, for a timed run: `reset profile=…`, `t_mark`, `tick baseline`, `tick pre-N`, `tick fault-minus60`, `tick fault-minus10`, `fault`, `tick fault-plus10`, the post-actions' markers, `tick post-N`, `recover`, the scenario's recovery markers, `tick verify`, `done`.

- [ ] **Step 1: `tick` calls the optional hook (`demos/cert-hygiene/lab/collect.sh`)**

In `tick`, immediately after `local name="$1"`, add:

```bash
  TICK_START_EPOCH="$(date -u +%s)"   # when this tick's checks begin; hooks compare against it
```

and after the final `wait`, add:

```bash
  if declare -F scenario_tick_extra > /dev/null; then scenario_tick_extra "$name"; fi
```

- [ ] **Step 1b: Settings in `demos/cert-hygiene/config.example.env`**

Append to the `# ---- Timing (seconds) ----` section:

```bash
# W: its post-expiry window, counted from the last webhook expiry (T3; design section 3).
W_POST_WINDOW_S=600
# Discovery runs launched with --short only (scripts/run.sh --discovery --short): each
# window is lowered to this value, never raised. Evidence runs refuse the override.
DISCOVERY_POST_WINDOW_S=420
DISCOVERY_RECOVER_WINDOW_S=120
DISCOVERY_W_POST_WINDOW_S=120
```

`DISCOVERY_POST_WINDOW_S=420` still exceeds a 5-minute leaf plus the 20 s skew, so a shortened identity outage still outlasts the leaf window.

- [ ] **Step 2: Rewrite `demos/cert-hygiene/lab/scenario-common.sh`**

```bash
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
  printf 'short_windows=applied\nPOST_EXPIRY_WINDOW_S=%s\nRECOVER_WINDOW_S=%s\nW_POST_WINDOW_S=%s\n' \
    "$POST_EXPIRY_WINDOW_S" "$RECOVER_WINDOW_S" "$W_POST_WINDOW_S" > "$RUN_DIR/discovery-windows.txt"
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
  snap_probes final
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
```

- [ ] **Step 3: Syntax, shellcheck, tests, line counts**

Run: `cd demos/cert-hygiene && for f in lab/*.sh scenarios/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/scenario-common.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh scenarios/*.sh'`
Expected: no errors; `scenario-common.sh` under 300 lines; no findings.

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 4: Commit, then launch the discovery smoke run of the control**

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add scenario hooks and a step-driven scenario entry point"
git push
git status --porcelain -- lib demos/cert-hygiene
```
Expected: the last command prints nothing.

Run: `just demo cert-hygiene run-discovery 00-baseline-control`
Expected: the last line is `runs/_discovery/<stamp>-00-baseline-control`.

The run takes the reset time, plus 15 minutes to T_mark, plus the 1800 s window, plus the stages: roughly an hour and a quarter. Wait with `cd demos/cert-hygiene && bash scripts/wait-run.sh runs/_discovery/<stamp>-00-baseline-control 540`, repeating while it exits 124.

Expected at the end:
- `timeline.log` has, in order, `discovery discovery run, never evidence: discovery=yes short_windows=no`, `t_mark`, `fault`, `applied probe-new`, `recover`, `recover-none`, `stage stage1-norestart: no restarts …`, `restart stage2-client-a: probe-tcp-new`, `gate stage2-client-a pass`, the same for `stage3-server` and `stage4-all`, `tick verify`, `done`.
- `validity.txt` says `evidence_valid=no` with exactly one reason, `reason=discovery run: never evidence`. A discovery run never reads `evidence_valid=yes`; any other reason is a harness fault to fix.
- `control-criteria.txt` starts `result=ok`, with `ok:` lines for the four gate records (`gate=none` for stage 1, `gate=pass` for stages 2–4), each `A=10/0/classified B=10/0/classified`.
- `credential-plan.txt` starts `result=ok` with `observed 1:` only.

If it isn't valid, read `validity.txt`, `control-criteria.txt`, `credential-plan.txt`, the `gates/*.txt` `check` lines and `harness.log`. Fix the harness, commit, and repeat this step. Keep every discovery run.

- [ ] **Step 5: Commit the discovery run**

Run: `(grep -rl 'PRIVATE KEY' demos/cert-hygiene/runs || echo none) && du -sh demos/cert-hygiene/runs/_discovery/*-00-baseline-control`
Expected: `none`. If a run directory exceeds 20M, report its largest files (`du -a <dir> | sort -n | tail`) to the user before committing.

```bash
git add demos/cert-hygiene/runs/_discovery
git commit -m "cert-hygiene record a discovery run of the restart-choreography control"
git push
```
