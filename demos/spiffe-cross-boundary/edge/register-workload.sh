#!/usr/bin/env bash
# Runs INSIDE the edge VM. Registers the proxy process (uid) -> EDGE_SPIFFE_ID.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
UID_PROXY="$(id -u root)"
if ! sudo /opt/spire/bin/spire-server entry show -spiffeID "$EDGE_SPIFFE_ID" | grep -q "$EDGE_SPIFFE_ID"; then
  sudo /opt/spire/bin/spire-server entry create \
    -parentID spiffe://root.linkerd.cluster.local/agent \
    -spiffeID "$EDGE_SPIFFE_ID" \
    -selector "unix:uid:${UID_PROXY}"
fi
sudo /opt/spire/bin/spire-server entry show -spiffeID "$EDGE_SPIFFE_ID"
