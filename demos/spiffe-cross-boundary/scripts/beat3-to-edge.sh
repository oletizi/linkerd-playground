#!/usr/bin/env bash
# Runs ON THE CLUSTER VM. Beat 3 (stretch): encrypted + authorized traffic TO the edge.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
kubectl apply -f "$HERE/cluster/authz-edge-server.yaml"
sleep 3
echo ">> in-cluster client -> edge-echo, expect 200 (allowed SA):"
kubectl -n mixed-env exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' -m 8 http://edge-echo.mixed-env.svc.cluster.local/
