#!/usr/bin/env bash
# Runs ON THE CLUSTER VM. Beat 2: identity-based authz on the in-cluster echo Server.
# The test calls originate FROM THE EDGE VM (this script applies policy + prints the commands).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"

EDGE_CALL="curl -s -o /dev/null -w '%{http_code}\\n' -m 8 http://echo.mixed-env.svc.cluster.local/"

echo "== applying default-deny Server + allow-edge policy =="
kubectl apply -f "$HERE/cluster/authz.yaml"
sleep 3
echo ">> From the EDGE VM, expect 200:"
echo "   $EDGE_CALL"

echo "== flipping allowed identity to a different SPIFFE ID =="
kubectl apply -f "$HERE/cluster/authz-deny.yaml"
sleep 3
echo ">> From the EDGE VM, expect 403 (same network, only identity changed):"
echo "   $EDGE_CALL"

echo "== restoring allow-edge =="
kubectl apply -f "$HERE/cluster/authz.yaml"

echo
echo "NOTE: if 200 does not become 403, the server may report a different client identity string."
echo "      Confirm it with:  linkerd -n mixed-env viz tap deploy/echo | grep -m1 client_id"
echo "      then set MeshTLSAuthentication .spec.identities to that exact value in cluster/authz.yaml."
