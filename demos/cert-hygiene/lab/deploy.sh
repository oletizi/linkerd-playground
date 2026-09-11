#!/usr/bin/env bash
# Runs INSIDE the lab VM. Renders and applies the lab workloads.
# Usage: deploy.sh <baseline|probe-new>
#   baseline:  namespace, probe-script ConfigMap, server, the four probes and
#              restart-target; waits for every rollout.
#   probe-new: the workload first created after T_iss. Applied WITHOUT waiting: after
#              issuer expiry it is expected never to become Ready.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
what="${1:?usage: deploy.sh <baseline|probe-new>}"
require_pinned_images
export LAB_NS IMAGE_CURL IMAGE_SOCAT IMAGE_BUSYBOX PROBE_INTERVAL_S

render() { # workload-file-stem; substitutes only the listed variables
  # shellcheck disable=SC2016
  envsubst '${LAB_NS} ${IMAGE_CURL} ${IMAGE_SOCAT} ${IMAGE_BUSYBOX} ${PROBE_INTERVAL_S}' < "$LAB_DIR/workloads/$1.yaml"
}

case "$what" in
  baseline)
    render namespace | kubectl apply -f -
    kubectl -n "$LAB_NS" create configmap lab-probes --from-file="$LAB_DIR/probes" \
      --dry-run=client -o yaml | kubectl apply -f -
    render baseline | kubectl apply -f -
    for d in server probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream restart-target; do
      kubectl -n "$LAB_NS" rollout status "deploy/$d" --timeout=5m
    done
    ;;
  probe-new)
    render probe-new | kubectl apply -f -
    ;;
  *) die "usage: deploy.sh <baseline|probe-new>" ;;
esac
