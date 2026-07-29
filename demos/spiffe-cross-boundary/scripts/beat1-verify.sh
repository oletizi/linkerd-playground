#!/usr/bin/env bash
# Runs ON THE CLUSTER VM. Beat 1: in-cluster client -> edge-echo (hosted on the VM), over mTLS.
set -euo pipefail
export PATH="${HOME}/.linkerd2/bin:${PATH}"
echo "== in-cluster client -> edge-echo (hosted on the VM) =="
kubectl -n mixed-env exec client -c client -- curl -s -m 5 http://edge-echo.mixed-env.svc.cluster.local/ | jq -r '.host.hostname'
echo "== tap: expect tls=true and server_id/dst = the edge SPIFFE identity =="
timeout 20 linkerd -n mixed-env viz tap deploy/client 2>/dev/null | grep -m1 -E 'tls=true' || true
linkerd -n mixed-env viz edges deployment 2>/dev/null || true
