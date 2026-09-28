#!/usr/bin/env bash
# Scenario N with Linkerd's default failurePolicy, Ignore (design section 3, slice 4); the
# shared timeline is in lab/scenario-n.sh. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/scenario-n.sh"

run_scenario 40-webhook-unavailable-ignore webhook-unavailable "${1:?usage: 40-webhook-unavailable-ignore.sh <run-dir>}"
