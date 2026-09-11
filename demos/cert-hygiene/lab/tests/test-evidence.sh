#!/usr/bin/env bash
# Unit tests for lab/lib-evidence.sh. Runs INSIDE the lab VM (GNU date, openssl).
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

# ---- duration_to_seconds ----
assert_eq "$(duration_to_seconds 15m)" 900 "15m"
assert_eq "$(duration_to_seconds 720h)" 2592000 "720h"
assert_eq "$(duration_to_seconds 90s)" 90 "90s"
assert_eq "$(duration_to_seconds 1h30m5s)" 5405 "1h30m5s"
assert_fails "rejects unknown unit" duration_to_seconds 15x
assert_fails "rejects empty" duration_to_seconds ""
assert_fails "rejects out-of-order units" duration_to_seconds 5m1h

# ---- cert_not_after_epoch / cert_meta ----
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 1 -subj /CN=unit-test >/dev/null 2>&1
now="$(date -u +%s)"
got="$(cert_not_after_epoch "$T/c.pem")"
delta=$(( got - now - 86400 ))
[ "$delta" -ge -5 ] && [ "$delta" -le 5 ]
assert_eq "$?" 0 "cert_not_after_epoch is now+1d (delta ${delta}s)"
meta="$(cert_meta < "$T/c.pem")"
assert_contains "$meta" "notAfter=" "cert_meta prints notAfter"
assert_contains "$meta" "serial=" "cert_meta prints serial"
assert_contains "$meta" "Fingerprint=" "cert_meta prints the fingerprint"
assert_contains "$meta" "CN=unit-test" "cert_meta prints the subject"
assert_fails "cert_meta rejects non-PEM input" bash -c ". '$ROOT/lib/common.sh'; . '$DEMO/lab/lib-evidence.sh'; echo nope | cert_meta"

# ---- metric_values ----
cat > "$T/m1.txt" <<'EOF'
identity_cert_expiration_timestamp_seconds 1800000300
identity_cert_refreshes_total 4
EOF
cat > "$T/m2.txt" <<'EOF'
identity_cert_expiration_timestamp_seconds{pod="a"} 1.8000002e9
identity_cert_expiration_timestamp_seconds_other 7
EOF
assert_eq "$(metric_values identity_cert_expiration_timestamp_seconds "$T/m1.txt")" 1800000300 "unlabelled sample"
assert_eq "$(metric_values identity_cert_expiration_timestamp_seconds "$T/m2.txt")" 1.8000002e9 "labelled sample; no prefix match"

# ---- leaf_lifetime_check ----
M=identity_cert_expiration_timestamp_seconds
assert_succeeds "within bound" leaf_lifetime_check "$M" 1800000000 320 "$T/m1.txt" "$T/m2.txt"
assert_fails "beyond bound" leaf_lifetime_check "$M" 1800000000 100 "$T/m1.txt"
assert_fails "already expired" leaf_lifetime_check "$M" 1800000400 320 "$T/m1.txt"
printf 'unrelated_metric 1\n' > "$T/m3.txt"
assert_fails "metric absent" leaf_lifetime_check "$M" 1800000000 320 "$T/m3.txt"
out="$(leaf_lifetime_check "$M" 1800000000 100 "$T/m1.txt")"
assert_contains "$out" "fail" "failure is reported, not just returned"

# ---- trust_invariant_check ----
printf 'configmap_sha256=aaa\nlab/server-1 h1\nkube-system/coredns -\n' > "$T/t1.txt"
printf 'configmap_sha256=aaa\nlab/server-1 h1\nlab/probe-new-9 h1\n' > "$T/t2.txt"
printf 'configmap_sha256=bbb\nlab/server-1 h1\n' > "$T/t3.txt"
printf 'configmap_sha256=aaa\nlab/server-1 h1\nlab/probe-new-9 h2\n' > "$T/t4.txt"
assert_succeeds "same bundle, pods added" trust_invariant_check "$T/t1.txt" "$T/t2.txt"
assert_fails "configmap hash changed" trust_invariant_check "$T/t1.txt" "$T/t3.txt"
assert_fails "a pod carries a second bundle" trust_invariant_check "$T/t1.txt" "$T/t4.txt"

# ---- evaluate_validity ----
make_run() { # dir scenario commit harness dirty
  local d="$1"
  mkdir -p "$d/certs" "$d/checks" "$d/metrics" "$d/pods"
  printf 'demo_repo_commit=%s\ndemo_repo_dirty=%s\nharness_tree_sha256=%s\n' "$3" "$5" "$4" > "$d/git-state.txt"
  printf 'linkerd_cli_version=edge-26.9.1\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$d/versions.txt"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n2026-09-10T10:40:00Z tick verify\n2026-09-10T10:41:00Z done\n' > "$d/timeline.log"
  local t f
  for t in baseline verify; do
    for f in "checks/$t-check.txt" "checks/$t-check-proxy.txt" "metrics/$t.txt" "pods/$t.txt"; do echo x > "$d/$f"; done
  done
  for f in trust-anchor issuer-initial issuer-replacement; do echo x > "$d/certs/$f.pem"; echo x > "$d/certs/$f.txt"; done
  printf 'result=ok\n' > "$d/leaf-lifetime.txt"
  printf 'result=ok\n' > "$d/trust-invariant.txt"
  printf 'result=ok\n' > "$d/control-criteria.txt"
}
V=edge-26.9.1
make_run "$T/ctl/r1" 00-baseline-control c1 h1 false
assert_succeeds "clean control run is valid" evaluate_validity "$T/ctl/r1" 00-baseline-control "$V"
assert_eq "$(head -n1 "$T/ctl/r1/validity.txt")" evidence_valid=yes "validity.txt says yes"

make_run "$T/r5" 05-issuer-expiry c2 h1 false
assert_succeeds "#5 valid with a valid control at the same harness tree" evaluate_validity "$T/r5" 05-issuer-expiry "$V" "$T/ctl"

make_run "$T/r5b" 05-issuer-expiry c3 h2 false
assert_fails "#5 invalid when no control matches its harness tree" evaluate_validity "$T/r5b" 05-issuer-expiry "$V" "$T/ctl"
assert_contains "$(cat "$T/r5b/validity.txt")" "reason=no valid 00-baseline-control run" "reason names the missing control"

make_run "$T/dirty" 00-baseline-control c1 h1 true
assert_fails "dirty tree is never evidence" evaluate_validity "$T/dirty" 00-baseline-control "$V"

make_run "$T/gap" 00-baseline-control c1 h1 false
rm "$T/gap/checks/verify-check-proxy.txt"
assert_fails "a tick missing a check is invalid" evaluate_validity "$T/gap" 00-baseline-control "$V"
assert_contains "$(cat "$T/gap/validity.txt")" "tick verify missing checks/verify-check-proxy.txt" "reason names the gap"

make_run "$T/abort" 00-baseline-control c1 h1 false
printf '2026-09-10T10:20:00Z aborted probes never became ready\n' >> "$T/abort/timeline.log"
assert_fails "an aborted run is invalid" evaluate_validity "$T/abort" 00-baseline-control "$V"

make_run "$T/ver" 00-baseline-control c1 h1 false
printf 'linkerd_cli_version=edge-26.7.2\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$T/ver/versions.txt"
assert_fails "wrong CLI version is invalid" evaluate_validity "$T/ver" 00-baseline-control "$V"

make_run "$T/leaf" 00-baseline-control c1 h1 false
printf 'result=fail\nfail x\n' > "$T/leaf/leaf-lifetime.txt"
assert_fails "failed leaf-lifetime check is invalid" evaluate_validity "$T/leaf" 00-baseline-control "$V"

make_run "$T/trust" 05-issuer-expiry c2 h1 false
printf 'result=fail\n' > "$T/trust/trust-invariant.txt"
assert_fails "broken trust invariant is invalid" evaluate_validity "$T/trust" 05-issuer-expiry "$V" "$T/ctl"

make_run "$T/norep" 05-issuer-expiry c2 h1 false
rm "$T/norep/certs/issuer-replacement.pem"
assert_fails "#5 without the replacement issuer is invalid" evaluate_validity "$T/norep" 05-issuer-expiry "$V" "$T/ctl"

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

finish test-evidence
