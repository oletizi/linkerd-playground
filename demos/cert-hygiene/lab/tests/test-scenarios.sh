#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-scenarios.sh (scenario-specific pure rules).
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

# ---- admission_denied_by ----
PW=linkerd-policy-validator.linkerd.io
SW=linkerd-sp-validator.linkerd.io
printf '$ kubectl create\nError from server: admission webhook "%s" denied the request: bad ttl\n[exit 1]\n' "$SW" > "$T/dby-ok.txt"
assert_succeeds "denied by its own validator" admission_denied_by "$SW" "$T/dby-ok.txt"
printf '$ kubectl create\ncreated\n[exit 0]\n' > "$T/dby-accepted.txt"
assert_fails "an accepted object is not denied" admission_denied_by "$SW" "$T/dby-accepted.txt"
printf '$ kubectl create\nError from server: admission webhook "%s" denied the request\n[exit 1]\n' "$PW" > "$T/dby-wrong.txt"
assert_fails "denied by a different validator does not count" admission_denied_by "$SW" "$T/dby-wrong.txt"
assert_fails "a missing file is not denied" admission_denied_by "$SW" "$T/dby-missing.txt"

# ---- admission_proof_check ----
proof() { # DIR: a probe set (suffix s1) that proves all three webhooks
  local d="$1"
  mkdir -p "$d"
  printf '$ kubectl create -f x\npod/inject-probe-s1 created\n[exit 0]\n' > "$d/inject-probe-s1.response.txt"
  printf '$ kubectl get\napiVersion: v1\nkind: Pod\nspec:\n  initContainers:\n  - name: linkerd-init\n  - name: linkerd-proxy\n  containers:\n  - name: idle\n[exit 0]\n' > "$d/inject-probe-s1.observed.yaml"
  printf '$ kubectl create\nError from server: admission webhook "%s" denied the request: invalid cidr\n[exit 1]\n' "$PW" > "$d/policy-invalid-s1.response.txt"
  printf '$ kubectl create\nError from server: admission webhook "%s" denied the request: bad ttl\n[exit 1]\n' "$SW" > "$d/serviceprofile-invalid-s1.response.txt"
  printf '$ kubectl create\ncreated\n[exit 0]\n' > "$d/policy-valid-s1.response.txt"
  printf '$ kubectl create\ncreated\n[exit 0]\n' > "$d/serviceprofile-valid-s1.response.txt"
}
proof "$T/a0"
assert_succeeds "a healthy probe set proves all three webhooks" admission_proof_check "$T/a0" s1 "$PW" "$SW"
proof "$T/a1"; printf '$ kubectl get\nkind: Pod\nspec:\n  containers:\n  - name: idle\n[exit 0]\n' > "$T/a1/inject-probe-s1.observed.yaml"
assert_fails "a pod without linkerd-proxy does not prove the injector" admission_proof_check "$T/a1" s1 "$PW" "$SW"
proof "$T/a2"; printf '$ kubectl create\ncreated\n[exit 0]\n' > "$T/a2/policy-invalid-s1.response.txt"
assert_fails "an accepted invalid policy does not prove the validator" admission_proof_check "$T/a2" s1 "$PW" "$SW"
proof "$T/a3"; printf '$ kubectl create\nThe ServiceProfile "x" is invalid: spec.routes[0].condition: Required value\n[exit 1]\n' > "$T/a3/serviceprofile-invalid-s1.response.txt"
assert_fails "a CRD-schema rejection does not prove the sp-validator" admission_proof_check "$T/a3" s1 "$PW" "$SW"
proof "$T/a4"; printf '$ kubectl create\nError from server: admission webhook "%s" denied the request\n[exit 1]\n' "$SW" > "$T/a4/policy-invalid-s1.response.txt"
assert_fails "a rejection by the wrong webhook does not count" admission_proof_check "$T/a4" s1 "$PW" "$SW"
proof "$T/a5"; printf '$ kubectl create\nerror\n[exit 1]\n' > "$T/a5/serviceprofile-valid-s1.response.txt"
assert_fails "a rejected valid ServiceProfile fails the proof" admission_proof_check "$T/a5" s1 "$PW" "$SW"
proof "$T/a6"; rm "$T/a6/policy-valid-s1.response.txt"
assert_fails "a missing attempt fails the proof" admission_proof_check "$T/a6" s1 "$PW" "$SW"

# ---- redact_manifest ----
key_b64="$(printf -- '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIFakeKeyMaterialForUnitTests\n-----END EC PRIVATE KEY-----\n' | base64 -w0)"
crt_b64="$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBFakeCertificateForUnitTests\n-----END CERTIFICATE-----\n' | base64 -w0)"
{
  printf 'apiVersion: v1\nkind: Secret\ndata:\n'
  printf '  tls.crt: %s\n  tls.key: %s\n' "$crt_b64" "$key_b64"
  printf -- '---\nkind: ConfigMap\ndata:\n  values: |\n    keyPEM: |\n'
  printf '      -----BEGIN EC PRIVATE KEY-----\n      AAAAFakeBlock\n      -----END EC PRIVATE KEY-----\n'
  printf '    other: kept\n'
} > "$T/m.yaml"
red="$(redact_manifest "$T/m.yaml")"
assert_eq "$(grep -c 'PRIVATE KEY' <<< "$red")" 0 "no private key text survives"
assert_eq "$(grep -cF "$key_b64" <<< "$red")" 0 "no base64 key survives"
assert_contains "$red" "tls.crt: $crt_b64" "certificates are kept"
assert_contains "$red" "tls.key: <redacted sha256=$(printf '%s' "$key_b64" | sha256sum | cut -d' ' -f1)>" "a base64 key becomes a hash marker"
assert_contains "$red" "      <redacted private key block>" "a PEM key block becomes one marker, indentation kept"
assert_contains "$red" "    other: kept" "lines after a block are kept"

# ---- b64_key_hits ----
mkdir -p "$T/ev/a" "$T/ev/b"
printf 'data:\n  tls.key: %s\n' "$key_b64" > "$T/ev/a/leak.yaml"
printf 'data:\n  tls.crt: %s\n' "$crt_b64" > "$T/ev/b/cert.yaml"
printf '%s\n' "$red" > "$T/ev/b/redacted.yaml"
assert_eq "$(b64_key_hits "$T/ev")" "$T/ev/a/leak.yaml" "only the file holding a base64 private key is reported"
assert_eq "$(b64_key_hits "$T/ev/b")" "" "certificates and redacted manifests pass"
# A key whose PEM header does not start the encoded text (so the encoding never begins
# with the encoding of "-----BEGIN"): found only by decoding every long run.
mkdir -p "$T/ev/c" "$T/ev/d"
shifted="$(printf 'prefix text; -----BEGIN EC PRIVATE KEY-----\nAAAAShiftedFake\n-----END EC PRIVATE KEY-----\n' | base64 -w0)"
printf 'data:\n  blob: %s\n' "$shifted" > "$T/ev/c/shifted.yaml"
assert_eq "$(b64_key_hits "$T/ev/c")" "$T/ev/c/shifted.yaml" "a key not at the start of the encoded text is reported"
# The linkerd-config-overrides shape: base64 YAML whose text carries a base64 PEM key.
outer="$(printf 'identity:\n  issuer:\n    tls:\n      keyPEM: %s\n' "$key_b64" | base64 -w0)"
printf 'data:\n  linkerd-config-overrides: %s\n' "$outer" > "$T/ev/d/overrides.yaml"
assert_eq "$(b64_key_hits "$T/ev/d")" "$T/ev/d/overrides.yaml" "a base64 PEM key nested inside a base64 value is reported"
red2="$(redact_manifest "$T/ev/d/overrides.yaml")"
assert_eq "$(grep -cF "$outer" <<< "$red2")" 0 "the nested key's outer value is redacted"
assert_contains "$red2" "linkerd-config-overrides: <redacted sha256=" "the redaction keeps the key name"

# ---- w_branch_classify ----
facts() { # FILE EQ1 EQ2 EQ3 VALID VERIFIES ADMISSION
  local f="$1" c eq
  : > "$f"
  for c in proxyInjector:"$2" policyValidator:"$3" profileValidator:"$4"; do
    eq="${c#*:}"
    printf 'component=%s secret_sha256=aa supplied_sha256=bb equals_supplied=%s not_after_epoch=9 valid_now=%s cabundle_verifies=%s\n' \
      "${c%%:*}" "$eq" "$5" "$6" >> "$f"
  done
  printf 'admission=%s\n' "$7" >> "$f"
}
facts "$T/b2" yes yes yes no no unhealthy
assert_eq "$(w_branch_classify "$T/b2")" branch=ii "all three still the supplied certificates: ii"
facts "$T/b1" no no no yes yes healthy
assert_eq "$(w_branch_classify "$T/b1")" branch=i "fresh, valid, verifying, serving: i"
facts "$T/b3" no no no yes no healthy
assert_eq "$(w_branch_classify "$T/b3")" branch=iii "a caBundle mismatch: iii"
facts "$T/b4" no no no yes yes unhealthy
assert_eq "$(w_branch_classify "$T/b4")" branch=iii "fresh certificates but admission unhealthy: iii"
facts "$T/b5" yes no no yes yes healthy
assert_eq "$(w_branch_classify "$T/b5")" branch=iii "some supplied, some fresh: iii"
head -n 2 "$T/b1" > "$T/b6"; echo admission=healthy >> "$T/b6"
assert_fails "two component lines die" w_branch_classify "$T/b6"
grep -v '^admission=' "$T/b1" > "$T/b7"
assert_fails "no admission line dies" w_branch_classify "$T/b7"

# ---- _w_upgrade_cmd (C1's fix: arguments only when there are some) ----
assert_eq "$(_w_upgrade_cmd /tmp/w-render.yaml)" "linkerd upgrade > /tmp/w-render.yaml" \
  "no arguments: exactly \"linkerd upgrade\", no trailing empty argument"
assert_eq "$(_w_upgrade_cmd /tmp/w-render.yaml --set-file x=a)" "linkerd upgrade --set-file x=a > /tmp/w-render.yaml" \
  "arguments are present and quoted"

finish test-scenarios
