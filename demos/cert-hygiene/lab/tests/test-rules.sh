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
assert_eq "${#LAB_SCENARIOS[@]}" 13 "thirteen scenarios"
assert_fails "unknown scenario dies (rules)" scenario_rules 99-nope
assert_fails "unknown scenario dies (plan)" credential_plan_for 99-nope
assert_fails "unknown scenario dies (files)" scenario_required_files 99-nope
assert_eq "$(scenario_rules 00-baseline-control | paste -sd' ' -)" "control-criteria" "control rules"
assert_eq "$(scenario_rules 05-issuer-expiry | paste -sd' ' -)" "recovery-apply control-at-tree" "R rules"
assert_eq "$(scenario_rules 02-webhook-expiry-ignore | paste -sd' ' -)" "webhook-baseline w-reconnect w-plain-render control-at-tree" "W-ignore rules"
assert_eq "$(scenario_rules 02-webhook-expiry-fail | paste -sd' ' -)" "webhook-baseline w-reconnect w-plain-render control-at-tree" "W-fail rules"
assert_eq "$(scenario_rules 09-identity-outage | paste -sd' ' -)" "control-at-tree" "O rules"
assert_eq "$(scenario_rules 20-check-threshold | paste -sd' ' -)" "k-remaining" "K rules"
assert_eq "$(scenario_rules 06-anchor-expiry | paste -sd' ' -)" "recovery-apply control-at-tree" "A rules"
assert_eq "$(scenario_rules 07-anchor-rotation-staged | paste -sd' ' -)" "control-at-tree" "S-staged rules"
assert_eq "$(scenario_rules 08-anchor-rotation-hard | paste -sd' ' -)" "s-hard-stage1 control-at-tree" "S-hard rules"
assert_eq "$(scenario_rules 30-tap-expiry | paste -sd' ' -)" "v-baseline v-reconnect control-at-tree" "V rules"
assert_eq "$(scenario_rules 40-webhook-unavailable-ignore | paste -sd' ' -)" "n-baseline n-restored control-at-tree" "N-ignore rules"
assert_eq "$(scenario_rules 40-webhook-unavailable-fail | paste -sd' ' -)" "n-baseline n-restored control-at-tree" "N-fail rules"
assert_eq "$(scenario_rules 41-webhook-algorithm | paste -sd' ' -)" "g-baseline g-timevalid control-at-tree" "G rules"
assert_eq "$(credential_plan_for 07-anchor-rotation-staged | grep '^plan')" "plan A/I1 A+B/I1 A+B/I2 B/I2" "S-staged plan"
assert_eq "$(credential_plan_for 02-webhook-expiry-ignore | grep '^plan')" "plan A/I1/W1 A/I1/W2" "W: the webhook certificates change once across ticks"
assert_eq "$(credential_plan_for 02-webhook-expiry-ignore | grep '^components')" "components trust issuer webhooks" "W components"
assert_eq "$(credential_plan_for 09-identity-outage | grep '^plan')" "plan A/I1" "O: one state"
assert_eq "$(credential_plan_for 06-anchor-expiry | grep '^plan')" "plan A/I1 B/I2" "A plan"
assert_eq "$(credential_plan_for 08-anchor-rotation-hard | grep '^plan')" "plan A/I1 B/I2" "S-hard plan"
assert_eq "$(credential_plan_for 20-check-threshold | grep '^plan')" "plan A/I1 A/I2" "K plan"
assert_eq "$(credential_plan_for 30-tap-expiry | grep '^plan')" "plan A/I1" "V: one state; the tap cert is not part of the credential plan"
assert_eq "$(credential_plan_for 40-webhook-unavailable-ignore | grep '^plan')" "plan A/I1/W1" "N: one state; nothing rotates"
assert_eq "$(credential_plan_for 40-webhook-unavailable-ignore | grep '^components')" "components trust issuer webhooks" "N components"
assert_eq "$(credential_plan_for 41-webhook-algorithm | grep '^plan')" "plan A/I1/W1 A/I1/W2 A/I1/W1" "G: baseline, swapped, restored -- three states, back where it started"
assert_eq "$(credential_plan_for 41-webhook-algorithm | grep '^components')" "components trust issuer webhooks" "G components"
assert_contains "$(scenario_required_files 20-check-threshold)" certs/issuer-plus.pem "K requires the +10m issuer"
assert_contains "$(scenario_required_files 30-tap-expiry)" tap-baseline.txt "V requires tap-baseline.txt"
for f in backing restart rollout; do
  assert_contains "$(scenario_required_files 30-tap-expiry)" "reconnect/$f.txt" "V requires reconnect/$f.txt"
done
assert_contains "$(scenario_required_files 40-webhook-unavailable-ignore)" admission-restored.txt "N requires admission-restored.txt"
for f in backing scale-down rollout-down pods-gone scale-up rollout-up; do
  assert_contains "$(scenario_required_files 40-webhook-unavailable-fail)" "scale/$f.txt" "N requires scale/$f.txt"
done
assert_contains "$(scenario_required_files 41-webhook-algorithm)" certs/webhook-profileValidator-algorithm.pem "G requires the algorithm-refused candidate cert"
assert_contains "$(scenario_required_files 41-webhook-algorithm)" admission-restored.txt "G requires admission-restored.txt"
for f in backing patch-fault restart-fault rollout-fault pods-gone-fault patch-restore restart-restore rollout-restore pods-gone-restore; do
  assert_contains "$(scenario_required_files 41-webhook-algorithm)" "swap/$f.txt" "G requires swap/$f.txt"
done

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
# w-reconnect: the forced-reconnect restart and its rollouts succeeded (design section 3)
assert_eq "$(cat "$T/all/02-webhook-expiry-fail/validity.txt")" evidence_valid=yes "W: a complete reconnect record satisfies w-reconnect"
for f in backing restart rollout; do
  assert_contains "$(scenario_required_files 02-webhook-expiry-ignore)" "reconnect/$f.txt" "W requires reconnect/$f.txt"
done
make_run "$T/wk1" 02-webhook-expiry-fail c2 h1 false
printf 'component=%s service=%s deployment=%s\n' proxyInjector linkerd-proxy-injector linkerd-proxy-injector \
  policyValidator linkerd-policy-validator linkerd-destination \
  profileValidator linkerd-sp-validator '- error=[Service linkerd-sp-validator read failed: exit 1] refused' > "$T/wk1/reconnect/backing.txt"
assert_fails "W without a backing Deployment for one webhook is invalid" evaluate_validity "$T/wk1" 02-webhook-expiry-fail "$V" "$T/ctl"
assert_contains "$(reason "$T/wk1")" "reason=forced reconnect: reconnect/backing.txt names no Deployment for profileValidator" "reason names the webhook"
make_run "$T/wk2" 02-webhook-expiry-ignore c2 h1 false
printf '$ kubectl -n linkerd rollout restart deploy/linkerd-destination\nerror: connection refused\n[exit 1]\n' > "$T/wk2/reconnect/restart.txt"
assert_fails "W whose reconnect restart failed is invalid" evaluate_validity "$T/wk2" 02-webhook-expiry-ignore "$V" "$T/ctl"
assert_contains "$(reason "$T/wk2")" "reason=forced reconnect: reconnect/restart.txt does not end [exit 0]" "reason names the restart"
make_run "$T/wk3" 02-webhook-expiry-fail c2 h1 false
printf '$ bash -c ... capture_rollouts linkerd-destination\nerror: timed out waiting for the condition\n[exit 1]\n' > "$T/wk3/reconnect/rollout.txt"
assert_fails "W whose reconnect rollout failed is invalid" evaluate_validity "$T/wk3" 02-webhook-expiry-fail "$V" "$T/ctl"
assert_contains "$(reason "$T/wk3")" "reason=forced reconnect: reconnect/rollout.txt does not end [exit 0]" "reason names the rollout"
make_run "$T/nb" 40-webhook-unavailable-ignore c2 h1 false
printf 'result=fail\nfail: policy-invalid-baseline was not rejected by the policy validator\n' > "$T/nb/admission-baseline.txt"
assert_fails "N without a proving baseline is invalid" evaluate_validity "$T/nb" 40-webhook-unavailable-ignore "$V" "$T/ctl"
assert_contains "$(reason "$T/nb")" "reason=N: the healthy baseline did not prove every admission probe" "reason names the baseline"
make_run "$T/nr" 40-webhook-unavailable-fail c2 h1 false
printf 'result=fail\nfail: inject-probe-verify was not created with a linkerd-proxy container\n' > "$T/nr/admission-restored.txt"
assert_fails "N without a proving restore is invalid" evaluate_validity "$T/nr" 40-webhook-unavailable-fail "$V" "$T/ctl"
assert_contains "$(reason "$T/nr")" "reason=N: admission did not work again after the replicas were restored" "reason names the restore"
# n-restored also checks that the fault/recovery commands themselves succeeded (a
# control's entire content is "the fault happened"): a probe passing on both sides of a
# scale command that actually failed would still be evidence_valid=yes without this.
make_run "$T/npg" 40-webhook-unavailable-ignore c2 h1 false
printf '$ bash -c ... pods-gone linkerd component=proxy-injector\nerror: timed out waiting for the condition\n[exit 1]\n' > "$T/npg/scale/pods-gone.txt"
assert_fails "N whose pods-gone wait timed out is invalid" evaluate_validity "$T/npg" 40-webhook-unavailable-ignore "$V" "$T/ctl"
assert_contains "$(reason "$T/npg")" "reason=N fault/recovery: scale/pods-gone.txt does not end [exit 0]" "reason names pods-gone.txt"
make_run "$T/nsd" 40-webhook-unavailable-fail c2 h1 false
printf '$ kubectl -n linkerd scale deploy/linkerd-proxy-injector --replicas=0\nerror: connection refused\n[exit 1]\n' > "$T/nsd/scale/scale-down.txt"
assert_fails "N whose scale-down failed is invalid even with both probes ok" evaluate_validity "$T/nsd" 40-webhook-unavailable-fail "$V" "$T/ctl"
assert_contains "$(reason "$T/nsd")" "reason=N fault/recovery: scale/scale-down.txt does not end [exit 0]" "reason names scale-down.txt"
# g-baseline
make_run "$T/gb" 41-webhook-algorithm c2 h1 false
printf 'result=fail\nfail: serviceprofile-invalid-baseline was not denied by the sp-validator\n' > "$T/gb/admission-baseline.txt"
assert_fails "G without a proving baseline is invalid" evaluate_validity "$T/gb" 41-webhook-algorithm "$V" "$T/ctl"
assert_contains "$(reason "$T/gb")" "reason=G: the healthy baseline did not prove every admission probe" "reason names the baseline"
# g-timevalid: the rule this task exists to prove has teeth. A missing per-tick record,
# an unreadable certificate, a swap command that never ran, and -- the one the rule is
# actually FOR -- a certificate that had already expired at a recorded tick, constructed
# here rather than assumed to fail.
make_run "$T/gtm" 41-webhook-algorithm c2 h1 false
rm "$T/gtm/timevalidity/verify.txt"
assert_fails "G missing a tick's timevalidity record is invalid" evaluate_validity "$T/gtm" 41-webhook-algorithm "$V" "$T/ctl"
assert_contains "$(reason "$T/gtm")" "reason=G: timevalidity/verify.txt missing" "reason names the missing tick"
make_run "$T/gtu" 41-webhook-algorithm c2 h1 false
printf 'observed_epoch=100\nobserved_utc=2026-01-01T00:00:00Z\n[profileValidator certificate unreadable]\n' > "$T/gtu/timevalidity/baseline.txt"
assert_fails "G with an unreadable certificate at a tick is invalid" evaluate_validity "$T/gtu" 41-webhook-algorithm "$V" "$T/ctl"
assert_contains "$(reason "$T/gtu")" "reason=G: timevalidity/baseline.txt: certificate unreadable at tick baseline" "reason names the tick"
make_run "$T/gtx" 41-webhook-algorithm c2 h1 false
printf '$ kubectl -n linkerd patch secret linkerd-sp-validator-k8s-tls --type merge --patch-file p.json\nerror: connection refused\n[exit 1]\n' > "$T/gtx/swap/patch-fault.txt"
assert_fails "G whose certificate-swap patch failed is invalid even with a clean timevalidity record" evaluate_validity "$T/gtx" 41-webhook-algorithm "$V" "$T/ctl"
assert_contains "$(reason "$T/gtx")" "reason=G cert swap: swap/patch-fault.txt does not end [exit 0]" "reason names the failed patch"
# The certificate expiring mid-run: constructed, not assumed. A run whose refused
# certificate had already expired by its verify tick cannot be told apart from an expiry
# run -- design section 4's own statement of why this rule exists.
make_run "$T/gexp" 41-webhook-algorithm c2 h1 false
printf 'observed_epoch=2000\nobserved_utc=2026-01-01T00:33:20Z\nnotAfter=Jan  1 00:16:40 2026 GMT\nnotAfter_epoch=1000\nseconds_until_notAfter=-1000\nsignature_algorithm=sha1WithRSAEncryption\nopenssl_x509_checkend_0_exit=1\n' \
  > "$T/gexp/timevalidity/verify.txt"
assert_fails "G whose certificate expired mid-run is invalid (constructed fixture, not assumed)" evaluate_validity "$T/gexp" 41-webhook-algorithm "$V" "$T/ctl"
assert_contains "$(reason "$T/gexp")" "reason=G: timevalidity/verify.txt: certificate not time-valid at tick verify (seconds_until_notAfter=-1000)" "reason names the tick and the negative remaining validity"
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
# v-baseline: a run where tap never worked while its certificate was valid is not
# evidence about tap breaking, whether tap-baseline.txt says so or is simply missing.
make_run "$T/vfail" 30-tap-expiry c2 h1 false
printf 'result=fail\nfail: no tap events observed before expiry\n' > "$T/vfail/tap-baseline.txt"
assert_fails "V without a proven tap baseline is invalid" evaluate_validity "$T/vfail" 30-tap-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/vfail")" "reason=tap was never proved working while its certificate was valid" "reason names the tap baseline"
make_run "$T/vmiss" 30-tap-expiry c2 h1 false
rm "$T/vmiss/tap-baseline.txt"
assert_fails "V without tap-baseline.txt at all is invalid" evaluate_validity "$T/vmiss" 30-tap-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/vmiss")" "reason=missing tap-baseline.txt" "reason names the missing file"
# v-reconnect: the forced-reconnect restart and its rollout succeeded (design section 8,
# Task 3b), the same shape as W's own w-reconnect but for tap's one component.
make_run "$T/vk1" 30-tap-expiry c2 h1 false
printf 'component=tap service=tap deployment=- error=[Service tap read failed: exit 1] refused\n' > "$T/vk1/reconnect/backing.txt"
assert_fails "V without a backing Deployment is invalid" evaluate_validity "$T/vk1" 30-tap-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/vk1")" "reason=forced reconnect: reconnect/backing.txt names no Deployment" "reason names the missing deployment"
make_run "$T/vk2" 30-tap-expiry c2 h1 false
printf '$ kubectl -n linkerd-viz rollout restart deploy/tap\nerror: connection refused\n[exit 1]\n' > "$T/vk2/reconnect/restart.txt"
assert_fails "V whose reconnect restart failed is invalid" evaluate_validity "$T/vk2" 30-tap-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/vk2")" "reason=forced reconnect: reconnect/restart.txt does not end [exit 0]" "reason names the restart"
make_run "$T/vk3" 30-tap-expiry c2 h1 false
printf '$ bash -c ... capture_rollouts linkerd-viz tap\nerror: timed out waiting for the condition\n[exit 1]\n' > "$T/vk3/reconnect/rollout.txt"
assert_fails "V whose reconnect rollout failed is invalid" evaluate_validity "$T/vk3" 30-tap-expiry "$V" "$T/ctl"
assert_contains "$(reason "$T/vk3")" "reason=forced reconnect: reconnect/rollout.txt does not end [exit 0]" "reason names the rollout"

# ---- control-at-tree: a committed manifest satisfies it exactly like an on-disk run ----
# This is the case that broke slice 3's task 5: the control was published and its local
# run directory removed, exactly as the publish workflow says to, and the next run's
# control-at-tree check failed even though the control itself was fine.
mkdir -p "$T/ctlmf"
manifest() { # DIR TS EVIDENCE_VALID TREE
  printf 'run=runs/00-baseline-control/%s\nfiles=3\nuploaded_utc=2026-09-14T08:08:34Z\nvalidity_evidence_valid=%s\nharness_tree_sha256=%s\narchive=runs/00-baseline-control/%s.tar.gz\n---\n' \
    "$2" "$3" "$4" "$2" > "$1/$2.manifest.txt"
}
manifest "$T/ctlmf" 20260914T071125Z yes h1
assert_eq "$(ls "$T/ctlmf")" 20260914T071125Z.manifest.txt "fixture: a manifest with no run directory beside it"
make_run "$T/mfr" 05-issuer-expiry c9 h1 false
assert_succeeds "R: a manifest-only control (no run directory on disk) satisfies control-at-tree" \
  evaluate_validity "$T/mfr" 05-issuer-expiry "$V" "$T/ctlmf"
make_run "$T/mfo" 09-identity-outage c9 h1 false
assert_succeeds "O: the same manifest-only control satisfies control-at-tree" \
  evaluate_validity "$T/mfo" 09-identity-outage "$V" "$T/ctlmf"
make_run "$T/mfwrong" 05-issuer-expiry c9 h9 false
assert_fails "R: a manifest control at a different harness tree does not satisfy control-at-tree" \
  evaluate_validity "$T/mfwrong" 05-issuer-expiry "$V" "$T/ctlmf"
mkdir -p "$T/ctlmfbad"
manifest "$T/ctlmfbad" 20260914T080000Z no h1
make_run "$T/mfbad" 05-issuer-expiry c9 h1 false
assert_fails "R: a manifest recording evidence_valid=no does not satisfy control-at-tree" \
  evaluate_validity "$T/mfbad" 05-issuer-expiry "$V" "$T/ctlmfbad"
# Both sources are checked: an on-disk run and an unrelated manifest, side by side, in a
# directory whose manifest alone would not satisfy the tree -- the on-disk run still does.
mkdir -p "$T/ctlboth"
manifest "$T/ctlboth" 20260914T090000Z yes h-other
make_run "$T/ctlboth/r1" 00-baseline-control c1 h1 false
assert_succeeds "control run fixture at h1 in a mixed control dir is valid" \
  evaluate_validity "$T/ctlboth/r1" 00-baseline-control "$V"
make_run "$T/mfboth" 05-issuer-expiry c9 h1 false
assert_succeeds "R: an on-disk control still satisfies control-at-tree beside an unrelated manifest" \
  evaluate_validity "$T/mfboth" 05-issuer-expiry "$V" "$T/ctlboth"

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
# W: the reconnect ticks come before recovery and change no credential, so W1 -> W2 holds.
wst() { printf 'trust_roots_sha256=t1\nissuer_sha256=i1\nwebhooks_sha256=%s\n' "$2" > "$1"; } # FILE WEBHOOKS
make_run "$T/wpc" 02-webhook-expiry-ignore c2 h1 false
printf '2026-09-10T10:0%s:00Z %s\n' 1 'tick baseline' 2 'tick post-1' 3 'tick reconnect-1' 4 'tick reconnect-2' \
  5 reconnect-end 6 recover-delete 7 'tick verify' 8 'done' > "$T/wpc/timeline.log"
for t in baseline post-1 reconnect-1 reconnect-2; do wst "$T/wpc/credentials/$t.txt" w1; done
wst "$T/wpc/credentials/verify.txt" w2
assert_succeeds "W: reconnect ticks keep the supplied webhook certificates; the plan walks W1 -> W2" credential_plan_check "$T/wpc" 02-webhook-expiry-ignore
wst "$T/wpc/credentials/reconnect-2.txt" w9
assert_fails "W: a webhook credential change during reconnect breaks the plan" credential_plan_check "$T/wpc" 02-webhook-expiry-ignore

# G: baseline (W1) -> swapped (W2) -> restored (back to W1) -- three states, the last
# equal to the first, distinguishing it from W's one-directional plan above.
make_run "$T/gpc" 41-webhook-algorithm c2 h1 false
printf '2026-09-10T10:00:00Z tick baseline\n2026-09-10T10:05:00Z tick fault-0001\n2026-09-10T10:10:00Z tick verify\n2026-09-10T10:11:00Z done\n' > "$T/gpc/timeline.log"
wst "$T/gpc/credentials/baseline.txt" w1
wst "$T/gpc/credentials/fault-0001.txt" w2
wst "$T/gpc/credentials/verify.txt" w1
assert_succeeds "G: baseline, swap, restore walks the declared plan" credential_plan_check "$T/gpc" 41-webhook-algorithm
assert_contains "$(credential_plan_check "$T/gpc" 41-webhook-algorithm)" "declared: plan A/I1/W1 A/I1/W2 A/I1/W1" "prints the declared plan"
wst "$T/gpc/credentials/verify.txt" w9
assert_fails "G: a restore that lands on a third, different webhook state breaks the plan" credential_plan_check "$T/gpc" 41-webhook-algorithm

finish test-rules
