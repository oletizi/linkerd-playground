#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Registers the edge as an ExternalWorkload + fronting Service.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$DEMO/../.." && pwd)/lib/common.sh"; load_config "$DEMO"
[ "$EDGE_ADDR" != "CHANGE_ME" ] || die "set EDGE_ADDR in config.local.env"
export PATH="${HOME}/.linkerd2/bin:${PATH}"

# Render __EDGE_ADDR__ with bash parameter expansion (no sed, per house rules).
render() { while IFS= read -r line; do echo "${line/__EDGE_ADDR__/$EDGE_ADDR}"; done < "$HERE/externalworkload.yaml"; }
render | kubectl apply -f -

# The ExternalWorkload endpoint is NotReady until a Ready status condition is set.
# status is a subresource, so `kubectl apply` of the spec cannot set it — patch it.
# (In production a controller/health-check would own readiness; here we mark it ready.)
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl -n mixed-env patch externalworkload edge-echo --subresource=status --type=merge \
  -p "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"ManuallyReady\",\"message\":\"marked ready for demo\",\"lastTransitionTime\":\"${NOW}\"}]}}"

kubectl -n mixed-env get externalworkload edge-echo -o wide
kubectl -n mixed-env get endpointslices -l kubernetes.io/service-name=edge-echo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" ready="}{.endpoints[0].conditions.ready}{"\n"}{end}'
