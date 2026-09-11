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

finish test-scenarios
