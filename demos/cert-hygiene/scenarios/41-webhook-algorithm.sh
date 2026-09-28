#!/usr/bin/env bash
# Scenario G (design section 4, slice 4): the sp-validator webhook's serving certificate
# is time-valid and correctly chained but signed with an algorithm the API server
# refuses; the shared timeline is in lab/scenario-g.sh. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/scenario-g.sh"

run_scenario 41-webhook-algorithm webhook-algorithm "${1:?usage: 41-webhook-algorithm.sh <run-dir>}"
