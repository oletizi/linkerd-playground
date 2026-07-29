#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"
load_config "$HERE"
log "demo: spiffe-cross-boundary"
log "cluster VM: ${CLUSTER_VM} (${CLUSTER_CPUS}cpu/${CLUSTER_MEM}) @ ${CLUSTER_NODE_ADDR}"
log "edge VM:    ${EDGE_VM} (${EDGE_CPUS}cpu/${EDGE_MEM}) @ ${EDGE_ADDR}"
log "linkerd:    ${LINKERD_EDGE_VERSION}   ns: ${DEMO_NS}"
if command -v limactl >/dev/null 2>&1; then
  limactl list
else
  log "limactl not installed here (run on a box that provisions a VM)"
fi
