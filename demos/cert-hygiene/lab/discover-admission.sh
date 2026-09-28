#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a healthy lab (long profile) with baseline workloads.
# Tries each candidate invalid policy and ServiceProfile resource and its valid twin,
# and records which the healthy validators reject with their own message (design 10).
# Usage: discover-admission.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"
RUN_DIR="${1:?usage: discover-admission.sh <out-dir>}"
[ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists; refusing to overwrite"
mkdir -p "$RUN_DIR"

for cfg in validatingwebhookconfiguration/linkerd-policy-validator-webhook-config \
    validatingwebhookconfiguration/linkerd-sp-validator-webhook-config; do
  printf '%s webhooks=%s\n' "$cfg" "$(kubectl get "$cfg" -o jsonpath='{.webhooks[*].name}')"
done > "$RUN_DIR/webhook-names.txt"
admission_attempt inject inject-probe-discovery inject-probe
for c in policy-1 policy-2 policy-3 sp-1 sp-2 sp-3; do
  case "$c" in policy-*) wh="$POLICY_VALIDATOR_WEBHOOK_NAME" ;; sp-*) wh="$SP_VALIDATOR_WEBHOOK_NAME" ;; esac
  admission_attempt candidates "$c-invalid-discovery" "candidates/$c-invalid"
  admission_attempt candidates "$c-valid-discovery" "candidates/$c-valid"
  inv="$RUN_DIR/admission/candidates/$c-invalid-discovery.response.txt"
  val="$RUN_DIR/admission/candidates/$c-valid-discovery.response.txt"
  denied=no; accepted=no
  if admission_denied_by "$wh" "$inv"; then denied=yes; fi
  if [ "$(tail -n 1 "$val")" = "[exit 0]" ]; then accepted=yes; fi
  printf 'candidate=%s invalid_denied_by_validator=%s valid_accepted=%s\n' "$c" "$denied" "$accepted"
done > "$RUN_DIR/summary.txt"
cat "$RUN_DIR/webhook-names.txt" "$RUN_DIR/summary.txt"
