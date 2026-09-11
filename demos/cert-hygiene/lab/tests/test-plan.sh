#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-plan.sh. Runs INSIDE the lab VM (GNU date, openssl).
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

# ---- cert_facts ----
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/k.pem" -out "$T/san.pem" \
  -days 1 -subj /CN=svc.example -addext "subjectAltName=DNS:a.example,DNS:b.example" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/k2.pem" -out "$T/nosan.pem" \
  -days 1 -subj /CN=nosan.example >/dev/null 2>&1
facts="$(cert_facts w < "$T/san.pem")"
der="$(openssl x509 -outform DER -in "$T/san.pem" | sha256sum | cut -d' ' -f1)"
assert_contains "$facts" "w_sha256=$der" "fingerprint is the DER SHA-256, lowercase, no colons"
assert_contains "$facts" "w_serial=$(openssl x509 -noout -serial -in "$T/san.pem" | cut -d= -f2)" "serial"
assert_contains "$facts" "w_not_after_epoch=$(cert_not_after_epoch "$T/san.pem")" "notAfter as epoch"
assert_contains "$facts" "w_not_after=$(openssl x509 -noout -enddate -in "$T/san.pem" | cut -d= -f2)" "notAfter as text, the value openssl prints"
assert_contains "$facts" "w_sans=DNS:a.example,DNS:b.example" "SANs, comma-joined"
assert_contains "$(cert_facts n < "$T/nosan.pem")" "n_sans=-" "no SAN extension is recorded as -"
assert_fails "cert_facts rejects non-PEM input" bash -c ". '$ROOT/lib/common.sh'; . '$DEMO/lab/lib-evidence.sh'; echo nope | cert_facts x"

# ---- credential_state_key ----
st() { # FILE TRUST ISSUER [WEBHOOKS]: a credential-state file
  printf 'sampled_at_epoch=1\ntrust_roots_sha256=%s\nissuer_sha256=%s\nissuer_serial=01\n' "$2" "$3" > "$1"
  if [ -n "${4:-}" ]; then printf 'webhooks_sha256=%s\n' "$4" >> "$1"; fi
}
st "$T/s1.txt" t1 i1 w1
assert_eq "$(credential_state_key "$T/s1.txt" trust issuer)" "trust=t1 issuer=i1" "trust and issuer key"
assert_eq "$(credential_state_key "$T/s1.txt" trust issuer webhooks)" "trust=t1 issuer=i1 webhooks=w1" "with webhooks"
st "$T/s2.txt" t1 i1
assert_fails "missing webhooks key dies" credential_state_key "$T/s2.txt" trust issuer webhooks
printf '[issuer Secret crt.pem read failed: exit 1] refused\n' >> "$T/s2.txt"
assert_fails "a recorded failed read dies" credential_state_key "$T/s2.txt" trust issuer
assert_fails "unknown component dies" credential_state_key "$T/s1.txt" anchors

# ---- credential_plan_walk ----
plan() { # FILE COMPONENTS-LINE PLAN-LINE...
  local f="$1" c="$2"
  shift 2
  printf 'components %s\n' "$c" > "$f"
  printf 'plan %s\n' "$@" >> "$f"
}
seq_files() { # DIR SPEC...: one state file per SPEC "trust,issuer[,webhooks]"; prints paths
  local d="$1" n=0 s t i w
  shift
  mkdir -p "$d"
  for s in "$@"; do
    n=$((n + 1)); IFS=, read -r t i w <<< "$s"
    st "$d/$n.txt" "$t" "$i" "$w"
    echo "$d/$n.txt"
  done
}
plan "$T/r.plan" "trust issuer" "A/I1 A/I2"
mapfile -t f < <(seq_files "$T/r-ok" t1,i1 t1,i1 t1,i2 t1,i2)
assert_succeeds "R: one issuer change, repeats collapsed" credential_plan_walk "$T/r.plan" "${f[@]}"
out="$(credential_plan_walk "$T/r.plan" "${f[@]}")"
assert_contains "$out" "observed 2: trust=t1 issuer=i2" "prints the collapsed sequence"
assert_contains "$out" "ok: 2 observed states walk the declared plan: A/I1 A/I2" "names the matched plan"
mapfile -t f < <(seq_files "$T/r-skip" t1,i1 t1,i1)
assert_fails "R: a skipped state fails" credential_plan_walk "$T/r.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/r-extra" t1,i1 t1,i2 t1,i3)
assert_fails "R: an undeclared third issuer fails" credential_plan_walk "$T/r.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/r-anchor" t1,i1 t2,i2)
assert_fails "R: a trust change fails (slice-1 anchor invariant)" credential_plan_walk "$T/r.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/r-back" t1,i1 t1,i2 t1,i1)
assert_fails "R: returning to the first issuer fails" credential_plan_walk "$T/r.plan" "${f[@]}"

plan "$T/one.plan" "trust issuer" "A/I1"
mapfile -t f < <(seq_files "$T/one-ok" t1,i1 t1,i1 t1,i1)
assert_succeeds "single state held throughout" credential_plan_walk "$T/one.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/one-bad" t1,i1 t1,i9)
assert_fails "single-state plan rejects any change" credential_plan_walk "$T/one.plan" "${f[@]}"

plan "$T/s.plan" "trust issuer" "A/I1 A+B/I1 A+B/I2 B/I2"
mapfile -t f < <(seq_files "$T/s-ok" t1,i1 t2,i1 t2,i1 t2,i2 t3,i2)
assert_succeeds "S-staged: four states in order" credential_plan_walk "$T/s.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/s-bad" t1,i1 t2,i1 t2,i2 t1,i2)
assert_fails "S-staged: final trust equal to the first fails (B must differ from A)" credential_plan_walk "$T/s.plan" "${f[@]}"

plan "$T/w.plan" "trust issuer webhooks" "A/I1/W1 A/I1/W2" "A/I1/W1 A/I1/Wg A/I1/W2"
mapfile -t f < <(seq_files "$T/w1" t,i,w1 t,i,w2)
assert_succeeds "W: two webhook states match the first alternative" credential_plan_walk "$T/w.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/w2" t,i,w1 t,i,w2 t,i,w3)
out="$(credential_plan_walk "$T/w.plan" "${f[@]}")"
assert_contains "$out" "walk the declared plan: A/I1/W1 A/I1/Wg A/I1/W2" "W: three webhook states match the second alternative"
mapfile -t f < <(seq_files "$T/w3" t,i,w1 t,i,w2 t,i,w1)
assert_fails "W: returning to the supplied webhook certs fails" credential_plan_walk "$T/w.plan" "${f[@]}"

mapfile -t f < <(seq_files "$T/unread" t1,i1 t1,i1)
printf '[trust-roots ConfigMap read failed: exit 1] x\n' >> "${f[1]}"
assert_fails "an unreadable state file fails the walk" credential_plan_walk "$T/one.plan" "${f[@]}"
plan "$T/bad.plan" "trust issuer" "A/I1/W1"
assert_fails "a label with the wrong number of components dies" credential_plan_walk "$T/bad.plan" "${f[0]}"
printf 'plan A/I1\n' > "$T/nocomp.plan"
assert_fails "a plan without a components line dies" credential_plan_walk "$T/nocomp.plan" "${f[0]}"

finish test-plan
