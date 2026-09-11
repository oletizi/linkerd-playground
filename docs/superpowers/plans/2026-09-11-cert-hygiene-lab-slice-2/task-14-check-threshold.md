# Task 14: Scenario K

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 5, `20-check-threshold`, profile `check-threshold`. No expiry, no T_mark: a step-driven scenario (`run_steps_scenario`). Linkerd warns when the issuer expires within 60 days (5 184 000 s) of the moment the check runs, so K brackets that boundary:
1. The profile installs an issuer valid for 1440h − 10m. Run `linkerd check` and `linkerd check --proxy`, recording each command's start and end time and the issuer's `notAfter`.
2. Sign an issuer valid for 1440h + 10m from the same anchor, apply it with the issuer-only `linkerd upgrade`, wait for `IssuerUpdated`, and repeat the checks and the recording.

The 15-minute case already recorded in R completes the comparison (Task 29 reads it from R's runs).

**Validity** (the `k-remaining` rule, design § 5), computed conservatively for each of the four check commands:
- the −10m measurement counts only if `notAfter − start` is under 5 184 000 s;
- the +10m measurement counts only if `notAfter − end` is over 5 184 000 s.

**Design point resolved here: "that step is repeated".** Repeating the +10m step inside the run would sign a third issuer, an undeclared credential state that the plan walk (`A/I1 → A/I2`) rejects. So a +10m measurement that falls on the wrong side makes the run invalid, and Task 23 repeats the step by launching a fresh K run. With a 10-minute margin and checks that take seconds, this should not arise.

No control is needed, because no probe outcome is judged (the rule table omits `control-at-tree` for K).

**Files:**
- Create: `demos/cert-hygiene/scenarios/20-check-threshold.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` (add `k_remaining_check`), `demos/cert-hygiene/lab/tests/test-scenarios.sh`
- Modify: `demos/cert-hygiene/config.example.env` (`K_PLUS_ISSUER_LIFETIME`)

**Interfaces:**
- Consumes: Task 9 `run_steps_scenario`, `make_issuer`, `write_cert`, `wait_issuer_updated`, `cert_not_after_epoch`, `capture`, `tick`, `_kv`.
- Produces:
  - `k/<step>-calc.txt` for `step` in `minus`, `plus`: `step=`, `issuer_not_after_epoch=`, `threshold_s=5184000`, `check_started_epoch=`, `check_ended_epoch=`, `check_proxy_started_epoch=`, `check_proxy_ended_epoch=`, `check_remaining_at_start_s=`, `check_proxy_remaining_at_start_s=`.
  - `k/<step>-check.txt`, `k/<step>-check-proxy.txt` (transcripts, via `capture`); ticks `k-minus`, `k-plus`.
  - `certs/issuer-plus.{pem,txt}`, `recover/linkerd-upgrade.txt`, timeline markers `k-measure`, `k-apply`, `issuer-updated`.
  - `k_remaining_check RUN_DIR` (pure) → `ok:`/`fail:` per command; 0 only when all four hold; `k-remaining.txt` in the run.
  - Config: `K_PLUS_ISSUER_LIFETIME=1440h10m`.

- [ ] **Step 1: Failing tests (append to `demos/cert-hygiene/lab/tests/test-scenarios.sh`, before `finish test-scenarios`)**

```bash
# ---- k_remaining_check ----
TH=5184000
kcalc() { # RUN STEP NOT_AFTER START END
  mkdir -p "$1/k"
  printf 'step=%s\nissuer_not_after_epoch=%s\nthreshold_s=%s\ncheck_started_epoch=%s\ncheck_ended_epoch=%s\ncheck_proxy_started_epoch=%s\ncheck_proxy_ended_epoch=%s\n' \
    "$2" "$3" "$TH" "$4" "$5" "$4" "$5" > "$1/k/$2-calc.txt"
  printf '$ linkerd check\n[exit 0]\n' > "$1/k/$2-check.txt"
  printf '$ linkerd check --proxy\n[exit 0]\n' > "$1/k/$2-check-proxy.txt"
}
N=1800000000
kcalc "$T/k1" minus $(( N + TH - 590 )) "$N" $(( N + 20 ))
kcalc "$T/k1" plus $(( N + 100 + TH + 590 )) $(( N + 100 )) $(( N + 120 ))
assert_succeeds "minus under, plus over 60 days at check time" k_remaining_check "$T/k1"
assert_contains "$(k_remaining_check "$T/k1")" "ok: plus check" "reports each command"
kcalc "$T/k2" minus $(( N + TH - 590 )) "$N" $(( N + 20 ))
kcalc "$T/k2" plus $(( N + 100 + TH + 10 )) $(( N + 100 )) $(( N + 120 ))
assert_fails "plus measured after it dropped under 60 days (conservative: end time)" k_remaining_check "$T/k2"
kcalc "$T/k3" minus $(( N + TH + 5 )) "$N" $(( N + 20 ))
kcalc "$T/k3" plus $(( N + 100 + TH + 590 )) $(( N + 100 )) $(( N + 120 ))
assert_fails "minus still over 60 days at its start" k_remaining_check "$T/k3"
kcalc "$T/k4" minus $(( N + TH - 590 )) "$N" $(( N + 20 ))
assert_fails "a missing plus step fails" k_remaining_check "$T/k4"
kcalc "$T/k5" minus $(( N + TH - 590 )) "$N" $(( N + 20 ))
kcalc "$T/k5" plus $(( N + 100 + TH + 590 )) $(( N + 100 )) $(( N + 120 ))
rm "$T/k5/k/plus-check-proxy.txt"
assert_fails "a missing transcript fails" k_remaining_check "$T/k5"
```

Run: `just demo cert-hygiene test`
Expected: `test-scenarios` fails with `k_remaining_check: command not found`.

- [ ] **Step 2: Implement `k_remaining_check` in `demos/cert-hygiene/lab/lib-evidence-scenarios.sh`**

```bash
# k_remaining_check RUN_DIR: do K's two measurements fall on opposite sides of 60 days
# (5184000 s) at the moment each check ran (design section 5)? Conservative: the -10m
# step is judged at each command's start, the +10m step at each command's end.
k_remaining_check() {
  local run="${1:?k_remaining_check: RUN_DIR required}" bad=0 step f na th c s e rem t
  for step in minus plus; do
    f="$run/k/$step-calc.txt"
    if [ ! -s "$f" ]; then echo "fail: $f missing"; bad=1; continue; fi
    na="$(_kv issuer_not_after_epoch "$f")"
    th="$(_kv threshold_s "$f")"
    [ "$th" = 5184000 ] || { echo "fail: $f threshold_s=$th, want 5184000"; bad=1; continue; }
    for c in check check_proxy; do
      t="$run/k/$step-${c//_/-}.txt"
      if [ ! -s "$t" ]; then echo "fail: transcript $t missing"; bad=1; continue; fi
      s="$(_kv "${c}_started_epoch" "$f")"; e="$(_kv "${c}_ended_epoch" "$f")"
      if [ -z "$na" ] || [ -z "$s" ] || [ -z "$e" ]; then echo "fail: $f lacks $c times or notAfter"; bad=1; continue; fi
      if [ "$step" = minus ]; then
        rem=$(( na - s ))
        if [ "$rem" -lt "$th" ]; then echo "ok: minus $c had ${rem}s left at its start (< ${th}s)"
        else echo "fail: minus $c had ${rem}s left at its start (not < ${th}s)"; bad=1; fi
      else
        rem=$(( na - e ))
        if [ "$rem" -gt "$th" ]; then echo "ok: plus $c had ${rem}s left at its end (> ${th}s)"
        else echo "fail: plus $c had ${rem}s left at its end (not > ${th}s); repeat K in a fresh run"; bad=1; fi
      fi
    done
  done
  return "$bad"
}
```

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines.

- [ ] **Step 3: Setting in `demos/cert-hygiene/config.example.env`**

Append to the `# ---- Credentials ----` section:

```bash
# K: the issuer applied for the +10m side of the 60-day boundary (1440h + 10m).
K_PLUS_ISSUER_LIFETIME=1440h10m
```

- [ ] **Step 4: Write `demos/cert-hygiene/scenarios/20-check-threshold.sh`**

```bash
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
```

`step certificate create --not-after 1440h10m` and `1439h50m` are Go durations; `duration_to_seconds` accepts both forms, so `write_versions` and the leaf check are unaffected.

- [ ] **Step 5: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && bash -n scenarios/20-check-threshold.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/20-check-threshold.sh lab/lib-evidence-scenarios.sh lab/tests/*.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

K's evidence run is Task 23.

```bash
git add demos/cert-hygiene/scenarios/20-check-threshold.sh demos/cert-hygiene/lab demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add linkerd check threshold scenario with remaining-validity validity rule"
git push
```
