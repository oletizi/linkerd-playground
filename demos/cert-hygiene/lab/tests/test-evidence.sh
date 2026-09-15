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
within=no
if [ "$delta" -ge -5 ] && [ "$delta" -le 5 ]; then within=yes; fi
assert_eq "$within" yes "cert_not_after_epoch is now+1d (delta ${delta}s)"
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

finish test-evidence
