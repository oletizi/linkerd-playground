# Task 8: Stages and the restart-choreography control

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 1.7. The control (`00-baseline-control`) runs the same timeline and the same recovery stages as R, with long-lived credentials:
1. `RECOVER_WINDOW_S` with no restarts, sampled at the end;
2. restart client A (`probe-tcp-new`);
3. restart `server`;
4. restart every remaining lab Deployment.

Each restart stage is gated and sampled (Task 7). With nothing expired, every gated sample should succeed. Failures seen *during* restarts are recorded, not counted against the control: they are the rollout-only disruption baseline that the S and R write-ups compare against. The post-expiry window becomes 1800 s (R's new window, design § 2), so the control still snapshots the same moments as R.

The control's criteria change to match:
- no probe `fail` or `closed` line between the baseline tick and the `recover` marker (all four probes);
- exactly one stream `connect` line before the `recover` marker (stage 3 restarts `server`, which ends the stream, and stage 4 restarts the stream pod);
- every gate record exists, passed, and has only successful samples;
- the post-expiry workloads' final rollouts completed;
- no fatal check result and no certificate-lifetime warning in any check.

Probe history is read from every `probes/<label>/` snapshot, deduplicated, because stage 4 replaces every probe pod and `probes/final/` alone would miss the earlier pods.

This task also adds `scripts/run.sh --discovery`. The discovery smoke run of the new control is at the end of Task 9.

**Files:**
- Create: `demos/cert-hygiene/lab/stages.sh`
- Modify: `demos/cert-hygiene/lab/scenario-common.sh` (source `gates.sh` and `stages.sh`; verify every lab Deployment's rollout)
- Modify: `demos/cert-hygiene/scenarios/00-baseline-control.sh`, `demos/cert-hygiene/scenarios/05-issuer-expiry.sh` (use the moved helpers)
- Modify: `demos/cert-hygiene/lab/lib-evidence-control.sh` (`control_criteria_check`), `demos/cert-hygiene/lab/tests/test-control.sh`
- Modify: `demos/cert-hygiene/scripts/run.sh` (`--discovery`), `demos/cert-hygiene/Justfile` (`run-discovery`), `demos/cert-hygiene/config.example.env` (`POST_EXPIRY_WINDOW_S=1800`)

**Interfaces:**
- Consumes: Task 7 (`restart_and_gate`, `stage_samples`, `lab_deployments`, `gate_summary`), `observe_until`, `post_expiry_hook`, `tick`, `snap_logs`, `snap_probes`.
- Produces:
  - `snap_before_restart LABEL` (logs and probe history of the pods a stage is about to replace).
  - `wait_issuer_updated TIMEOUT_S` (moved from R's scenario file, unchanged behaviour; timeline marker `issuer-updated …`).
  - `stage_window STAGE WINDOW_S`: ticks `<STAGE>-N` every `OBSERVE_INTERVAL_S` for `WINDOW_S` with no restarts, then `stage_samples STAGE`.
  - `restart_stages`: stage names `stage1-norestart`, `stage2-client-a`, `stage3-server`, `stage4-all`; gate records `gates/<stage>.txt`; ticks `stage1-N` during the window and one tick named after each restart stage; log snapshots `pre-stage2`, `pre-stage3`, `pre-stage4`.
  - `matrix_restart_stages`: stages 2–4 alone (used by `restart_stages` and by S-hard, Task 17).
  - `_all_probe_lines RUN_DIR PROBE`: the probe's lines from every `probes/*/` snapshot, deduplicated and time-sorted.
  - `pods/verify-rollout-<deploy>.txt` for every lab Deployment.
  - `scripts/run.sh [--discovery] SCENARIO`: with `--discovery`, the run directory is `runs/_discovery/<UTC>-<scenario>` instead of `runs/<scenario>/<UTC>`.

- [ ] **Step 1: Rewrite the control-criteria tests**

In `demos/cert-hygiene/lab/tests/test-control.sh`, replace the whole `make_ctl` function with:

```bash
make_ctl() { # dir: a control run that meets every criterion (probes/final/, one pod per probe)
  local d="$1" p="$1/probes/final" s
  mkdir -p "$p" "$d/pods" "$d/checks" "$d/gates"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n2026-09-10T10:30:00Z recover\n' > "$d/timeline.log"
  printf '$ kubectl -n lab logs probe-http-1 -c probe\n2026-09-10T10:04:58Z probe-http seq=1 fail curl_rc=7 http=000 err=refused\n2026-09-10T10:05:01Z probe-http seq=2 ok http=200\n[exit 0]\n' > "$p/probe-http-1.log"
  printf '$ kubectl -n lab logs probe-http-1 -c probe --previous\nError from server (BadRequest): previous terminated container "probe" in pod "probe-http-1" not found\n[exit 1]\n' > "$p/probe-http-1-previous.log"
  printf '2026-09-10T10:05:01Z probe-tcp-new seq=2 ok\n' > "$p/probe-tcp-new-1.log"
  printf '2026-09-10T10:05:01Z probe-tcp-new-b seq=2 ok\n' > "$p/probe-tcp-new-b-1.log"
  printf '2026-09-10T10:04:59Z probe-tcp-stream seq=0 conn=ab-1 connect target=s:9000\n2026-09-10T10:05:01Z probe-tcp-stream seq=2 conn=ab-1 ok\n' > "$p/probe-tcp-stream-1.log"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-restart-target.txt"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-probe-new.txt"
  printf '$ linkerd check\n√ issuer cert is valid for at least 60 days\n‼ cli is up-to-date\n[exit 0]\n' > "$d/checks/verify-check.txt"
  for s in stage1-norestart stage2-client-a stage3-server stage4-all; do
    printf 'stage=%s\ngate=pass\ncell pair=A ok=10 fail=0 status=classified\ncell pair=B ok=10 fail=0 status=classified\n' "$s" > "$d/gates/$s.txt"
  done
}
```

Delete the line `make_ctl "$T/ccb"; rm "$T/ccb/probes/final/probe-tcp-new-b-1.log"` and the `assert_fails` line after it, and replace them with the block below. The existing `cc1`–`cc7`, `ccb2` tests stay (their failures are timed 10:20, before the `recover` marker).

```bash
make_ctl "$T/ccb"; rm "$T/ccb/probes/final/probe-tcp-new-b-1.log"
assert_fails "the control needs the second client's lines" control_criteria_check "$T/ccb"
make_ctl "$T/cr1"; printf '2026-09-10T10:40:00Z probe-tcp-new seq=900 fail socat_rc=1\n' >> "$T/cr1/probes/final/probe-tcp-new-1.log"
assert_succeeds "a failure during the restart stages is recorded, not a criteria failure" control_criteria_check "$T/cr1"
make_ctl "$T/cr2"; mkdir -p "$T/cr2/probes/pre-stage4"
printf '2026-09-10T10:50:00Z probe-tcp-stream seq=0 conn=cd-2 connect target=s:9000\n' > "$T/cr2/probes/pre-stage4/probe-tcp-stream-2.log"
assert_succeeds "a stream reconnect after the recover marker is allowed" control_criteria_check "$T/cr2"
make_ctl "$T/cr3"; mkdir -p "$T/cr3/probes/pre-stage2"
printf '2026-09-10T10:20:00Z probe-http seq=9 fail curl_rc=7\n' > "$T/cr3/probes/pre-stage2/probe-http-1.log"
assert_fails "a pre-recover failure in an earlier probe snapshot breaks the control" control_criteria_check "$T/cr3"
make_ctl "$T/cr4"; printf 'stage=stage3-server\ngate=pass\ncell pair=A ok=9 fail=1 status=classified\ncell pair=B ok=10 fail=0 status=classified\n' > "$T/cr4/gates/stage3-server.txt"
assert_fails "a failed gated sample breaks the control" control_criteria_check "$T/cr4"
make_ctl "$T/cr5"; printf 'stage=stage2-client-a\ngate=timeout\ncell pair=A ok=10 fail=0 status=unclassified\ncell pair=B ok=10 fail=0 status=unclassified\n' > "$T/cr5/gates/stage2-client-a.txt"
assert_fails "a timed-out gate breaks the control" control_criteria_check "$T/cr5"
make_ctl "$T/cr6"; rm -r "$T/cr6/gates"
assert_fails "no gate records breaks the control" control_criteria_check "$T/cr6"
make_ctl "$T/cr7"; printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n' > "$T/cr7/timeline.log"
assert_fails "no recover marker breaks the control" control_criteria_check "$T/cr7"
```

Run: `just demo cert-hygiene test`
Expected: `test-control` fails (at least `cr1`, `cr2`, `cr4`, `cr5`, `cr6`, `cr7`).

- [ ] **Step 2: Rewrite `control_criteria_check` in `demos/cert-hygiene/lab/lib-evidence-control.sh`**

Replace the function and its comment with:

```bash
# _all_probe_lines RUN_DIR PROBE: PROBE's lines from every probes/<label>/ snapshot
# (restart stages replace probe pods, so no single snapshot holds them all),
# deduplicated and sorted by time.
_all_probe_lines() {
  local run="$1" p="$2" dir
  for dir in "$run"/probes/*/; do
    [ -d "$dir" ] || continue
    _probe_lines "$dir" "$p"
  done | sort -u
}

# control_criteria_check RUN_DIR: the restart-choreography control's criteria (design
# section 1.7). Probe lines count only from the baseline tick to the recover marker:
# before baseline is startup noise, and during the restart stages failures are the
# rollout-disruption baseline, recorded but not judged here. The stages are judged by
# their gate records: every gate passed and every gated sample succeeded.
control_criteria_check() {
  local run="${1:?control_criteria_check: RUN_DIR required}" bad=0 t r p n f lines g s
  t="$(awk '$2 == "tick" && $3 == "baseline" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  r="$(awk '$2 == "recover" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  [ -n "$t" ] || { echo "fail: no baseline tick in timeline.log"; return 1; }
  [ -n "$r" ] || { echo "fail: no recover marker in timeline.log"; return 1; }
  for p in probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream; do
    lines="$(_all_probe_lines "$run" "$p")"
    if [ -z "$lines" ]; then echo "fail: no $p lines in $run/probes/"; bad=1; continue; fi
    n="$(printf '%s\n' "$lines" | awk -v t="$t" -v r="$r" '$1 >= t && $1 < r && / (fail|closed) /' | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then echo "ok: $p has no fail/closed lines between baseline and recover"
    else echo "fail: $p has $n fail/closed lines between baseline and recover"; bad=1; fi
  done
  n="$(_all_probe_lines "$run" probe-tcp-stream | awk -v r="$r" '$1 < r && / connect /' | wc -l | tr -d ' ')"
  if [ "$n" = 1 ]; then echo "ok: one stream connection before recover"
  else echo "fail: $n stream connect lines before recover, want 1"; bad=1; fi
  n=0
  for f in "$run"/gates/*.txt; do
    [ -f "$f" ] || continue
    case "$f" in *-restart.txt) continue ;; esac
    n=$((n + 1))
    if ! s="$(gate_summary "$f")"; then echo "$s"; bad=1; continue; fi
    g="${s%% *}"
    if [ "$g" = gate=timeout ]; then echo "fail: $(basename "$f") gate timed out"; bad=1; fi
    if grep -qE '^cell .* fail=[1-9]' "$f" || grep -qE '^cell .* ok=0 ' "$f"; then
      echo "fail: $(basename "$f") has failed gated samples: $s"; bad=1
    else
      echo "ok: $(basename "$f") $s"
    fi
  done
  if [ "$n" -eq 0 ]; then echo "fail: no gate records in $run/gates/"; bad=1; fi
  for f in verify-rollout-restart-target verify-rollout-probe-new; do
    if [ "$(tail -n 1 "$run/pods/$f.txt" 2>/dev/null)" = "[exit 0]" ]; then echo "ok: $f completed"
    else echo "fail: $f did not complete"; bad=1; fi
  done
  # grep -l exits 1 when nothing matches -- the passing case -- so it must not fail
  # the pipeline under set -e / pipefail.
  n="$({ grep -l '×' "$run"/checks/*.txt 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no fatal check results"
  else echo "fail: $n check files contain a fatal (×) result"; bad=1; fi
  n="$({ grep -lE '‼.*valid for at least 60 days' "$run"/checks/*.txt 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no certificate-lifetime warnings"
  else echo "fail: $n check files carry a certificate-lifetime warning"; bad=1; fi
  return "$bad"
}
```

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 3: Write `demos/cert-hygiene/lab/stages.sh`**

```bash
#!/usr/bin/env bash
# Recovery stage choreographies (design sections 1.7 and 2). Source after
# lab/scenario-common.sh's helpers, lab/collect.sh and lab/gates.sh; do not execute.

snap_before_restart() { # LABEL: logs and probe history of the pods a stage will replace
  snap_logs "$1"
  snap_probes "$1"
}

wait_issuer_updated() { # TIMEOUT_S: record when (or whether) identity reloaded the issuer
  local t0 deadline
  t0="$(date -u +%s)"
  deadline=$(( t0 + $1 ))
  until kubectl -n linkerd get events --field-selector reason=IssuerUpdated -o name 2>/dev/null | grep -q .; do
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
      mark issuer-updated "no IssuerUpdated event within ${1}s"
      return 0
    fi
    sleep 5
  done
  mark issuer-updated "IssuerUpdated event seen $(( $(date -u +%s) - t0 ))s after apply"
}

stage_window() { # STAGE WINDOW_S: no restarts for WINDOW_S (ticks STAGE-N), then samples
  local stage="$1" window="$2"
  mark stage "$stage: no restarts for ${window}s"
  observe_until $(( $(date -u +%s) + window )) "${stage%%-*}" post_expiry_hook
  stage_samples "$stage"
}

# restart_stages: the four cumulative stages that map endpoint state (design section 2):
# no restarts; client A; server; everything else. Used by the control, R and O.
restart_stages() {
  stage_window stage1-norestart "$RECOVER_WINDOW_S"
  matrix_restart_stages
}

# matrix_restart_stages: stages 2-4 of the matrix, each gated and sampled. S-hard uses
# them after its own condition-driven stage 1.
matrix_restart_stages() {
  local rest
  snap_before_restart pre-stage2
  restart_and_gate stage2-client-a probe-tcp-new
  tick stage2-client-a
  snap_before_restart pre-stage3
  restart_and_gate stage3-server server
  tick stage3-server
  snap_before_restart pre-stage4
  mapfile -t rest < <(lab_deployments | grep -vx -e probe-tcp-new -e server)
  [ "${#rest[@]}" -ge 1 ] || die "restart_stages: no lab Deployments left for stage 4"
  restart_and_gate stage4-all "${rest[@]}"
  tick stage4-all
}
```

`stage_window stage1-norestart …` names its ticks `stage1-1`, `stage1-2`, … (the part of the stage name before the first `-`).

- [ ] **Step 4: Wire it into `demos/cert-hygiene/lab/scenario-common.sh`**

After the line `. "$LAB_DIR/collect.sh"`, add:

```bash
# shellcheck source=/dev/null
. "$LAB_DIR/gates.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/stages.sh"
```

In `run_scenario`, replace the two lines

```bash
  capture pods/verify-rollout-restart-target.txt kubectl -n "$LAB_NS" rollout status deploy/restart-target --timeout=120s
  capture pods/verify-rollout-probe-new.txt kubectl -n "$LAB_NS" rollout status deploy/probe-new --timeout=120s
```

with

```bash
  for d in $(lab_deployments); do
    capture "pods/verify-rollout-$d.txt" kubectl -n "$LAB_NS" rollout status "deploy/$d" --timeout=120s
  done
```

and add `d` to `run_scenario`'s `local` line.

- [ ] **Step 5: Update the two scenario files**

`demos/cert-hygiene/scenarios/00-baseline-control.sh` — replace the header comment and `scenario_recover`:

```bash
#!/usr/bin/env bash
# Negative control with restart choreography (design section 1.7): R's timeline and
# R's four gated recovery stages, with long-lived credentials. T_mark sits where R's
# issuer would expire, so both runs snapshot the same moments. Nothing should fail
# outside a restart; failures during restarts are the rollout-disruption baseline.
# Launch with scripts/run.sh.
```

```bash
scenario_recover() {
  mark recover-none "control run: nothing expired; running R's restart stages with nothing to recover"
  restart_stages
}
```

`demos/cert-hygiene/scenarios/05-issuer-expiry.sh` — delete `_before_restart` and `_wait_issuer_updated` (they now live in `stages.sh` as `snap_before_restart` and `wait_issuer_updated`), and in `scenario_recover` change `_wait_issuer_updated 180` to `wait_issuer_updated 180` and both `_before_restart` calls to `snap_before_restart`. Task 10 rewrites the rest of R.

- [ ] **Step 6: The 1800-second window in `demos/cert-hygiene/config.example.env`**

Change `POST_EXPIRY_WINDOW_S=600` to:

```bash
POST_EXPIRY_WINDOW_S=1800   # R's window (design 2); the control mirrors it
```

- [ ] **Step 7: `--discovery` in `demos/cert-hygiene/scripts/run.sh`**

Change the usage comment to `# Usage: run.sh [--discovery] <scenario>, e.g. run.sh 00-baseline-control. With --discovery the run goes under runs/_discovery/ and is never evidence.` Replace the three lines from `scenario="${1:?usage: run.sh <scenario>}"` through `rel="runs/$scenario/$(date -u +%Y%m%dT%H%M%SZ)"` with:

```bash
discovery=no
if [ "${1:-}" = --discovery ]; then discovery=yes; shift; fi
scenario="${1:?usage: run.sh [--discovery] <scenario>}"
[ -f "$DEMO/scenarios/$scenario.sh" ] || die "no scenario '$scenario' in $DEMO/scenarios/"
if [ "$discovery" = yes ]; then
  rel="runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)-$scenario"
else
  rel="runs/$scenario/$(date -u +%Y%m%dT%H%M%SZ)"
fi
```

Append to `demos/cert-hygiene/Justfile`:

```just

# Launch a scenario as a discovery run (runs/_discovery/; never evidence)
run-discovery SCENARIO:
    bash scripts/run.sh --discovery {{SCENARIO}}
```

- [ ] **Step 8: Syntax, shellcheck, tests**

Run: `cd demos/cert-hygiene && for f in lab/*.sh scenarios/*.sh scripts/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/*.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh lab/tests/*.sh scenarios/*.sh scripts/*.sh'`
Expected: no errors; every file under 300 lines; no findings.

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 9: Commit**

The end-to-end discovery smoke run of this control happens at the end of Task 9, after the timeline restructure, so one run covers both tasks.

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/scenarios demos/cert-hygiene/scripts demos/cert-hygiene/Justfile demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene run R's gated restart stages in the control"
git push
```
