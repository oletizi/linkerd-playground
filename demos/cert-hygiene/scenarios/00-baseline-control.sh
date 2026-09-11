#!/usr/bin/env bash
# Negative control (design spec section 4.4): the scenario #5 timeline and actions,
# with long-lived credentials. T_mark sits where #5's issuer would expire, so both
# runs snapshot the same moments. Nothing should fail. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  echo $(( $(cert_not_before_epoch "$CERTS/issuer.crt") + $(duration_to_seconds "$CONTROL_T_MARK_AFTER") ))
}
scenario_recover() {
  mark recover-none "control run: nothing expired, nothing to recover"
}

run_scenario 00-baseline-control long "${1:?usage: 00-baseline-control.sh <run-dir>}"
