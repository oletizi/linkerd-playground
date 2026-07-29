#!/usr/bin/env bash
# Runs INSIDE the edge VM. Extracts the linkerd2-proxy binary from the image.
# Version MUST match the installed control plane (LINKERD_EDGE_VERSION).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
if [ ! -x /opt/linkerd-proxy/linkerd-proxy ]; then
  sudo mkdir -p /opt/linkerd-proxy
  id=$(sudo docker create "cr.l5d.io/linkerd/proxy:${LINKERD_EDGE_VERSION}")
  sudo docker cp "$id:/usr/lib/linkerd/linkerd2-proxy" /opt/linkerd-proxy/linkerd-proxy
  sudo docker rm -v "$id"
fi
/opt/linkerd-proxy/linkerd-proxy --version || true
