#!/usr/bin/env bash
# Runs ON THE EDGE VM. Beat 1b: edge (as client) -> in-cluster echo, through the proxy outbound.
# Confirms the edge presents EDGE_SPIFFE_ID; read it on the cluster with:
#   linkerd -n mixed-env viz tap deploy/echo | grep -m1 client_id
set -euo pipefail
if curl -s -m 8 http://echo.mixed-env.svc.cluster.local/ | jq -r '.host.hostname'; then
  echo "edge -> in-cluster echo OK (mTLS via proxy outbound)"
else
  echo "outbound path failed — see FALLBACK in Task 17 (gate the other direction)" >&2
  exit 1
fi
