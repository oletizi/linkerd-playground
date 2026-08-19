#!/usr/bin/env bash
# Show demo configuration + local VM state.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$(cd "$SCRIPTS/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"
load_config "$HERE"

log "demo: spiffe-cross-boundary"
log "linkerd:    ${LINKERD_EDGE_VERSION}   ns: ${DEMO_NS}"

if [ "$(uname -s)" = "Linux" ]; then
  log "topology:   libvirt VMs on ${LIBVIRT_NET:-default} (the recommended setup)"
  log "cluster VM: ${CLUSTER_VM} (${CLUSTER_CPUS}cpu/${CLUSTER_MEM_MIB:-6144}MiB) @ ${CLUSTER_NODE_ADDR}"
  log "edge VM:    ${EDGE_VM} (${EDGE_CPUS}cpu/${EDGE_MEM_MIB:-3072}MiB) @ ${EDGE_ADDR}"
  if command -v virsh >/dev/null 2>&1 && virsh -c qemu:///system list >/dev/null 2>&1; then
    virsh -c qemu:///system list --all
  else
    log "cannot reach qemu:///system — run 'just demo spiffe-cross-boundary host-setup', then log out and back in"
  fi
else
  log "topology:   Lima VMs (macOS fallback)"
  log "cluster VM: ${CLUSTER_VM} (${CLUSTER_CPUS}cpu/${CLUSTER_MEM}) @ ${CLUSTER_NODE_ADDR}"
  log "edge VM:    ${EDGE_VM} (${EDGE_CPUS}cpu/${EDGE_MEM}) @ ${EDGE_ADDR}"
  if command -v limactl >/dev/null 2>&1; then limactl list; else log "limactl not installed here"; fi
fi

# The dashboard URL cannot be derived from config: the port is a NodePort that
# Kubernetes allocates. So ask the cluster, with the same script Build it uses.
# Silent whenever the answer is not available yet -- no ssh config, cluster not
# reachable, app not deployed. This is a status line, not a check, and a demo
# half-built is the normal state for someone running status.
SSH_CONFIG="${DEMO_SSH_CONFIG:-$HOME/.ssh/linkerd-playground.conf}"
if [ -f "$SSH_CONFIG" ]; then
  dashboard="$(ssh -F "$SSH_CONFIG" -o ConnectTimeout=5 -o BatchMode=yes linkerd-cluster \
    'bash ~/linkerd-playground/demos/spiffe-cross-boundary/cluster/retail/url.sh' 2>/dev/null || true)"
  # An `if`, not `[ -n … ] && log …`: as the last statement under `set -e`, the
  # && form would make an absent URL the script's exit status.
  if [ -n "$dashboard" ]; then log "dashboard:  $dashboard"; fi
fi
