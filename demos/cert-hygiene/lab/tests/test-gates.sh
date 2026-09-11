#!/usr/bin/env bash
# Unit tests for lab/gates.sh's pure trust-comparison helper. Runs INSIDE the lab VM.
# _trust_yn is the one piece of the restart-gate (_gate_check, carried item D) and the
# anchor-scenario canary check (_a_canary_state, carried item C) that is pure enough to
# unit test without a live cluster: both callers pass it their "current trust" read
# (_trust_now, or the pod's trust-root-sha256 annotation) and must never treat two
# failed reads ("-") as a match.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
# shellcheck source=/dev/null
. "$DEMO/lab/gates.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
set +e   # assertions count failures; they must not abort the suite

assert_eq "$(_trust_yn abc123 abc123)" yes "matching real hashes: met"
assert_eq "$(_trust_yn abc123 def456)" no "different real hashes: unmet"
assert_eq "$(_trust_yn - -)" no "two failed reads (both -) never compare equal: unmet"
assert_eq "$(_trust_yn - abc123)" no "failed WANT read (trust ConfigMap unreadable): unmet"
assert_eq "$(_trust_yn abc123 -)" no "failed GOT read (pod annotation missing): unmet"

finish test-gates
