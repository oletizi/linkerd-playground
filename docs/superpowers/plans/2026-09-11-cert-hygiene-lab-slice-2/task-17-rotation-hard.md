# Task 17: Scenario S-hard

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 7, `08-anchor-rotation-hard`, profile `long`. At T_mark (`FAULT_LEAD_S` after it is computed), `scenario_fault` replaces the anchor and issuer in one step, `--force`, with no bundle. There are no post-actions and no post window (`POST_EXPIRY_WINDOW_S=0`). Recovery is:
1. **No restarts,** until each unrestarted endpoint meets the stage-1 condition below, or `S_HARD_STAGE1_TIMEOUT_S` after the swap passes. **A timeout makes the run invalid** (the `s-hard-stage1` rule reads `s-hard/stage1-condition.txt`). Then `stage_samples stage1-norestart` classifies the matrix's row 1.
2. Restart client A only, then gate and sample.
3. Restart `server`, then gate and sample.
4. Restart everything else, then gate and sample.

Stages 2–4 are `matrix_restart_stages` (Task 8). Each pod's trust hash is on every tick (`trust/<tick>.txt`), so the mixed-anchor states of the design's matrix are recorded directly. The credential plan is `A/I1 → B/I2`.

**The stage-1 condition** (design § 7), for each unrestarted endpoint: client A (`probe-tcp-new`), client B (`probe-tcp-new-b`) and `server`. The run must have recorded the endpoint's last old leaf and its `notAfter`, its renewal attempt after the swap and the result, and its first failed forced-new connection after that leaf expired.

**Design point resolved here: a renewal that succeeds.** S4 predicts that unrestarted proxies can't take a renewed certificate chained to the new anchor. Read literally, the condition can only be met if S4 holds, so a falsified S4 would end every run in a timeout, invalid. That would make S4 unfalsifiable. So an endpoint also meets the condition when the run records a successful renewal after the swap; its state is recorded as `renewed`, which is evidence against S4. Per endpoint, from the tick's metrics section and the forced-new probe lines (both of the endpoint's clients, for `server`):
- `expired-failed`: no successful refresh since the swap (refresh time before the swap); the current leaf's `notAfter` has passed; a failed refresh has been counted since the last pre-swap tick (`fault-minus10`); and a forced-new connection failed after that `notAfter`. The record carries the old leaf's `notAfter`, the refresh attempts, and the first failure's timestamp.
- `renewed`: a successful refresh after the swap (refresh time at or after the swap, and the ok count grew).
- `pending`: anything else, including unreadable metrics.

`S_HARD_STAGE1_TIMEOUT_S=900`. A current leaf lasts at most 5 minutes plus the 20 s skew, so every old leaf expires by swap + 320 s. The rest leaves room for a 10 s refresh retry, a 30 s tick interval, and the next probe attempt.

**Files:**
- Create: `demos/cert-hygiene/scenarios/08-anchor-rotation-hard.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` (add `pod_section`, `s_hard_endpoint_state`), `demos/cert-hygiene/lab/tests/test-scenarios.sh`
- Modify: `demos/cert-hygiene/config.example.env` (`S_HARD_STAGE1_TIMEOUT_S`)

**Interfaces:**
- Consumes: Task 9 hooks and `run_scenario`, Task 8 `matrix_restart_stages`, Task 7 `stage_samples`, `_current_pod`, `make_trust_anchor`, `make_issuer`, `write_cert`, `snap_controlplane`.
- Produces:
  - `pod_section METRICS_FILE POD` (pure) → the lines of POD's section (`== lab/POD :4191` up to the next `==`) in a tick's metrics file; nothing if absent.
  - `s_hard_endpoint_state SWAP_EPOCH NOW_EPOCH BEFORE_SECTION NOW_SECTION LINES_FILE` (pure) → one line starting `state=expired-failed|renewed|pending` with the recorded values; returns 0 for the first two, 1 for pending.
  - Evidence: `certs/trust-anchor-new.{pem,txt}`, `certs/issuer-new.{pem,txt}`, `swap/linkerd-upgrade.txt`, `swap/rollout.txt`, `controlplane/swap-after.txt`; ticks `stage1-N`; `s-hard/stage1.txt` (one line per endpoint per tick); `s-hard/stage1-condition.txt` (first line `result=met|timeout`, then `swap_epoch=`, `timeout_s=`, and the per-tick lines); `gates/stage1-norestart.txt` and the three matrix gate records; timeline markers `s-hard-swap`, `stage s-hard stage 1: …`.
  - Config: `S_HARD_STAGE1_TIMEOUT_S=900`.

- [ ] **Step 1: Failing tests (append to `demos/cert-hygiene/lab/tests/test-scenarios.sh`, before `finish test-scenarios`)**

```bash
# ---- pod_section ----
printf 'sampled_at_epoch=1\n== lab/a :4191\nm_a 1\n== lab/b :4191\nm_b 2\nm_b2 3\n== linkerd/id :9990\nx 9\n' > "$T/metrics.txt"
assert_eq "$(pod_section "$T/metrics.txt" b | paste -sd' ' -)" "m_b 2 m_b2 3" "a pod's section, up to the next header"
assert_eq "$(pod_section "$T/metrics.txt" zzz)" "" "an absent pod has no section"

# ---- s_hard_endpoint_state ----
SWAP_T=1800000000
sec() { # FILE REFRESH EXPIRY OK ERR
  printf 'control_identity_cert_expiration_timestamp_seconds %s.0\ncontrol_identity_cert_refresh_timestamp_seconds %s.25\ncontrol_identity_cert_refreshes_total{result="ok"} %s\ncontrol_identity_cert_refreshes_total{result="error"} %s\n' \
    "$3" "$2" "$4" "$5" > "$1"
}
sec "$T/before" $(( SWAP_T - 100 )) $(( SWAP_T + 220 )) 5 0
printf '2026-09-11T00:00:00Z probe-tcp-new seq=1 ok\n' > "$T/lines-none"
printf '%s probe-tcp-new seq=9 fail socat_rc=1\n' "$(date -u -d "@$(( SWAP_T + 230 ))" +%Y-%m-%dT%H:%M:%SZ)" > "$T/lines-fail"
printf '%s probe-tcp-new seq=8 fail socat_rc=1\n' "$(date -u -d "@$(( SWAP_T + 100 ))" +%Y-%m-%dT%H:%M:%SZ)" > "$T/lines-early"
sec "$T/n1" $(( SWAP_T - 100 )) $(( SWAP_T + 220 )) 5 3
out="$(s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 240 )) "$T/before" "$T/n1" "$T/lines-fail")"
assert_contains "$out" "state=expired-failed" "old leaf expired, renewal failed, then a new connection failed"
assert_contains "$out" "old_leaf_not_after=$(( SWAP_T + 220 ))" "records the old leaf's notAfter"
assert_succeeds "expired-failed meets the condition" s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 240 )) "$T/before" "$T/n1" "$T/lines-fail"
assert_fails "no failure after the leaf expired: pending" s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 240 )) "$T/before" "$T/n1" "$T/lines-early"
assert_fails "leaf not yet expired: pending" s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 200 )) "$T/before" "$T/n1" "$T/lines-fail"
sec "$T/n2" $(( SWAP_T - 100 )) $(( SWAP_T + 220 )) 5 0
assert_fails "expired and failed, but no failed renewal counted: pending" s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 240 )) "$T/before" "$T/n2" "$T/lines-fail"
sec "$T/n3" $(( SWAP_T + 60 )) $(( SWAP_T + 380 )) 6 0
assert_contains "$(s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 90 )) "$T/before" "$T/n3" "$T/lines-none")" "state=renewed" "a successful renewal after the swap"
assert_succeeds "renewed meets the condition (S4 falsifiable)" s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 90 )) "$T/before" "$T/n3" "$T/lines-none"
: > "$T/n4"
assert_fails "unreadable metrics: pending" s_hard_endpoint_state "$SWAP_T" $(( SWAP_T + 240 )) "$T/before" "$T/n4" "$T/lines-fail"
```

Run: `just demo cert-hygiene test`
Expected: `test-scenarios` fails with `pod_section: command not found`.

- [ ] **Step 2: Implement both in `demos/cert-hygiene/lab/lib-evidence-scenarios.sh`**

```bash
# pod_section METRICS_FILE POD: POD's lines in a tick's metrics file (metrics/<tick>.txt).
pod_section() {
  awk -v h="== lab/${2:?pod_section: POD required} " 'index($0, h) == 1 { on = 1; next } /^== / { on = 0 } on' "${1:?}"
}

_exact() { awk -v n="$1" '$1 == n { v = $2 } END { print v }' "$2"; } # NAME FILE

# s_hard_endpoint_state SWAP_EPOCH NOW_EPOCH BEFORE_SECTION NOW_SECTION LINES_FILE:
# S-hard's stage-1 condition for one unrestarted endpoint (design section 7, with a
# successful renewal accepted so that S4 stays falsifiable). Returns 0 when met.
s_hard_endpoint_state() {
  local swap="$1" now="$2" b="$3" c="$4" l="$5" exp ref okb errb okn errn ts first=-
  exp="$(_exact control_identity_cert_expiration_timestamp_seconds "$c")"
  ref="$(_exact control_identity_cert_refresh_timestamp_seconds "$c")"
  okb="$(_exact 'control_identity_cert_refreshes_total{result="ok"}' "$b")"
  errb="$(_exact 'control_identity_cert_refreshes_total{result="error"}' "$b")"
  okn="$(_exact 'control_identity_cert_refreshes_total{result="ok"}' "$c")"
  errn="$(_exact 'control_identity_cert_refreshes_total{result="error"}' "$c")"
  if [ -z "$exp" ] || [ -z "$ref" ] || [ -z "$okb" ] || [ -z "$errb" ] || [ -z "$okn" ] || [ -z "$errn" ]; then
    echo "state=pending reason=metrics-unreadable"; return 1
  fi
  exp="${exp%.*}"; ref="${ref%.*}"
  if [ "$ref" -ge "$swap" ] && [ "$okn" -gt "$okb" ]; then
    echo "state=renewed refresh=$ref leaf_not_after=$exp renew_ok=$(( okn - okb )) renew_err=$(( errn - errb ))"
    return 0
  fi
  while read -r ts _; do
    if [ "$(date -u -d "$ts" +%s)" -gt "$exp" ]; then first="$ts"; break; fi
  done < <(awk '/ fail /' "$l")
  local detail="old_leaf_not_after=$exp renew_attempts=$(( okn + errn - okb - errb )) renew_err=$(( errn - errb )) first_fail_after_expiry=$first"
  if [ "$exp" -lt "$now" ] && [ "$errn" -gt "$errb" ] && [ "$first" != - ]; then
    echo "state=expired-failed $detail"; return 0
  fi
  echo "state=pending $detail"
  return 1
}
```

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines.

- [ ] **Step 3: Setting in `demos/cert-hygiene/config.example.env`**

Append to the `# ---- Timing (seconds) ----` section:

```bash
# S-hard: stage 1 ends when every unrestarted endpoint's old leaf has expired and failed
# (or it renewed); past this many seconds after the swap, the run is invalid.
S_HARD_STAGE1_TIMEOUT_S=900
```

- [ ] **Step 4: Write `demos/cert-hygiene/scenarios/08-anchor-rotation-hard.sh`**

```bash
#!/usr/bin/env bash
# Scenario S-hard (design section 7): the trust anchor and issuer are replaced in one
# step (--force, no bundle) at T_mark. No restarts until every unrestarted endpoint's
# old leaf has expired and failed, or it renewed, within S_HARD_STAGE1_TIMEOUT_S; then
# the matrix stages: client A, server, everything else. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

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
  # shellcheck disable=SC2016
  capture swap/rollout.txt bash -c \
    'for d in $(kubectl -n linkerd get deploy -o name); do kubectl -n linkerd rollout status "$d" --timeout=300s || exit 1; done'
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
      if ! state="$(s_hard_endpoint_state "$S_SWAP_EPOCH" "$now" "$tmp/before" "$tmp/now" "$tmp/${role%%:*}")"; then met=no; fi
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
```

A timed-out stage 1 still proceeds through the matrix stages, so the run's evidence is complete. The validity rule marks it invalid.

- [ ] **Step 5: Syntax, shellcheck, line counts**

Run: `cd demos/cert-hygiene && bash -n scenarios/08-anchor-rotation-hard.sh && wc -l lab/lib-evidence-scenarios.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/08-anchor-rotation-hard.sh lab/lib-evidence-scenarios.sh lab/tests/*.sh'`
Expected: no errors; `lib-evidence-scenarios.sh` under 300 lines; no findings.

- [ ] **Step 6: Commit**

S-hard's evidence run is Task 26, after its discovery run (Task 19).

```bash
git add demos/cert-hygiene/scenarios/08-anchor-rotation-hard.sh demos/cert-hygiene/lab demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add hard trust-anchor swap scenario with a per-endpoint stage-1 condition"
git push
```
