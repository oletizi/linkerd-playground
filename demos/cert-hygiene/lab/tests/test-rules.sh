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
assert_eq "$(scenario_rules 00-baseline-control | paste -sd' ' -)" "control-criteria" "control rules"
assert_eq "$(scenario_rules 05-issuer-expiry | paste -sd' ' -)" "recovery-apply control-at-tree" "R rules"
assert_eq "$(scenario_rules 02-webhook-expiry-ignore | paste -sd' ' -)" "webhook-baseline w-plain-render control-at-tree" "W-ignore rules"
assert_eq "$(scenario_rules 02-webhook-expiry-fail | paste -sd' ' -)" "webhook-baseline w-plain-render control-at-tree" "W-fail rules"
assert_eq "$(scenario_rules 09-identity-outage | paste -sd' ' -)" "control-at-tree" "O rules"
assert_eq "$(scenario_rules 20-check-threshold | paste -sd' ' -)" "k-remaining" "K rules"
assert_eq "$(scenario_rules 06-anchor-expiry | paste -sd' ' -)" "recovery-apply control-at-tree" "A rules"
assert_eq "$(scenario_rules 07-anchor-rotation-staged | paste -sd' ' -)" "control-at-tree" "S-staged rules"
assert_eq "$(scenario_rules 08-anchor-rotation-hard | paste -sd' ' -)" "s-hard-stage1 control-at-tree" "S-hard rules"
assert_eq "$(credential_plan_for 07-anchor-rotation-staged | grep '^plan')" "plan A/I1 A+B/I1 A+B/I2 B/I2" "S-staged plan"
assert_eq "$(credential_plan_for 02-webhook-expiry-ignore | grep '^plan')" "plan A/I1/W1 A/I1/W2" "W: the webhook certificates change once across ticks"
assert_eq "$(credential_plan_for 02-webhook-expiry-ignore | grep '^components')" "components trust issuer webhooks" "W components"
assert_eq "$(credential_plan_for 09-identity-outage | grep '^plan')" "plan A/I1" "O: one state"
assert_eq "$(credential_plan_for 06-anchor-expiry | grep '^plan')" "plan A/I1 B/I2" "A plan"
assert_eq "$(credential_plan_for 08-anchor-rotation-hard | grep '^plan')" "plan A/I1 B/I2" "S-hard plan"
assert_eq "$(credential_plan_for 20-check-threshold | grep '^plan')" "plan A/I1 A/I2" "K plan"
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
assert_contains "$(reason "$T/noproxy")" "pre-recover: probe-http-1 has no probe-http-1-linkerd-proxy.txt" "reason names the pod and label"

# ---- the proxy-log rule follows logs/<label>/pods.txt ----
make_run "$T/nolist" 00-baseline-control c1 h1 false
rm "$T/nolist/logs/final/pods.txt"
assert_fails "a log snapshot without pods.txt is invalid" evaluate_validity "$T/nolist" 00-baseline-control "$V"
assert_contains "$(reason "$T/nolist")" "final: pods.txt missing" "reason names the snapshot"
make_run "$T/badlist" 00-baseline-control c1 h1 false
printf '[lab pod listing failed: exit 1] connection refused\n' > "$T/badlist/logs/final/pods.txt"
assert_fails "a failed pod listing is invalid" evaluate_validity "$T/badlist" 00-baseline-control "$V"
make_run "$T/empty" 00-baseline-control c1 h1 false
: > "$T/empty/logs/final/pods.txt"
assert_fails "a snapshot listing no pod is invalid (the rule is never vacuous)" evaluate_validity "$T/empty" 00-baseline-control "$V"
make_run "$T/noapp" 00-baseline-control c1 h1 false
rm "$T/noapp/logs/final/server-1-echo.txt"
assert_fails "a listed container without its log is invalid" evaluate_validity "$T/noapp" 00-baseline-control "$V"
assert_contains "$(reason "$T/noapp")" "final: server-1 has no server-1-echo.txt" "reason names the container"
make_run "$T/noproxy2" 00-baseline-control c1 h1 false
rm "$T/noproxy2/logs/final/server-1-linkerd-proxy.txt"
assert_fails "a multi-container meshed pod without its proxy log is invalid" evaluate_validity "$T/noproxy2" 00-baseline-control "$V"
assert_contains "$(reason "$T/noproxy2")" "final: server-1 has no server-1-linkerd-proxy.txt" "reason names the pod and proxy container"
make_run "$T/uninjected" 02-webhook-expiry-ignore c2 h1 false
printf 'pod=inject-probe-post-3 proxy=no containers=idle\n' >> "$T/uninjected/logs/final/pods.txt"
echo x > "$T/uninjected/logs/final/inject-probe-post-3-idle.txt"
assert_succeeds "an un-injected pod needs no proxy log" evaluate_validity "$T/uninjected" 02-webhook-expiry-ignore "$V" "$T/ctl"

# ---- per-scenario rules ----
make_run "$T/ctlbad" 00-baseline-control c1 h9 false
printf 'result=fail\nfail: probe-http has 3 fail/closed lines\n' > "$T/ctlbad/control-criteria.txt"
assert_fails "control that failed its criteria is invalid" evaluate_validity "$T/ctlbad" 00-baseline-control "$V"
assert_contains "$(reason "$T/ctlbad")" "reason=control criteria not met" "reason names the criteria"
make_run "$T/ctl2/r1" 00-baseline-control c4 h3 false
printf 'result=fail\n' > "$T/ctl2/r1/control-criteria.txt"
evaluate_validity "$T/ctl2/r1" 00-baseline-control "$V" >/dev/null 2>&1
assert_eq "$(head -n1 "$T/ctl2/r1/validity.txt")" evidence_valid=no "fixture: the h3 control is invalid"
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
# w-plain-render's own manifest clause (-s recover/plain-manifest.yaml) is fully
# redundant with the required-files check on the same path, so this proves the
# required-files reason instead of the rule's reason text.
assert_contains "$(reason "$T/wm")" "reason=missing recover/plain-manifest.yaml" "reason names the missing manifest via required files"
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
