#!/usr/bin/env bash
# Runs INSIDE the lab VM. Runs every lab/tests/test-*.sh; exits non-zero if any fails.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$TESTS"/test-*.sh; do
  bash "$t" || rc=1
done
exit "$rc"
