#!/usr/bin/env bash
# Unit tests for scenario V's pure-ish helpers in scenarios/30-tap-expiry.sh: _v_tap_events'
# counting, and _v_backing / _v_backing_namespace (slice 3 Task 1 item 3: _v_backing now
# carries the namespace it derived instead of _v_reconnect hardcoding linkerd-viz).
#
# scenarios/30-tap-expiry.sh is V's launcher AND its function library in one file (unlike
# W, whose functions live in lab/scenario-webhook.sh with no invocation, sourced by its own
# thin launcher scenarios/02-webhook-expiry-*.sh). Sourcing it unmodified would run
# run_scenario for real -- a live cluster reset and timed scenario -- which this task
# forbids and a unit test must never do. So this file sources scenario-common.sh once
# itself (giving RUN_DIR/mark/capture/_record/w_backing_line etc, exactly what
# 30-tap-expiry.sh's own sourcing line loads), then sources a copy of 30-tap-expiry.sh with
# only two lines removed: that same sourcing line (redundant once done above) and the
# trailing run_scenario invocation. Every function definition in between -- the part under
# test -- is copied and sourced unchanged. The copy is written under mktemp, never into the
# repository, and is never executed, only sourced.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/scenario-common.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

TAP_SCENARIO="$DEMO/scenarios/30-tap-expiry.sh"
# shellcheck disable=SC2016   # the single-quoted pattern is meant literally, for grep -F
grep -vF '. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"' "$TAP_SCENARIO" \
  | grep -v '^run_scenario ' > "$T/tap-functions.sh"
# Each grep -v above matches exactly one line today. If either ever stops matching -- the
# launcher line is reworded, or 30-tap-expiry.sh grows a second "run_scenario " call --
# this file would silently source a copy that still ends in a live run_scenario
# invocation: a real, timed cluster reset from a unit test. Guard it explicitly rather
# than trust that arithmetic silently: refuse to source anything but a copy exactly two
# lines shorter than the original.
orig_lines="$(wc -l < "$TAP_SCENARIO")"
stripped_lines="$(wc -l < "$T/tap-functions.sh")"
[ "$stripped_lines" -eq "$(( orig_lines - 2 ))" ] || die \
  "30-tap-expiry.sh stripped to $stripped_lines lines from $orig_lines original (expected exactly 2 fewer); the source-line or run_scenario filter no longer matches what it should -- refusing to source a copy that might still invoke run_scenario for real"
# shellcheck source=/dev/null
. "$T/tap-functions.sh"

set +e   # assertions count failures; they must not abort the suite

# ---- _v_tap_events: counts complete JSON objects, tolerant of a timeout(1) mid-cut ----
tapfile() { # FILE BODY...: a capture()-shaped tap transcript (header line, body, [exit N])
  local f="$1"; shift
  { printf '$ timeout 10s linkerd viz tap deploy/server -n cert-hygiene -o json\n'; printf '%s\n' "$@"; printf '[exit %s]\n' "${STUB_EXIT:-0}"; } > "$f"
}
tapfile "$T/three.txt" '{"id":1}' '{"id":2}' '{"id":3}'
assert_eq "$(_v_tap_events "$T/three.txt")" 3 "three complete JSON objects: counted 3"
STUB_EXIT=124 tapfile "$T/none.txt"
assert_eq "$(_v_tap_events "$T/none.txt")" 0 "no events between the header and [exit 124]: 0"
STUB_EXIT=124 tapfile "$T/cut.txt" '{"id":1}' '{"id":2'
assert_eq "$(_v_tap_events "$T/cut.txt")" 1 "a stream timeout(1) cut mid-object: the complete object before it still counts"
tapfile "$T/one.txt" '{"id":1}'
assert_eq "$(_v_tap_events "$T/one.txt")" 1 "one complete JSON object: counted 1"
assert_eq "$(_v_tap_events "$T/no-such-file.txt" 2>/dev/null)" 0 "a missing tap capture: 0, never fatal"

# head -n -1's strip is otherwise untested: jq already discards "[exit N]" on its own
# (it is not valid JSON, and jq streams out every complete value it finds before erroring
# on it), so every assertion above passes identically with head -n -1 deleted -- proved
# by mutation while writing this fixture, then removed again. A real capture() (collect.sh)
# never inserts a newline of its own between a command's raw output and the footer it
# appends; if the command's last byte is not itself a newline -- plausible when timeout(1)
# kills `linkerd viz tap` mid-stream -- the footer lands on the SAME physical line as
# whatever came before it. tapfile() above always inserts a newline after every body
# argument, so it cannot reproduce that; built directly here instead, with the final body
# event glued straight onto "[exit 0]" with no separating newline.
{
  printf '$ timeout 10s linkerd viz tap deploy/server -n cert-hygiene -o json\n'
  printf '%s\n' '{"id":1}' '{"id":2}'
  printf '%s' '{"id":3}'
  printf '[exit 0]\n'
} > "$T/glued.txt"
assert_eq "$(_v_tap_events "$T/glued.txt")" 2 \
  "a complete final event glued to the [exit N] footer (no newline before it) is dropped along with it by head -n -1; only the two cleanly newline-terminated events before it count"

# ---- _v_backing / _v_backing_namespace: the namespace= field (slice 3 Task 1 item 3) ----
mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<'EOF'
#!/bin/sh
# Stub for _v_backing's three reads: the tap APIService, its backing Service, then that
# Service's namespace's Deployments. STUB_{A,S,D}_OK select success/failure per step.
if [ "$1" = get ] && [ "$2" = apiservice ]; then
  [ "$STUB_A_OK" = 1 ] && cat "$STUB_A_JSON" || { echo "apiservice read failed" >&2; exit 1; }
elif [ "$1" = -n ] && [ "$3" = get ] && [ "$4" = svc ]; then
  [ "$STUB_S_OK" = 1 ] && cat "$STUB_S_JSON" || { echo "svc read failed" >&2; exit 1; }
elif [ "$1" = -n ] && [ "$3" = get ] && [ "$4" = deploy ]; then
  [ "$STUB_D_OK" = 1 ] && cat "$STUB_D_JSON" || { echo "deploy read failed" >&2; exit 1; }
else
  echo "unexpected kubectl invocation: $*" >&2; exit 2
fi
EOF
chmod +x "$T/bin/kubectl"
printf '%s' '{"spec":{"service":{"name":"tap","namespace":"linkerd-viz"}}}' > "$T/apisvc.json"
printf '%s' '{"spec":{"selector":{"app":"tap"}}}' > "$T/svc.json"
printf '%s' '{"items":[{"metadata":{"name":"tap"},"spec":{"template":{"metadata":{"labels":{"app":"tap"}}}}}]}' > "$T/deploy.json"

vbacking() { # RUN_DIR: run _v_backing fully stubbed ok, with overrides from the caller's env
  mkdir -p "$1/reconnect"
  RUN_DIR="$1" STUB_A_JSON="$T/apisvc.json" STUB_A_OK="${STUB_A_OK:-1}" \
    STUB_S_JSON="$T/svc.json" STUB_S_OK="${STUB_S_OK:-1}" \
    STUB_D_JSON="$T/deploy.json" STUB_D_OK="${STUB_D_OK:-1}" \
    PATH="$T/bin:$PATH" _v_backing
}
vbacking "$T/r1"
assert_eq "$(cat "$T/r1/reconnect/backing.txt")" "component=tap service=tap deployment=tap namespace=linkerd-viz" \
  "_v_backing's line carries component, service, deployment and the derived namespace"
assert_eq "$(_v_backing_namespace "$T/r1/reconnect/backing.txt")" linkerd-viz \
  "_v_backing_namespace reads the namespace field back out of backing.txt"

STUB_A_OK=0 vbacking "$T/r2"
assert_contains "$(cat "$T/r2/reconnect/backing.txt")" "namespace=-" \
  "a failed APIService read leaves namespace as the '-' sentinel, never blank"
assert_eq "$(_v_backing_namespace "$T/r2/reconnect/backing.txt")" - \
  "_v_backing_namespace reports '-' when _v_backing recorded none"

printf 'component=tap service=tap deployment=- error=[Service tap read failed: exit 1] refused\n' > "$T/nofield.txt"
assert_eq "$(_v_backing_namespace "$T/nofield.txt")" "" \
  "a backing.txt with no namespace field at all (an older fixture) reads back empty, distinct from the '-' sentinel"

finish test-tap-expiry
