#!/usr/bin/env bash
# Scenario W with Linkerd's default failurePolicy, Ignore (design section 3); the shared
# timeline is in lab/scenario-webhook.sh. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/scenario-webhook.sh"

run_scenario 02-webhook-expiry-ignore webhook-short "${1:?usage: 02-webhook-expiry-ignore.sh <run-dir>}"
