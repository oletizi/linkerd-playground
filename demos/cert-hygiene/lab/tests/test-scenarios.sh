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
# capture and assert_no_keys; capture_cp_rollouts; W's _w_render_apply (LAB_DIR for its source)
# shellcheck source=/dev/null
. "$DEMO/lab/collect.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/stages.sh"
# shellcheck disable=SC2034
LAB_DIR="$DEMO/lab"
# shellcheck source=/dev/null
. "$DEMO/lab/scenario-webhook.sh"
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
# An argument with a space and a comma, and an OUT with a space, each stay one word (%q).
mkdir -p "$T/bin-args"
cat > "$T/bin-args/linkerd" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '[%s]\n' "$a"; done
EOF
chmod +x "$T/bin-args/linkerd"
PATH="$T/bin-args:$PATH" bash -c "$(_w_upgrade_cmd "$T/out dir.txt" --set-file 'p.crtPEM=/a b/c.crt,p.keyPEM=/a b/c.key')"
assert_eq "$(cat "$T/out dir.txt")" "$(printf '[upgrade]\n[--set-file]\n[p.crtPEM=/a b/c.crt,p.keyPEM=/a b/c.key]')" \
  "an argument with a space and a comma survives the shell as one word"

# ---- scans read bytes, not text ----
# One invalid UTF-8 byte makes an unforced grep call the file binary and print no match.
mkdir -p "$T/ev/e" "$T/ev/f" "$T/ev/h"
printf '\377 data:\n  tls.key: %s\n' "$key_b64" > "$T/ev/e/nonutf8.yaml"
assert_eq "$(LC_ALL=C.UTF-8 b64_key_hits "$T/ev/e")" "$T/ev/e/nonutf8.yaml" "a base64 key in a non-UTF-8 file is reported"
printf '\377 -----BEGIN EC PRIVATE KEY-----\n' > "$T/ev/f/nonutf8-pem.txt"
assert_contains "$(LC_ALL=C.UTF-8 key_scan "$T/ev/f")" "private key PEM text: $T/ev/f/nonutf8-pem.txt" "PEM key text in a non-UTF-8 file is reported"
printf 'blob: %s\n' "$(printf '\377 -----BEGIN EC PRIVATE KEY-----\nAAAAFake\n' | base64 -w0)" > "$T/ev/h/inner.yaml"
assert_eq "$(LC_ALL=C.UTF-8 b64_key_hits "$T/ev/h")" "$T/ev/h/inner.yaml" "a key whose decoded text is not UTF-8 is reported"
# A NUL byte before the key: grep reading such a file directly stops printing matches.
mkdir -p "$T/ev/n"
printf 'a\0b\n  tls.key: %s\n' "$key_b64" > "$T/ev/n/nul.yaml"
assert_eq "$(b64_key_hits "$T/ev/n")" "$T/ev/n/nul.yaml" "a base64 key after a NUL byte is reported"

# ---- depth pin: three layers of base64 around a PEM key ----
mkdir -p "$T/ev/g"
mid="$(printf 'overrides: %s\n' "$outer" | base64 -w0)"
printf 'data:\n  deep: %s\n' "$mid" > "$T/ev/g/deep.yaml"
assert_fails "the fixture really needs depth 3" _has_key_b64 2 "$mid"
assert_eq "$(b64_key_hits "$T/ev/g")" "$T/ev/g/deep.yaml" "a key under three layers of base64 is reported"
assert_eq "$(grep -cF "$mid" <<< "$(redact_manifest "$T/ev/g/deep.yaml")")" 0 "a key under three layers of base64 is redacted"

# ---- key_scan: the one scan behind assert_no_keys and key-guard.sh ----
mkdir -p "$T/run-b64" "$T/run-clean"
printf 'data:\n  tls.key: %s\n' "$key_b64" > "$T/run-b64/leak.yaml"   # base64 only: no literal key text
printf 'data:\n  tls.crt: %s\n' "$crt_b64" > "$T/run-clean/cert.yaml"
assert_eq "$(key_scan "$T/run-b64")" "base64-encoded private key: $T/run-b64/leak.yaml" "key_scan reports a base64-only key"
assert_succeeds "key_scan passes a clean directory" key_scan "$T/run-clean"
assert_fails "key_scan fails closed on a missing path" key_scan "$T/no-such-dir"
no_keys_in() { RUN_DIR="$1" assert_no_keys; } # DIR
assert_fails "assert_no_keys fails on a base64-only key" no_keys_in "$T/run-b64"
assert_succeeds "assert_no_keys passes a clean run" no_keys_in "$T/run-clean"
kg="$(bash "$DEMO/lab/key-guard.sh" "$T/run-b64" 2>/dev/null)"
assert_eq "$?" 1 "key-guard exits non-zero on a hit"
assert_contains "$kg" "base64-encoded private key: $T/run-b64/leak.yaml" "key-guard prints the hit"
assert_eq "$(bash "$DEMO/lab/key-guard.sh" "$T/run-clean" 2>/dev/null)" "key-guard: clean $T/run-clean" "key-guard passes a clean directory"
assert_fails "key-guard fails on a missing directory" bash "$DEMO/lab/key-guard.sh" "$T/no-such-dir"

# ---- _w_render_apply fails closed: a redaction the scan still flags never reaches RUN_DIR ----
mkdir -p "$T/bin-r"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncat "$STUB_MANIFEST"\n' > "$T/bin-r/linkerd"
printf '#!/bin/sh\nexit 0\n' > "$T/bin-r/kubectl"
chmod +x "$T/bin-r/linkerd" "$T/bin-r/kubectl"
ra() { mkdir -p "$1-certs"; RUN_DIR="$1" CERTS="$1-certs" STUB_MANIFEST="$2" PATH="$T/bin-r:$PATH" _w_render_apply plain; } # RUN MANIFEST
printf 'kind: Secret\ndata:\n  tls.key: "%s"\n' "$key_b64" > "$T/quoted.yaml"   # quoted: redaction misses it
printf 'kind: Secret\ndata:\n  tls.key: %s\n' "$key_b64" > "$T/plain.yaml"
assert_fails "a redacted manifest that still holds a key dies" ra "$T/ra1" "$T/quoted.yaml"
assert_eq "$(ls "$T/ra1/recover")" plain-render.txt "only the render transcript reached RUN_DIR; nothing was applied"
( ra "$T/ra2" "$T/plain.yaml" ) > /dev/null 2>&1
assert_contains "$(cat "$T/ra2/recover/plain-manifest.yaml" 2>/dev/null)" "tls.key: <redacted sha256=" "a clean redaction reaches RUN_DIR"
assert_eq "$(tail -n 1 "$T/ra2/recover/plain-apply.txt" 2>/dev/null)" "[exit 0]" "then the manifest is applied"

# ---- capture_cp_rollouts: [exit N] is non-zero unless every listed rollout completed ----
mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<'EOF'
#!/bin/sh
case "$3" in
  get) [ "$STUB_GET" = ok ] || exit 1; printf '%s' "$STUB_LIST" ;;
  rollout) exit "$STUB_ROLLOUT" ;;
esac
EOF
chmod +x "$T/bin/kubectl"
cp_last() { # RUN GET LIST ROLLOUT: the last line of capture_cp_rollouts against the stub
  RUN_DIR="$1" STUB_GET="$2" STUB_LIST="$3" STUB_ROLLOUT="$4" PATH="$T/bin:$PATH" capture_cp_rollouts rollout.txt
  tail -n 1 "$1/rollout.txt"
}
assert_eq "$(cp_last "$T/cp1" ok deployment.apps/linkerd-identity 0)" "[exit 0]" "every listed rollout completed"
assert_eq "$(cp_last "$T/cp2" ok '' 0)" "[exit 1]" "no control-plane Deployment listed: non-zero"
assert_eq "$(cp_last "$T/cp3" fail '' 0)" "[exit 1]" "the Deployment listing failed: non-zero"
assert_eq "$(cp_last "$T/cp4" ok deployment.apps/linkerd-identity 1)" "[exit 1]" "a rollout did not complete: non-zero"
cr_last() { RUN_DIR="$1" STUB_ROLLOUT="$2" PATH="$T/bin:$PATH" capture_rollouts rollout.txt "${@:3}"; tail -n 1 "$1/rollout.txt"; } # RUN ROLLOUT DEPLOY...
assert_eq "$(cr_last "$T/cr1" 0)" "[exit 1]" "capture_rollouts with no Deployment named: non-zero"
assert_eq "$(cr_last "$T/cr2" 0 linkerd-destination linkerd-proxy-injector)" "[exit 0]" "capture_rollouts: every named rollout completed"

# ---- w_backing_line, w_backing_deployments: reconnect/backing.txt ----
dep() { printf '{"metadata":{"name":"%s"},"spec":{"template":{"metadata":{"labels":%s}}}}' "$1" "$2"; } # NAME LABELS
printf '{"items":[%s,%s,%s]}\n' "$(dep linkerd-destination '{"c":"destination","ns":"linkerd"}')" \
  "$(dep linkerd-proxy-injector '{"c":"proxy-injector","ns":"linkerd"}')" "$(dep other '{"ns":"linkerd"}')" > "$T/deps.json"
svcj() { printf '{"spec":%s}\n' "$2" > "$T/svc-$1.json"; echo "$T/svc-$1.json"; } # NAME SPEC: prints the path
bl() { w_backing_line policyValidator linkerd-policy-validator "$@"; } # SVC_JSON DEPLOYS_JSON [READ_ERROR]
assert_eq "$(bl "$(svcj two '{"selector":{"c":"destination","ns":"linkerd"}}')" "$T/deps.json")" \
  "component=policyValidator service=linkerd-policy-validator deployment=linkerd-destination" "the one Deployment whose pod template carries every selector label"
assert_eq "$(bl "$(svcj ns '{"selector":{"ns":"linkerd"}}')" "$T/deps.json")" \
  "component=policyValidator service=linkerd-policy-validator deployment=linkerd-destination,linkerd-proxy-injector,other" "several matching Deployments are comma-joined"
assert_contains "$(bl "$(svcj none '{"selector":{"c":"nothing"}}')" "$T/deps.json")" " deployment=- error=no Deployment pod template matches the selector" "no match: recorded, not fatal"
assert_contains "$(bl "$(svcj nosel '{}')" "$T/deps.json")" " deployment=- error=" "a Service without a selector backs nothing"
printf 'not json\n' > "$T/bad.json"
assert_contains "$(bl "$T/bad.json" "$T/deps.json")" " deployment=- error=unreadable Service or Deployment JSON: " "unreadable JSON: recorded, not fatal"
assert_eq "$(bl "$T/bad.json" "$T/bad.json" '[Service read failed: exit 1] refused')" \
  "component=policyValidator service=linkerd-policy-validator deployment=- error=[Service read failed: exit 1] refused" "a failed read is recorded with its error"
printf 'component=a service=s1 deployment=d2\ncomponent=b service=s2 deployment=d1,d2\ncomponent=c service=s3 deployment=- error=x deployment=d9\n' > "$T/backing.txt"
assert_eq "$(w_backing_deployments "$T/backing.txt" | paste -sd' ' -)" "d2 d1" "each distinct backing Deployment once; - and error text are not Deployments"

# ---- w_branch_classify: valid_now alone; w_fact_line ----
facts "$T/b8" no no no no yes healthy
assert_eq "$(w_branch_classify "$T/b8")" branch=iii "fresh, verifying, serving, but not valid now: iii"
printf 'not a certificate\n' > "$T/junk.crt"
: > "$T/empty.pem"
assert_eq "$(w_fact_line proxyInjector bb "$T/junk.crt" "$T/empty.pem" 100)" \
  "component=proxyInjector secret_sha256=unreadable supplied_sha256=bb equals_supplied=unreadable not_after_epoch=unreadable valid_now=unreadable cabundle_verifies=unreadable" \
  "a Secret value that is not a certificate is recorded as unreadable, not fatal"
assert_eq "$(w_fact_line policyValidator bb "$T/empty.pem" "$T/empty.pem" 100)" \
  "component=policyValidator secret_sha256=- supplied_sha256=bb equals_supplied=no not_after_epoch=- valid_now=no cabundle_verifies=no" \
  "no Secret certificate: dashes"
{ w_fact_line proxyInjector bb "$T/junk.crt" "$T/empty.pem" 100; grep -v '^component=proxyInjector ' "$T/b1"; } > "$T/b9"
assert_eq "$(w_branch_classify "$T/b9")" branch=iii "an unreadable Secret matches neither i nor ii: iii"
{ w_fact_line proxyInjector bb "$T/junk.crt" "$T/empty.pem" 100; grep -v '^component=proxyInjector ' "$T/b2"; } > "$T/b10"
assert_eq "$(w_branch_classify "$T/b10")" branch=iii "two supplied and one unreadable: iii"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/wk.key" -out "$T/wc.crt" \
  -days 1 -subj /CN=w-test > /dev/null 2>&1
printf '%s' "$(cat "$T/wc.crt")" > "$T/wca.pem"   # a caBundle without its trailing newline (Task 1's round trip)
wsha="$(cert_facts x < "$T/wc.crt" | awk -F= '$1 == "x_sha256" { print $2 }')"
wline="$(w_fact_line profileValidator "$wsha" "$T/wc.crt" "$T/wca.pem" "$(date -u +%s)")"
assert_contains "$wline" " equals_supplied=yes " "the supplied certificate matches by X.509 fingerprint"
assert_contains "$wline" " valid_now=yes cabundle_verifies=yes" "a valid certificate verifies against a caBundle without its trailing newline"

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
