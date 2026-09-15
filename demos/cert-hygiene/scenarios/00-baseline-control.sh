#!/usr/bin/env bash
# Negative control with restart choreography (design section 1.7): R's timeline and
# R's four gated recovery stages, with long-lived credentials. T_mark sits where R's
# issuer would expire, so both runs snapshot the same moments. Nothing should fail
# outside a restart; failures during restarts are the rollout-disruption baseline.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  echo $(( $(cert_not_before_epoch "$CERTS/issuer.crt") + $(duration_to_seconds "$CONTROL_T_MARK_AFTER") ))
}
scenario_recover() {
  mark recover-none "control run: nothing expired; running R's restart stages with nothing to recover"
  restart_stages
}

run_scenario 00-baseline-control long "${1:?usage: 00-baseline-control.sh <run-dir>}"
