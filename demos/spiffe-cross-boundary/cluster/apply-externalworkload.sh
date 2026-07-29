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
kubectl -n mixed-env get externalworkload edge-echo -o wide
kubectl -n mixed-env get endpointslices -l kubernetes.io/service-name=edge-echo -o wide
