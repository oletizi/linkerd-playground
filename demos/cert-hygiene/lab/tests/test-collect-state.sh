#!/usr/bin/env bash
# Unit tests for lab/collect-state.sh's V-only collector, snap_apiservices, stubbing
# kubectl on PATH the way test-webhook.sh's capture_cp_rollouts tests do.
# collect-state.sh had no test file before this task.
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
# collect.sh sources collect-state.sh (and collect-logs.sh) at its own tail.
# shellcheck source=/dev/null
. "$DEMO/lab/collect.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<'EOF'
#!/bin/sh
# Stub: only "kubectl get apiservice v1alpha1.tap.linkerd.io -o json", the one call
# snap_apiservices makes. Matched against the full argument list, not just "$1 $2", so a
# regression that changed the APIService name in snap_apiservices (or dropped -o json)
# would fail this stub instead of being silently accepted. STUB_GET selects
# success/failure; STUB_JSON is the fixture body.
case "$*" in
  "get apiservice v1alpha1.tap.linkerd.io -o json")
    if [ "$STUB_GET" = ok ]; then cat "$STUB_JSON"
    else echo 'apiservices.apiregistration.k8s.io "v1alpha1.tap.linkerd.io" not found' >&2; exit 1
    fi
    ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/kubectl"

snap() { # RUN NAME JSON_FILE [GET(ok|fail)]
  mkdir -p "$1"
  RUN_DIR="$1" STUB_JSON="$3" STUB_GET="${4:-ok}" PATH="$T/bin:$PATH" snap_apiservices "$2"
}

# ---- a present caBundle is hashed ----
printf '%s' '{"status":{"conditions":[{"type":"Available","status":"True","reason":"Passed","message":"all checks passed"}]},"spec":{"service":{"name":"tap","namespace":"linkerd-viz"},"caBundle":"aGVsbG8="}}' \
  > "$T/present.json"
snap "$T/r1" baseline "$T/present.json"
want_hash="$(printf 'hello' | sha256sum | cut -d' ' -f1)"
out="$(cat "$T/r1/apiservices/baseline.txt")"
assert_contains "$out" "apiservice_cabundle_sha256=$want_hash" "a present caBundle is hashed"
assert_contains "$out" "apiservice_available_status=True" "the Available condition's status is recorded"
assert_contains "$out" "apiservice_available_reason=Passed" "the Available condition's reason is recorded"
assert_contains "$out" "apiservice_available_message=all checks passed" "the Available condition's message is recorded"
assert_contains "$out" "apiservice_backing_service=tap.linkerd-viz.svc" "the backing Service is recorded"

# ---- an absent caBundle records "-", the sentinel every neighbouring field uses, never
# the hash of an empty string (slice 3 review finding: this fixed a real ambiguity) ----
printf '%s' '{"status":{"conditions":[{"type":"Available","status":"False","reason":"FailedDiscoveryCheck","message":"failing"}]},"spec":{"service":{"name":"tap","namespace":"linkerd-viz"}}}' \
  > "$T/absent.json"
snap "$T/r2" verify "$T/absent.json"
out2="$(cat "$T/r2/apiservices/verify.txt")"
assert_contains "$out2" "apiservice_cabundle_sha256=-" "no caBundle key at all: the '-' sentinel, not a hash"
want_empty_hash="$(printf '' | sha256sum | cut -d' ' -f1)"
assert_eq "$(grep -c "apiservice_cabundle_sha256=$want_empty_hash" "$T/r2/apiservices/verify.txt")" 0 \
  "never the empty-string hash masquerading as a real caBundle hash"
assert_contains "$out2" "apiservice_available_status=False" "a failing Available condition is recorded too"

# ---- caBundle present but the empty string: same sentinel, same reasoning ----
printf '%s' '{"status":{"conditions":[]},"spec":{"service":{"name":"tap","namespace":"linkerd-viz"},"caBundle":""}}' \
  > "$T/emptystr.json"
snap "$T/r3" x "$T/emptystr.json"
out3="$(cat "$T/r3/apiservices/x.txt")"
assert_contains "$out3" "apiservice_cabundle_sha256=-" "an empty-string caBundle also records '-', not a computed hash"
assert_contains "$out3" "apiservice_available_status=-" "no Available condition at all: status is '-'"

# ---- no backing Service named at all ----
printf '%s' '{"status":{"conditions":[]},"spec":{}}' > "$T/nosvc.json"
snap "$T/r5" z "$T/nosvc.json"
assert_contains "$(cat "$T/r5/apiservices/z.txt")" "apiservice_backing_service=<none>.<none>.svc" \
  "a missing service name and namespace both fall back to <none>"

# ---- a failed APIService read is recorded, never fatal ----
snap "$T/r4" y "$T/present.json" fail
assert_contains "$(cat "$T/r4/apiservices/y.txt")" "v1alpha1.tap.linkerd.io read failed" \
  "a failed read is recorded in the snapshot file"

finish test-collect-state
