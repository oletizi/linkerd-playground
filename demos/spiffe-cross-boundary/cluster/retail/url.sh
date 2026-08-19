#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Prints the dashboard URL and nothing else, so it can
# be used directly: open "$(... url.sh)".
#
# Neither half of that URL is safe to write down. The address depends on the
# topology -- libvirt pins it, Lima and OrbStack assign it -- and the port is a
# NodePort Kubernetes allocates. Ask the cluster instead of hardcoding either.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$DEMO/../.." && pwd)/lib/common.sh"; load_config "$DEMO"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found — run this on the cluster box (Box A)."

port="$(kubectl -n "${DEMO_NS}" get svc retail-cloud-lan \
          -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"

[ -n "$port" ] || die "the retail-cloud-lan Service does not exist in namespace '${DEMO_NS}'.
  Run cluster/retail/apply.sh (Build it step 5) first."

echo "http://${CLUSTER_NODE_ADDR}:${port}/"
