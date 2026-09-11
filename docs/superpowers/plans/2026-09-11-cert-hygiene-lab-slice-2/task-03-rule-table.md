# Task 3: Validity rule table (TDD)

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Replace `evaluate_validity`'s scenario-name special cases with one rule table (design § 1.3), keyed by scenario name and unit-tested: common rules for every scenario, the credential-plan walk for every scenario, and the per-scenario rules. The slice-1 trust-anchor invariant (`trust_summary`, `trust_invariant_check`, `trust-invariant.txt`) is removed: the plan walk subsumes it ("the trust label never changes"). `lib-evidence.sh` is split so no file passes 300 lines.

**The table** (design § 1.3, with the evidence file each rule reads):

| Rule id | Reads | Applies to |
| --- | --- | --- |
| common | `git-state.txt`, no `discovery.txt` (a discovery run is never evidence; `scripts/run.sh --discovery` writes it, Task 8), required files, `timeline.log` ends `done`, per-tick files, proxy logs, `leaf-lifetime.txt`, `versions.txt` | every scenario |
| plan | `credential-plan.txt` starts `result=ok` | every scenario |
| `control-criteria` | `control-criteria.txt` starts `result=ok` | `00-baseline-control` |
| `recovery-apply` | `recover/linkerd-upgrade.txt` ends `[exit 0]` | R, A |
| `webhook-baseline` | `admission-baseline.txt` starts `result=ok` (Task 11 writes it) | both W |
| `w-plain-render` | `recover/plain-render.txt` and `recover/plain-apply.txt` end `[exit 0]`, and `recover/plain-manifest.yaml` is non-empty (Task 12 writes them): the plain `linkerd upgrade` really rendered and applied, so W6 never records a harness failure as Linkerd behaviour | both W |
| `k-remaining` | `k-remaining.txt` starts `result=ok` (Task 14 writes it) | K |
| `s-hard-stage1` | `s-hard/stage1-condition.txt` starts `result=met` (Task 17 writes it) | S-hard |
| `control-at-tree` | a valid control run with the same `harness_tree_sha256` | every timed scenario: all except K and the control itself |

A restart-stage gate that times out is **not** a rule: it yields an unclassified cell (design § 1.3, § 1.6).

**Files:**
- Create: `demos/cert-hygiene/lab/lib-evidence-rules.sh`, `demos/cert-hygiene/lab/lib-evidence-control.sh`
- Create: `demos/cert-hygiene/lab/tests/fixtures.sh`, `demos/cert-hygiene/lab/tests/test-rules.sh`, `demos/cert-hygiene/lab/tests/test-control.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence.sh` (remove moved and retired functions; source the new files)
- Modify: `demos/cert-hygiene/lab/tests/test-evidence.sh` (keep only the core-helper tests)
- Modify: `demos/cert-hygiene/lab/scenario-common.sh` (write `credential-plan.txt` instead of `trust-invariant.txt`)

**Interfaces:**
- Consumes: Task 2 (`credential_plan_walk`), the existing `_kv`, `_control_passed`, `_probe_lines`, `control_criteria_check`, `_missing_proxy_logs`.
- Produces:
  - `LAB_SCENARIOS` (array of the nine scenario names in the README table).
  - `scenario_rules SCENARIO` → rule ids, one per line (table above, excluding common and plan). Dies for an unknown scenario.
  - `scenario_required_files SCENARIO` → run-relative paths, one per line. Common: `versions.txt git-state.txt timeline.log leaf-lifetime.txt credential-plan.txt certs/trust-anchor.{pem,txt} certs/issuer-initial.{pem,txt}`. Per scenario, in addition:
    - control: `control-criteria.txt`
    - R: `certs/issuer-replacement.{pem,txt}`, `recover/linkerd-upgrade.txt`
    - W: `certs/webhook-ca.{pem,txt}`, `certs/webhook-<component>.{pem,txt}` for the three components, `admission-baseline.txt`, `recover/branch.txt`, `recover/plain-render.txt`, `recover/plain-apply.txt`, `recover/plain-manifest.yaml`
    - O: nothing more
    - K: `certs/issuer-plus.{pem,txt}`, `k-remaining.txt`
    - A: `certs/trust-anchor-new.{pem,txt}`, `certs/issuer-replacement.{pem,txt}`, `recover/linkerd-upgrade.txt`
    - S-staged: `certs/trust-anchor-new.{pem,txt}`, `certs/trust-bundle.{pem,txt}`, `certs/issuer-new.{pem,txt}`
    - S-hard: `certs/trust-anchor-new.{pem,txt}`, `certs/issuer-new.{pem,txt}`, `s-hard/stage1-condition.txt`
  - `credential_plan_for SCENARIO` → the plan file text (Task 2 contract). Plans: control and O `A/I1`; R and K `A/I1 A/I2`; A and S-hard `A/I1 B/I2`; S-staged `A/I1 A+B/I1 A+B/I2 B/I2`; both W: components `trust issuer webhooks`, plan `A/I1/W1 A/I1/W2`. All others use components `trust issuer`. W's recovery (Task 12) records the state between its plain upgrade and its explicit re-supply in non-tick artifacts (`recover/plain-facts.txt`, `webhooks/recover-plain.txt`), so the ticks see exactly one webhook change, whichever branch occurs; the intermediate state is declared and recorded by the branch record, not by the plan.
  - `credential_plan_check RUN_DIR SCENARIO` → prints `declared: <plan line>` lines then the walk over `credentials/<tick>.txt` for every tick in `timeline.log` order. Returns 0 only if it walks.
  - `evaluate_validity RUN_DIR SCENARIO EXPECTED_LINKERD_VERSION [CONTROL_RUNS_DIR]` (same signature). Per tick it now requires `checks/<t>-check.txt`, `checks/<t>-check-proxy.txt`, `metrics/<t>.txt`, `pods/<t>.txt`, `credentials/<t>.txt`, `webhooks/<t>.txt`, `controlplane/<t>.txt` (Tasks 4–5 write the last three).
  - `tests/fixtures.sh`: `make_run DIR SCENARIO COMMIT HARNESS DIRTY` builds a complete, valid fixture run for any scenario.

- [ ] **Step 1: Write `demos/cert-hygiene/lab/tests/fixtures.sh`**

```bash
#!/usr/bin/env bash
# Fixture runs for the lab's unit tests. Source after lab/lib-evidence.sh; do not execute.

# make_run DIR SCENARIO COMMIT HARNESS DIRTY: a complete run directory that
# evaluate_validity accepts for SCENARIO (given a valid control at HARNESS, where the
# scenario needs one). Tests then break one thing at a time.
make_run() {
  local d="$1" scenario="$2" t f
  mkdir -p "$d"/{certs,checks,metrics,pods,credentials,webhooks,controlplane,logs/final,logs/pre-recover}
  printf 'demo_repo_commit=%s\ndemo_repo_dirty=%s\nharness_tree_sha256=%s\n' "$3" "$5" "$4" > "$d/git-state.txt"
  printf 'linkerd_cli_version=edge-26.9.1\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$d/versions.txt"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n2026-09-10T10:40:00Z tick verify\n2026-09-10T10:41:00Z done\n' > "$d/timeline.log"
  for t in baseline verify; do
    for f in "checks/$t-check.txt" "checks/$t-check-proxy.txt" "metrics/$t.txt" "pods/$t.txt" \
        "credentials/$t.txt" "webhooks/$t.txt" "controlplane/$t.txt"; do
      echo x > "$d/$f"
    done
  done
  while read -r f; do
    mkdir -p "$(dirname "$d/$f")"
    echo x > "$d/$f"
  done < <(scenario_required_files "$scenario")
  printf 'result=ok\n' > "$d/leaf-lifetime.txt"
  printf 'result=ok\n' > "$d/credential-plan.txt"
  printf 'result=ok\n' > "$d/control-criteria.txt"
  printf 'result=ok\n' > "$d/admission-baseline.txt"
  printf 'result=ok\n' > "$d/k-remaining.txt"
  mkdir -p "$d/s-hard" "$d/recover"
  printf 'result=met\n' > "$d/s-hard/stage1-condition.txt"
  printf '$ linkerd upgrade ... | kubectl apply -f -\nsecret/linkerd-identity-issuer configured\n[exit 0]\n' > "$d/recover/linkerd-upgrade.txt"
  printf '$ bash -o pipefail -c linkerd upgrade > m.yaml\n[exit 0]\n' > "$d/recover/plain-render.txt"
  printf '$ kubectl apply -f m.yaml\nsecret/linkerd-proxy-injector-k8s-tls created\n[exit 0]\n' > "$d/recover/plain-apply.txt"
  for f in identity identity-proxy k3s-journal server-1-http server-1-echo server-1-linkerd-proxy server-1-linkerd-init; do
    echo x > "$d/logs/final/$f.txt"
  done
  for f in probe-http-1-probe probe-http-1-probe-previous probe-http-1-linkerd-proxy; do
    echo x > "$d/logs/pre-recover/$f.txt"
  done
}
```

- [ ] **Step 2: Move the control-criteria tests into `demos/cert-hygiene/lab/tests/test-control.sh`**

Create `test-control.sh` with this header:

```bash
#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-control.sh. Runs INSIDE the lab VM.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/lib-evidence.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
```

Then **move** (cut from `test-evidence.sh`, paste here unchanged) the block from the line `# ---- control_criteria_check ----` through the line `assert_fails "a certificate-lifetime warning breaks the control" control_criteria_check "$T/cc5"` (current lines 184–214). End the file with:

```bash

finish test-control
```

- [ ] **Step 3: Trim `demos/cert-hygiene/lab/tests/test-evidence.sh`**

Delete everything from the line `# ---- trust_invariant_check ----` through the line before `finish test-evidence` (current lines 65–214: the trust-invariant tests, which test retired functions, and the evaluate_validity tests, which Step 4 rewrites against the table; the control tests already moved in Step 2). `test-evidence.sh` keeps its header, the `duration_to_seconds`, `cert_not_after_epoch`/`cert_meta`, `metric_values` and `leaf_lifetime_check` tests, and `finish test-evidence`.

- [ ] **Step 4: Write the failing tests, `demos/cert-hygiene/lab/tests/test-rules.sh`**

```bash
#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-rules.sh: the rule table and evaluate_validity.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/lib-evidence.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
# shellcheck source=/dev/null
. "$TESTS/fixtures.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
V=edge-26.9.1
reason() { cat "$1/validity.txt"; }

# ---- the table itself ----
assert_eq "${#LAB_SCENARIOS[@]}" 9 "nine scenarios"
assert_fails "unknown scenario dies (rules)" scenario_rules 99-nope
assert_fails "unknown scenario dies (plan)" credential_plan_for 99-nope
assert_fails "unknown scenario dies (files)" scenario_required_files 99-nope
assert_eq "$(scenario_rules 00-baseline-control)" control-criteria "control rules"
assert_eq "$(scenario_rules 05-issuer-expiry | paste -sd' ' -)" "recovery-apply control-at-tree" "R rules"
assert_eq "$(scenario_rules 20-check-threshold)" k-remaining "K needs no control"
assert_contains "$(scenario_rules 08-anchor-rotation-hard)" s-hard-stage1 "S-hard stage-1 rule"
assert_contains "$(scenario_rules 02-webhook-expiry-fail)" webhook-baseline "W baseline rule"
assert_eq "$(credential_plan_for 07-anchor-rotation-staged | grep '^plan')" "plan A/I1 A+B/I1 A+B/I2 B/I2" "S-staged plan"
assert_eq "$(credential_plan_for 02-webhook-expiry-ignore | grep '^plan')" "plan A/I1/W1 A/I1/W2" "W: the webhook certificates change once across ticks"
assert_eq "$(credential_plan_for 02-webhook-expiry-ignore | grep '^components')" "components trust issuer webhooks" "W components"
assert_eq "$(credential_plan_for 09-identity-outage | grep '^plan')" "plan A/I1" "O: one state"
assert_contains "$(scenario_required_files 20-check-threshold)" certs/issuer-plus.pem "K requires the +10m issuer"

# ---- every scenario: a complete fixture is valid ----
make_run "$T/ctl/r1" 00-baseline-control c1 h1 false
assert_succeeds "clean control run is valid" evaluate_validity "$T/ctl/r1" 00-baseline-control "$V"
assert_eq "$(head -n1 "$T/ctl/r1/validity.txt")" evidence_valid=yes "validity.txt says yes"
for s in "${LAB_SCENARIOS[@]}"; do
  make_run "$T/all/$s" "$s" c2 h1 false
  assert_succeeds "$s: complete fixture with a control at its tree is valid" evaluate_validity "$T/all/$s" "$s" "$V" "$T/ctl"
done
make_run "$T/k" 20-check-threshold c3 h7 false
assert_succeeds "K is valid without any control" evaluate_validity "$T/k" 20-check-threshold "$V"

# ---- common rules ----
make_run "$T/r5b" 05-issuer-expiry c3 h2 false
assert_fails "R invalid when no control matches its harness tree" evaluate_validity "$T/r5b" 05-issuer-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/r5b")" "reason=no valid 00-baseline-control run" "reason names the missing control"
make_run "$T/o" 09-identity-outage c3 h2 false
assert_fails "O needs a control too" evaluate_validity "$T/o" 09-identity-outage "$V" "$T/ctl"
make_run "$T/dirty" 00-baseline-control c1 h1 true
assert_fails "dirty tree is never evidence" evaluate_validity "$T/dirty" 00-baseline-control "$V"
make_run "$T/gap" 00-baseline-control c1 h1 false
rm "$T/gap/credentials/verify.txt"
assert_fails "a tick missing its credential state is invalid" evaluate_validity "$T/gap" 00-baseline-control "$V"
assert_contains "$(reason "$T/gap")" "tick verify missing credentials/verify.txt" "reason names the gap"
make_run "$T/gap2" 00-baseline-control c1 h1 false
rm "$T/gap2/checks/verify-check-proxy.txt"
assert_fails "a tick missing a check is invalid" evaluate_validity "$T/gap2" 00-baseline-control "$V"
make_run "$T/abort" 00-baseline-control c1 h1 false
printf '2026-09-10T10:20:00Z aborted probes never became ready\n' >> "$T/abort/timeline.log"
assert_fails "an aborted run is invalid" evaluate_validity "$T/abort" 00-baseline-control "$V"
make_run "$T/ver" 00-baseline-control c1 h1 false
printf 'linkerd_cli_version=edge-26.7.2\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$T/ver/versions.txt"
assert_fails "wrong CLI version is invalid" evaluate_validity "$T/ver" 00-baseline-control "$V"
make_run "$T/img" 00-baseline-control c1 h1 false
printf 'linkerd_cli_version=edge-26.9.1\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.7.2\n' > "$T/img/versions.txt"
assert_fails "controller image at another version is invalid" evaluate_validity "$T/img" 00-baseline-control "$V"
assert_contains "$(reason "$T/img")" "reason=control plane is not $V" "reason names the control plane"
make_run "$T/nogit" 00-baseline-control c1 h1 false
rm "$T/nogit/git-state.txt"
assert_fails "missing git-state.txt is invalid" evaluate_validity "$T/nogit" 00-baseline-control "$V"
assert_contains "$(reason "$T/nogit")" "git-state.txt missing" "reason names git-state.txt"
make_run "$T/leaf" 00-baseline-control c1 h1 false
printf 'result=fail\nfail x\n' > "$T/leaf/leaf-lifetime.txt"
assert_fails "failed leaf-lifetime check is invalid" evaluate_validity "$T/leaf" 00-baseline-control "$V"
make_run "$T/plan" 05-issuer-expiry c2 h1 false
printf 'result=fail\nfail: 3 observed states match no declared plan\n' > "$T/plan/credential-plan.txt"
assert_fails "credential states off the plan are invalid" evaluate_validity "$T/plan" 05-issuer-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/plan")" "reason=credential states do not walk the declared plan" "reason names the plan"
make_run "$T/norep" 05-issuer-expiry c2 h1 false
rm "$T/norep/certs/issuer-replacement.pem"
assert_fails "R without the replacement issuer is invalid" evaluate_validity "$T/norep" 05-issuer-expiry "$V" "$T/ctl"
make_run "$T/noproxy" 00-baseline-control c1 h1 false
rm "$T/noproxy/logs/pre-recover/probe-http-1-linkerd-proxy.txt"
assert_fails "an app-container log without the pod's proxy log is invalid" evaluate_validity "$T/noproxy" 00-baseline-control "$V"
assert_contains "$(reason "$T/noproxy")" "pre-recover: probe-http-1 has a probe log but no probe-http-1-linkerd-proxy.txt" "reason names the pod and label"

# ---- per-scenario rules ----
make_run "$T/ctlbad" 00-baseline-control c1 h9 false
printf 'result=fail\nfail: probe-http has 3 fail/closed lines\n' > "$T/ctlbad/control-criteria.txt"
assert_fails "control that failed its criteria is invalid" evaluate_validity "$T/ctlbad" 00-baseline-control "$V"
assert_contains "$(reason "$T/ctlbad")" "reason=control criteria not met" "reason names the criteria"
make_run "$T/ctl2/r1" 00-baseline-control c4 h3 false
printf 'result=fail\n' > "$T/ctl2/r1/control-criteria.txt"
evaluate_validity "$T/ctl2/r1" 00-baseline-control "$V" >/dev/null 2>&1
make_run "$T/r5c" 05-issuer-expiry c5 h3 false
assert_fails "R invalid when the control at its tree is itself invalid" evaluate_validity "$T/r5c" 05-issuer-expiry "$V" "$T/ctl2"
make_run "$T/badup" 06-anchor-expiry c2 h1 false
printf '$ linkerd upgrade ... | kubectl apply -f -\nerror: unable to connect\n[exit 1]\n' > "$T/badup/recover/linkerd-upgrade.txt"
assert_fails "A whose recovery apply failed is invalid" evaluate_validity "$T/badup" 06-anchor-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/badup")" "reason=recovery apply did not succeed" "reason names the recovery apply"
make_run "$T/wb" 02-webhook-expiry-ignore c2 h1 false
printf 'result=fail\nfail: policy-invalid-baseline was not rejected by the policy validator\n' > "$T/wb/admission-baseline.txt"
assert_fails "W without a proving baseline is invalid" evaluate_validity "$T/wb" 02-webhook-expiry-ignore "$V" "$T/ctl"
assert_contains "$(reason "$T/wb")" "reason=webhook baseline did not prove every admission probe" "reason names the baseline"
make_run "$T/wr" 02-webhook-expiry-fail c2 h1 false
printf '$ bash -o pipefail -c linkerd upgrade  > m.yaml\nError: unknown command "" for "linkerd upgrade"\n[exit 1]\n' > "$T/wr/recover/plain-render.txt"
assert_fails "W whose plain upgrade did not render is invalid" evaluate_validity "$T/wr" 02-webhook-expiry-fail "$V" "$T/ctl"
assert_contains "$(reason "$T/wr")" "reason=plain linkerd upgrade render or apply did not succeed" "reason names the plain render"
make_run "$T/wa" 02-webhook-expiry-ignore c2 h1 false
printf '$ kubectl apply -f m.yaml\nerror: no objects passed to apply\n[exit 1]\n' > "$T/wa/recover/plain-apply.txt"
assert_fails "W whose plain apply failed is invalid" evaluate_validity "$T/wa" 02-webhook-expiry-ignore "$V" "$T/ctl"
make_run "$T/wm" 02-webhook-expiry-ignore c2 h1 false
: > "$T/wm/recover/plain-manifest.yaml"
assert_fails "W with an empty plain manifest is invalid" evaluate_validity "$T/wm" 02-webhook-expiry-ignore "$V" "$T/ctl"
make_run "$T/disc" 00-baseline-control c1 h1 false
printf 'discovery=yes\nshort_windows=no\n' > "$T/disc/discovery.txt"
assert_fails "a discovery run is never evidence" evaluate_validity "$T/disc" 00-baseline-control "$V"
assert_contains "$(reason "$T/disc")" "reason=discovery run: never evidence" "reason marks it as a discovery run"
make_run "$T/kb" 20-check-threshold c2 h1 false
printf 'result=fail\n' > "$T/kb/k-remaining.txt"
assert_fails "K with a measurement on the wrong side is invalid" evaluate_validity "$T/kb" 20-check-threshold "$V"
make_run "$T/sh" 08-anchor-rotation-hard c2 h1 false
printf 'result=timeout\n' > "$T/sh/s-hard/stage1-condition.txt"
assert_fails "S-hard whose stage 1 timed out is invalid" evaluate_validity "$T/sh" 08-anchor-rotation-hard "$V" "$T/ctl"
assert_contains "$(reason "$T/sh")" "reason=S-hard stage 1 did not reach its per-endpoint condition" "reason names stage 1"

# ---- credential_plan_check ----
state() { printf 'trust_roots_sha256=%s\nissuer_sha256=%s\n' "$2" "$3" > "$1"; }
make_run "$T/pc" 05-issuer-expiry c2 h1 false
state "$T/pc/credentials/baseline.txt" t1 i1
state "$T/pc/credentials/verify.txt" t1 i2
assert_succeeds "R: I1 then I2 walks R's plan" credential_plan_check "$T/pc" 05-issuer-expiry
assert_contains "$(credential_plan_check "$T/pc" 05-issuer-expiry)" "declared: plan A/I1 A/I2" "prints the declared plan"
assert_fails "the same states break the control's single-state plan" credential_plan_check "$T/pc" 00-baseline-control
rm "$T/pc/credentials/verify.txt"
assert_fails "a tick without credential state fails the check" credential_plan_check "$T/pc" 05-issuer-expiry

finish test-rules
```

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence`, `PASS: test-plan`, and failures in `test-control` (`control_criteria_check` still lives in `lib-evidence.sh`, so it may pass) and `test-rules` (`LAB_SCENARIOS`, `scenario_rules` and `scenario_required_files` are not defined yet). Exit non-zero.

- [ ] **Step 5: Write `demos/cert-hygiene/lab/lib-evidence-control.sh`**

Create the file with this header, then **move** `control_criteria_check` from `lib-evidence.sh` (its comment block and body, current lines 109–141) below it unchanged:

```bash
#!/usr/bin/env bash
# The negative control's criteria and restart-gate record parsing. Pure: no kubectl.
# Sourced by lab/lib-evidence.sh; do not execute.
```

- [ ] **Step 6: Write `demos/cert-hygiene/lab/lib-evidence-rules.sh`**

Create it with the content below. `LAB_APP_CONTAINERS` and `_missing_proxy_logs` are **moved** unchanged from `lib-evidence.sh` (current lines 158–183); Task 5 rewrites the proxy-log rule.

```bash
#!/usr/bin/env bash
# The validity rule table (design section 1.3), keyed by scenario name, and
# evaluate_validity. Pure: no kubectl. Sourced by lab/lib-evidence.sh; do not execute.
# Says nothing about hypotheses.

LAB_SCENARIOS=(00-baseline-control 05-issuer-expiry 02-webhook-expiry-ignore 02-webhook-expiry-fail
  09-identity-outage 20-check-threshold 06-anchor-expiry 07-anchor-rotation-staged 08-anchor-rotation-hard)

# scenario_rules SCENARIO: the rule ids that apply beyond the common rules and the plan.
scenario_rules() {
  case "${1:?scenario_rules: SCENARIO required}" in
    00-baseline-control) echo control-criteria ;;
    05-issuer-expiry|06-anchor-expiry) printf '%s\n' recovery-apply control-at-tree ;;
    02-webhook-expiry-ignore|02-webhook-expiry-fail) printf '%s\n' webhook-baseline w-plain-render control-at-tree ;;
    09-identity-outage|07-anchor-rotation-staged) echo control-at-tree ;;
    20-check-threshold) echo k-remaining ;;
    08-anchor-rotation-hard) printf '%s\n' s-hard-stage1 control-at-tree ;;
    *) die "scenario_rules: unknown scenario '$1'" ;;
  esac
}

_certs() { local n; for n in "$@"; do printf 'certs/%s.pem\ncerts/%s.txt\n' "$n" "$n"; done; }

# scenario_required_files SCENARIO: run-relative files that must exist, non-empty.
scenario_required_files() {
  local s="${1:?scenario_required_files: SCENARIO required}"
  scenario_rules "$s" > /dev/null
  printf '%s\n' versions.txt git-state.txt timeline.log leaf-lifetime.txt credential-plan.txt
  _certs trust-anchor issuer-initial
  case "$s" in
    00-baseline-control) echo control-criteria.txt ;;
    05-issuer-expiry) _certs issuer-replacement; echo recover/linkerd-upgrade.txt ;;
    02-webhook-expiry-*)
      _certs webhook-ca webhook-proxyInjector webhook-policyValidator webhook-profileValidator
      printf '%s\n' admission-baseline.txt recover/branch.txt recover/plain-render.txt recover/plain-apply.txt recover/plain-manifest.yaml ;;
    09-identity-outage) ;;
    20-check-threshold) _certs issuer-plus; echo k-remaining.txt ;;
    06-anchor-expiry) _certs trust-anchor-new issuer-replacement; echo recover/linkerd-upgrade.txt ;;
    07-anchor-rotation-staged) _certs trust-anchor-new trust-bundle issuer-new ;;
    08-anchor-rotation-hard) _certs trust-anchor-new issuer-new; echo s-hard/stage1-condition.txt ;;
  esac
}

# credential_plan_for SCENARIO: the declared credential plan (design section 1.3).
credential_plan_for() {
  local s="${1:?credential_plan_for: SCENARIO required}"
  scenario_rules "$s" > /dev/null
  case "$s" in
    02-webhook-expiry-*) printf 'components trust issuer webhooks\nplan A/I1/W1 A/I1/W2\n' ;;
    00-baseline-control|09-identity-outage) printf 'components trust issuer\nplan A/I1\n' ;;
    05-issuer-expiry|20-check-threshold) printf 'components trust issuer\nplan A/I1 A/I2\n' ;;
    06-anchor-expiry|08-anchor-rotation-hard) printf 'components trust issuer\nplan A/I1 B/I2\n' ;;
    07-anchor-rotation-staged) printf 'components trust issuer\nplan A/I1 A+B/I1 A+B/I2 B/I2\n' ;;
  esac
}

# credential_plan_check RUN_DIR SCENARIO: walk credentials/<tick>.txt, in timeline
# order, against the scenario's declared plan.
credential_plan_check() {
  local run="${1:?}" scenario="${2:?}" plan t files=() rc=0
  plan="$(mktemp)"
  credential_plan_for "$scenario" > "$plan"
  while read -r t; do files+=("$run/credentials/$t.txt"); done \
    < <(awk '$2 == "tick" { print $3 }' "$run/timeline.log" 2>/dev/null)
  awk '$1 == "plan" { print "declared: " $0 }' "$plan"
  if [ "${#files[@]}" -eq 0 ]; then echo "fail: no ticks in $run/timeline.log"; rc=1; fi
  for t in "${files[@]}"; do
    [ -s "$t" ] || { echo "fail: $t missing"; rc=1; }
  done
  if [ "$rc" -eq 0 ]; then credential_plan_walk "$plan" "${files[@]}" || rc=1; fi
  rm -f "$plan"
  return "$rc"
}

# (LAB_APP_CONTAINERS and _missing_proxy_logs, moved here unchanged from lib-evidence.sh)

_first_is() { [ "$(head -n 1 "$1" 2>/dev/null)" = "$2" ]; } # FILE LINE

# evaluate_validity RUN_DIR SCENARIO EXPECTED_LINKERD_VERSION [CONTROL_RUNS_DIR]:
# decide mechanically whether a run is valid evidence and write RUN_DIR/validity.txt.
evaluate_validity() {
  local run="${1:?}" scenario="${2:?}" expected="${3:?}" control_dir="${4:-}"
  local reasons=() f tick rule tree rules
  rules="$(scenario_rules "$scenario")" || die "evaluate_validity: unknown scenario '$scenario'"
  [ "$(_kv demo_repo_dirty "$run/git-state.txt")" = false ] || reasons+=("dirty harness tree, or git-state.txt missing")
  [ ! -e "$run/discovery.txt" ] || reasons+=("discovery run: never evidence")
  while read -r f; do
    [ -s "$run/$f" ] || reasons+=("missing $f")
  done < <(scenario_required_files "$scenario")
  tail -n 1 "$run/timeline.log" 2>/dev/null | grep -qE '^[^ ]+ done$' || reasons+=("timeline does not end in done")
  while read -r tick; do
    for f in "checks/$tick-check.txt" "checks/$tick-check-proxy.txt" "metrics/$tick.txt" "pods/$tick.txt" \
        "credentials/$tick.txt" "webhooks/$tick.txt" "controlplane/$tick.txt"; do
      [ -s "$run/$f" ] || reasons+=("tick $tick missing $f")
    done
  done < <(awk '$2 == "tick" { print $3 }' "$run/timeline.log" 2>/dev/null)
  while read -r f; do
    reasons+=("missing workload proxy log: $f")
  done < <(_missing_proxy_logs "$run")
  _first_is "$run/leaf-lifetime.txt" result=ok || reasons+=("effective leaf lifetime check did not pass")
  _first_is "$run/credential-plan.txt" result=ok || reasons+=("credential states do not walk the declared plan")
  [ "$(_kv linkerd_cli_version "$run/versions.txt")" = "$expected" ] || reasons+=("linkerd CLI is not $expected")
  case "$(_kv linkerd_controller_image "$run/versions.txt")" in
    *":$expected") ;;
    *) reasons+=("control plane is not $expected") ;;
  esac
  for rule in $rules; do
    case "$rule" in
      control-criteria) _first_is "$run/control-criteria.txt" result=ok || reasons+=("control criteria not met") ;;
      recovery-apply)
        [ "$(tail -n 1 "$run/recover/linkerd-upgrade.txt" 2>/dev/null)" = "[exit 0]" ] \
          || reasons+=("recovery apply did not succeed: recover/linkerd-upgrade.txt missing or not ending [exit 0]") ;;
      webhook-baseline)
        _first_is "$run/admission-baseline.txt" result=ok || reasons+=("webhook baseline did not prove every admission probe") ;;
      w-plain-render)
        if [ "$(tail -n 1 "$run/recover/plain-render.txt" 2>/dev/null)" != "[exit 0]" ] \
            || [ "$(tail -n 1 "$run/recover/plain-apply.txt" 2>/dev/null)" != "[exit 0]" ] \
            || [ ! -s "$run/recover/plain-manifest.yaml" ]; then
          reasons+=("plain linkerd upgrade render or apply did not succeed: recover/plain-render.txt or plain-apply.txt does not end [exit 0], or plain-manifest.yaml is empty")
        fi ;;
      k-remaining)
        _first_is "$run/k-remaining.txt" result=ok || reasons+=("K measurements are not on opposite sides of 60 days at check time") ;;
      s-hard-stage1)
        _first_is "$run/s-hard/stage1-condition.txt" result=met \
          || reasons+=("S-hard stage 1 did not reach its per-endpoint condition before its timeout") ;;
      control-at-tree)
        tree="$(_kv harness_tree_sha256 "$run/git-state.txt")"
        _control_passed "$control_dir" "$tree" || reasons+=("no valid 00-baseline-control run with harness tree $tree") ;;
      *) die "evaluate_validity: rule '$rule' has no check" ;;
    esac
  done
  if [ ${#reasons[@]} -eq 0 ]; then
    echo evidence_valid=yes > "$run/validity.txt"
    return 0
  fi
  { echo evidence_valid=no; printf 'reason=%s\n' "${reasons[@]}"; } > "$run/validity.txt"
  return 1
}
```

Replace the line `# (LAB_APP_CONTAINERS and _missing_proxy_logs, moved here unchanged from lib-evidence.sh)` with the moved code.

- [ ] **Step 7: Trim `demos/cert-hygiene/lab/lib-evidence.sh`**

Delete from it: `trust_summary` and `trust_invariant_check` with their comments (current lines 65–96); `control_criteria_check` with its comment (moved in Step 5); `LAB_APP_CONTAINERS`, `_missing_proxy_logs` and `evaluate_validity` with their comments (moved or rewritten in Step 6). Keep `duration_to_seconds`, `cert_not_after_epoch`, `cert_meta`, `metric_values`, `leaf_lifetime_check`, `_probe_lines`, `_kv`, `_control_passed`. Extend the sourcing block at the end (added in Task 2) so it reads:

```bash
# The rest of the evidence library, split by concern to keep each file short.
_EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-plan.sh"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-rules.sh"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-control.sh"
```

Change the header comment's "(Task 4)" to "(slice-1 plan Task 4; slice-2 plan Tasks 2–3)".

- [ ] **Step 8: Write the plan result instead of the trust invariant in `scenario-common.sh`**

In `run_scenario`, replace the two lines

```bash
  _write_result trust-invariant.txt trust_invariant_check \
    "$RUN_DIR/trust/baseline.txt" "$RUN_DIR/trust/pre-recover.txt" "$RUN_DIR/trust/verify.txt" || true
```

with

```bash
  _write_result credential-plan.txt credential_plan_check "$RUN_DIR" "$SCENARIO" || true
```

Until Task 4 adds `credentials/<tick>.txt`, a run would record `result=fail` here; no run happens before then.

- [ ] **Step 9: Run the tests and confirm they pass**

Run: `just demo cert-hygiene test`
Expected: `PASS: test-control`, `PASS: test-evidence`, `PASS: test-plan`, `PASS: test-rules`, exit 0.

- [ ] **Step 10: Line counts, syntax, shellcheck**

Run: `cd demos/cert-hygiene && wc -l lab/lib-evidence*.sh lab/tests/*.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh lab/tests/*.sh scenarios/*.sh'`
Expected: every file under 300 lines; no shellcheck findings.

- [ ] **Step 11: Commit**

No README status change.

```bash
git add demos/cert-hygiene/lab
git commit -m "cert-hygiene replace validity special cases with a tested per-scenario rule table"
git push
```
