# Task 8: Orchestration and the negative control

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** The shared scenario timeline (spec § 4.3), the host launcher that records git state, and the `00-baseline-control` scenario (spec § 4.4). Run the control from a clean tree and commit a run whose `validity.txt` says `evidence_valid=yes`.

This task also closes a gap in Task 4. "The control passed" must mean its § 4.4 criteria held, not only that its evidence is complete. `control_criteria_check` is added test-first, and `evaluate_validity` requires it for the control.

**Files:**
- Modify: `demos/cert-hygiene/lab/lib-evidence.sh` (add `control_criteria_check`; extend `evaluate_validity`)
- Modify: `demos/cert-hygiene/lab/tests/test-evidence.sh` (fixture + new tests)
- Create: `demos/cert-hygiene/lab/scenario-common.sh`
- Create: `demos/cert-hygiene/scenarios/00-baseline-control.sh`
- Create: `demos/cert-hygiene/scripts/run.sh`, `demos/cert-hygiene/scripts/wait-run.sh`
- Modify: `demos/cert-hygiene/Justfile` (add `run`, `wait`)
- Create (evidence, committed): `demos/cert-hygiene/runs/00-baseline-control/<UTC>/`

**Interfaces:**
- Consumes: everything from Tasks 4–7. The collector (`mark`, `capture`, `tick`, `snap_*`, `write_versions`, `write_cert`, `assert_no_keys`), `lab/reset.sh`, `lab/deploy.sh`, and `lib-evidence.sh` functions.
- Produces:
  - `control_criteria_check RUN_DIR`. Checks only probe lines at or after the `tick baseline` timestamp:
    - no `fail` or `closed` lines in any probe log
    - exactly one stream `connect` line
    - both `pods/verify-rollout-*.txt` end `[exit 0]`
    - no check file contains `×`, and none has a `‼ … valid for at least 60 days` line
  - `evaluate_validity` also requires `control-criteria.txt` to start `result=ok` when SCENARIO is `00-baseline-control`.
  - `lab/scenario-common.sh`: `run_scenario SCENARIO MODE RUN_DIR`, `sleep_until`, `cert_not_before_epoch`, `probes_ok_now`, `wait_probes_ok`, `observe_until`, `post_expiry_hook`. A scenario file must define `scenario_mark_epoch` (echo T_mark as epoch) and `scenario_recover` (run between the `pre-recover` snapshots and the `verify` tick).
  - Tick names: `baseline`, `pre-N`, `fault-minus60`, `fault-minus10`, `fault-plus10`, `post-N`, `verify`.
  - Snapshot names for secrets and trust: `baseline`, `pre-recover`, `verify`.
  - `scripts/run.sh SCENARIO` creates `runs/SCENARIO/<UTC>/` and writes `git-state.txt` (Task 4 format) and `host.txt` (plus `harness.diff` when dirty). It launches the scenario detached and prints the demo-relative run dir on its last line.
  - `scripts/wait-run.sh RUN_REL [timeout]` waits for `RUN_REL/harness.log` to end `[exit N]`, prints the timeline tail and `validity.txt`, and exits N.

- [ ] **Step 1: Extend the test fixture and add failing tests**

In `demos/cert-hygiene/lab/tests/test-evidence.sh`, inside `make_run`, add this line after the one that writes `trust-invariant.txt`:

```bash
  printf 'result=ok\n' > "$d/control-criteria.txt"
```

Then insert this block immediately before the final `finish test-evidence` line:

```bash
# ---- evaluate_validity: the control must have met its criteria ----
make_run "$T/ctlbad" 00-baseline-control c1 h9 false
printf 'result=fail\nfail: probe-http has 3 fail/closed lines\n' > "$T/ctlbad/control-criteria.txt"
assert_fails "control that failed its criteria is invalid" evaluate_validity "$T/ctlbad" 00-baseline-control "$V"
assert_contains "$(cat "$T/ctlbad/validity.txt")" "reason=control criteria not met" "reason names the criteria"

# ---- control_criteria_check ----
make_ctl() { # dir: a control run that meets every criterion
  local d="$1"
  mkdir -p "$d/probes" "$d/pods" "$d/checks"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n' > "$d/timeline.log"
  printf '2026-09-10T10:04:58Z probe-http seq=1 fail curl_rc=7 http=000 err=refused\n2026-09-10T10:05:01Z probe-http seq=2 ok http=200\n' > "$d/probes/probe-http.log"
  printf '2026-09-10T10:05:01Z probe-tcp-new seq=2 ok\n' > "$d/probes/probe-tcp-new.log"
  printf '2026-09-10T10:04:59Z probe-tcp-stream seq=0 conn=ab-1 connect target=s:9000\n2026-09-10T10:05:01Z probe-tcp-stream seq=2 conn=ab-1 ok\n' > "$d/probes/probe-tcp-stream.log"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-restart-target.txt"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-probe-new.txt"
  printf '$ linkerd check\n√ issuer cert is valid for at least 60 days\n‼ cli is up-to-date\n[exit 0]\n' > "$d/checks/verify-check.txt"
}
make_ctl "$T/cc"
assert_succeeds "healthy control meets criteria (a fail before baseline is ignored)" control_criteria_check "$T/cc"
make_ctl "$T/cc1"; printf '2026-09-10T10:20:00Z probe-tcp-new seq=9 fail socat_rc=1\n' >> "$T/cc1/probes/probe-tcp-new.log"
assert_fails "a probe failure after baseline breaks the control" control_criteria_check "$T/cc1"
make_ctl "$T/cc2"; printf '2026-09-10T10:20:00Z probe-tcp-stream seq=0 conn=ab-2 connect target=s:9000\n' >> "$T/cc2/probes/probe-tcp-stream.log"
assert_fails "a second stream connection breaks the control" control_criteria_check "$T/cc2"
make_ctl "$T/cc3"; printf '$ kubectl rollout status\n[exit 1]\n' > "$T/cc3/pods/verify-rollout-probe-new.txt"
assert_fails "an incomplete rollout breaks the control" control_criteria_check "$T/cc3"
make_ctl "$T/cc4"; printf '× issuer cert is within its validity period\n' >> "$T/cc4/checks/verify-check.txt"
assert_fails "a fatal check result breaks the control" control_criteria_check "$T/cc4"
make_ctl "$T/cc5"; printf '‼ issuer cert is valid for at least 60 days\n' >> "$T/cc5/checks/verify-check.txt"
assert_fails "a certificate-lifetime warning breaks the control" control_criteria_check "$T/cc5"
```

Run: `just demo cert-hygiene test`
Expected: FAIL, because `control_criteria_check` is not defined and the `ctlbad` validity reason is absent.

- [ ] **Step 2: Implement in `demos/cert-hygiene/lab/lib-evidence.sh`**

Add this function before `_kv()`:

```bash
# control_criteria_check RUN_DIR: the negative control's pass criteria (design spec
# section 4.4) that a script can judge. Probe lines before the baseline tick are
# startup noise and are ignored. Other check warnings are compared by a human.
control_criteria_check() {
  local run="${1:?control_criteria_check: RUN_DIR required}" bad=0 t p n f
  t="$(awk '$2 == "tick" && $3 == "baseline" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  [ -n "$t" ] || { echo "fail: no baseline tick in timeline.log"; return 1; }
  for p in probe-http probe-tcp-new probe-tcp-stream; do
    f="$run/probes/$p.log"
    if [ ! -s "$f" ]; then echo "fail: $f missing"; bad=1; continue; fi
    n="$(awk -v t="$t" '$1 >= t && / (fail|closed) /' "$f" | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then echo "ok: $p has no fail/closed lines after baseline"
    else echo "fail: $p has $n fail/closed lines after baseline"; bad=1; fi
  done
  n="$(grep -c ' connect ' "$run/probes/probe-tcp-stream.log" 2>/dev/null || true)"
  if [ "$n" = 1 ]; then echo "ok: one stream connection"
  else echo "fail: $n stream connect lines, want 1"; bad=1; fi
  for f in verify-rollout-restart-target verify-rollout-probe-new; do
    if [ "$(tail -n 1 "$run/pods/$f.txt" 2>/dev/null)" = "[exit 0]" ]; then echo "ok: $f completed"
    else echo "fail: $f did not complete"; bad=1; fi
  done
  n="$(grep -l '×' "$run"/checks/*.txt 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no fatal check results"
  else echo "fail: $n check files contain a fatal (×) result"; bad=1; fi
  n="$(grep -lE '‼.*valid for at least 60 days' "$run"/checks/*.txt 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no certificate-lifetime warnings"
  else echo "fail: $n check files carry a certificate-lifetime warning"; bad=1; fi
  return "$bad"
}
```

In `evaluate_validity`, add this block immediately before the `if [ "$scenario" = 05-issuer-expiry ]; then` block that computes `tree`:

```bash
  if [ "$scenario" = 00-baseline-control ]; then
    [ "$(head -n 1 "$run/control-criteria.txt" 2>/dev/null)" = result=ok ] || reasons+=("control criteria not met")
  fi
```

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence`.

- [ ] **Step 3: Write `demos/cert-hygiene/lab/scenario-common.sh`**

```bash
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

_on_exit() { # RC: mark an aborted run and keep what evidence exists
  local rc="$1"
  [ "$rc" -ne 0 ] || return 0
  [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ] || return 0
  mark aborted "exit $rc, see harness.log"
  snap_logs aborted
  snap_events aborted
}

_write_result() { # FILE CMD...: "result=ok|fail", then the command's output
  local file="$RUN_DIR/$1" body r=ok
  shift
  body="$("$@")" || r=fail
  { echo "result=$r"; printf '%s\n' "$body"; } > "$file"
  [ "$r" = ok ]
}

run_scenario() { # SCENARIO MODE RUN_DIR
  SCENARIO="$1"
  local mode="$2" start sampled max
  RUN_DIR="$3"
  [ -f "$RUN_DIR/git-state.txt" ] || die "$RUN_DIR/git-state.txt missing: launch scenarios with scripts/run.sh"
  [ ! -e "$RUN_DIR/timeline.log" ] || die "$RUN_DIR already has a timeline; runs are never resumed"
  trap '_on_exit $?' EXIT
  start="$(date -u +%s)"
  CERT_SET="$SCENARIO-$(basename "$RUN_DIR")"
  CERTS="$CERTS_ROOT/$CERT_SET"

  mark reset "mode=$mode cert_set=$CERT_SET"
  bash "$LAB_DIR/reset.sh" "$mode" "$CERT_SET" > "$RUN_DIR/install.log" 2>&1 || die "reset failed; see install.log"
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
  snap_probes
  _write_result trust-invariant.txt trust_invariant_check \
    "$RUN_DIR/trust/baseline.txt" "$RUN_DIR/trust/pre-recover.txt" "$RUN_DIR/trust/verify.txt" || true
  if [ "$SCENARIO" = 00-baseline-control ]; then
    _write_result control-criteria.txt control_criteria_check "$RUN_DIR" || true
  fi
  assert_no_keys
  mark done
  if evaluate_validity "$RUN_DIR" "$SCENARIO" "$LINKERD_EDGE_VERSION" "$CONTROL_RUNS"; then
    log "evidence_valid=yes"
  else
    log "run finished but is NOT valid evidence:"
    cat "$RUN_DIR/validity.txt" >&2
  fi
}
```

- [ ] **Step 4: Write `demos/cert-hygiene/scenarios/00-baseline-control.sh`**

```bash
#!/usr/bin/env bash
# Negative control (design spec section 4.4): the scenario #5 timeline and actions,
# with long-lived credentials. T_mark sits where #5's issuer would expire, so both
# runs snapshot the same moments. Nothing should fail. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  echo $(( $(cert_not_before_epoch "$CERTS/issuer.crt") + $(duration_to_seconds "$ISSUER_LIFETIME") ))
}
scenario_recover() {
  mark recover-none "control run: nothing expired, nothing to recover"
}

run_scenario 00-baseline-control long "${1:?usage: 00-baseline-control.sh <run-dir>}"
```

- [ ] **Step 5: Write `demos/cert-hygiene/scripts/run.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Launches a scenario detached inside the lab machine, after
# recording the harness's git state (the VM never runs git). The harness is lib/ plus
# demos/cert-hygiene/ excluding runs/. Prints the demo-relative run dir last.
# Usage: run.sh <scenario>, e.g. run.sh 00-baseline-control
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb git shasum

scenario="${1:?usage: run.sh <scenario>}"
[ -f "$DEMO/scenarios/$scenario.sh" ] || die "no scenario '$scenario' in $DEMO/scenarios/"
rel="runs/$scenario/$(date -u +%Y%m%dT%H%M%SZ)"
run="$DEMO/$rel"
mkdir -p "$run"

commit="$(git -C "$ROOT" rev-parse HEAD)"
status="$(git -C "$ROOT" status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs')"
if [ -f "$DEMO/config.local.env" ]; then
  status="$(printf '%s\n%s' "$status" "config.local.env present (overrides config.example.env)")"
fi
tree="$(git -C "$ROOT" ls-tree -r HEAD -- lib demos/cert-hygiene \
  | awk -F '\t' '$2 !~ /^demos\/cert-hygiene\/runs\//' | shasum -a 256 | cut -d' ' -f1)"
if [ -z "$status" ]; then dirty=false; else dirty=true; fi
printf 'demo_repo_commit=%s\ndemo_repo_dirty=%s\nharness_tree_sha256=%s\n' "$commit" "$dirty" "$tree" > "$run/git-state.txt"
if [ "$dirty" = true ]; then
  { printf '%s\n' "$status"; git -C "$ROOT" diff HEAD -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'; } > "$run/harness.diff"
  log "WARNING: harness tree is dirty; this run can never be valid evidence (see $rel/harness.diff)"
fi
printf 'orbstack_version=%s\nhost_os=%s\n' "$(orb version 2>/dev/null | head -n 1)" "$(sw_vers -productVersion 2>/dev/null || uname -sr)" > "$run/host.txt"

bash "$DEMO/scripts/in-lab.sh" --detach "$rel/harness.log" "scenarios/$scenario.sh" "$rel"
log "follow: tail -f $DEMO/$rel/timeline.log"
echo "$rel"
```

- [ ] **Step 6: Write `demos/cert-hygiene/scripts/wait-run.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Waits for a scenario launched by run.sh to finish, prints
# the end of its timeline and its validity verdict, and exits with the scenario's
# exit status (124 if the timeout passes first; the run keeps going regardless).
# Usage: wait-run.sh <demo-relative-run-dir> [timeout-seconds, default 3600]
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rel="${1:?usage: wait-run.sh <demo-relative-run-dir> [timeout-seconds]}"
rc=0
bash "$DEMO/scripts/wait-log.sh" "$rel/harness.log" "${2:-3600}" > /dev/null || rc=$?
[ "$rc" -ne 124 ] || { echo "still running: $rel" >&2; exit 124; }
echo "--- timeline (last 15 lines)"
tail -n 15 "$DEMO/$rel/timeline.log"
echo "--- validity"
cat "$DEMO/$rel/validity.txt" 2>/dev/null || echo "(no validity.txt: the run aborted; see $rel/harness.log)"
exit "$rc"
```

- [ ] **Step 7: Add `run` and `wait` to `demos/cert-hygiene/Justfile`**

Append:

```just

# Launch a scenario detached in the lab (prints the run directory)
run SCENARIO:
    bash scripts/run.sh {{SCENARIO}}

# Wait for a run to finish; prints its timeline tail and validity verdict
wait RUN TIMEOUT="3600":
    bash scripts/wait-run.sh {{RUN}} {{TIMEOUT}}
```

- [ ] **Step 8: Syntax-check, shellcheck, and tests**

Run: `cd demos/cert-hygiene && for f in lab/scenario-common.sh scenarios/*.sh scripts/run.sh scripts/wait-run.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh scenarios/*.sh scripts/*.sh'`
Expected: no output.

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence`.

- [ ] **Step 9: Commit the harness BEFORE running it**

Only a clean tree produces valid evidence (spec § 5), so the harness is committed first.

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/scenarios demos/cert-hygiene/scripts demos/cert-hygiene/Justfile
git commit -m "cert-hygiene add scenario timeline, launcher and negative control"
git push
git status --porcelain -- lib demos/cert-hygiene
```
Expected: the last command prints nothing.

- [ ] **Step 10: Run the control**

Run: `just demo cert-hygiene run 00-baseline-control`
Expected: the last line is `runs/00-baseline-control/<stamp>`. Note the stamp.

The run takes roughly the reset time, plus `ISSUER_LIFETIME` from certificate generation, plus `POST_EXPIRY_WINDOW_S`, plus verification. Wait with `just demo cert-hygiene wait runs/00-baseline-control/<stamp>`. If the Bash tool's time limit ends the wait, run it again. The run itself is detached and unaffected.

Expected at the end: the timeline tail ends `done`, then `evidence_valid=yes`, and the exit status is 0.

- [ ] **Step 11: If the control is not valid, diagnose — never edit evidence**

Read `validity.txt`, `control-criteria.txt`, `leaf-lifetime.txt`, and `harness.log`. Fix the harness, commit, and run again (Steps 9–10). The failed run's directory is still committed in Step 12, since it is part of the record, and it is never modified.

- [ ] **Step 12: Check size and keys, update the README, and commit the evidence**

Run: `du -sh demos/cert-hygiene/runs/00-baseline-control/* && (grep -rl 'PRIVATE KEY' demos/cert-hygiene/runs || echo none)`
Expected: `none`. If any run directory exceeds 20M, report its largest files (`du -a <dir> | sort -n | tail`) to the user before committing.

In `docs/articles/cert-hygiene/README.md`, set the `Baseline control (00-baseline-control)` row to `Valid run: demos/cert-hygiene/runs/00-baseline-control/<stamp>`, and the `Lab harness` row to `In progress: negative control passes (plan Task 8 of 10)`.

```bash
git add demos/cert-hygiene/runs/00-baseline-control docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record negative control run"
git push
```
