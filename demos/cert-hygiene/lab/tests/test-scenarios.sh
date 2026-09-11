#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-scenarios.sh: K's and S-hard's pure rules. W's rules and
# helpers are tested in test-webhook.sh.
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

finish test-scenarios
