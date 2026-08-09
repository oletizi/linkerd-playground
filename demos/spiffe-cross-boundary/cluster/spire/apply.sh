#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Deploys the in-cluster SPIRE server: the Linkerd root
# (ca.crt+ca.key) as a read-only Secret, server.cfg as a ConfigMap, the StatefulSet +
# NodePort Service, and the tailnet firewall on the NodePort. Then registers the
# workload entry, exports the trust bundle, and mints a one-time join token.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
CERTS="${HOME}/linkerd-certs"
[ -f "$CERTS/ca.key" ] || { echo "missing $CERTS/ca.key (run cluster/gen-certs.sh)" >&2; exit 1; }

kubectl apply -f "$HERE/spire-server.yaml"     # ns/spire, SA (automount off), StatefulSet, NodePort Service
kubectl -n spire create secret generic spire-upstream-ca \
  --from-file=ca.crt="$CERTS/ca.crt" --from-file=ca.key="$CERTS/ca.key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n spire create configmap spire-server-config \
  --from-file=server.cfg="$HERE/server.cfg" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n spire rollout status statefulset/spire-server --timeout=180s

bash "$HERE/firewall.sh"
echo "spire server ready; NodePort 30081 (tailnet only)"

# --- registration + bootstrap material (consumed by the edge agent) ---
SP="kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server"
AGENT="spiffe://root.linkerd.cluster.local/store/042/agent"
WL="spiffe://root.linkerd.cluster.local/store/042/inventory-sync"

if $SP entry show -spiffeID "$WL" 2>/dev/null | grep -q "$WL"; then
  echo "entry exists"
else
  $SP entry create -parentID "$AGENT" -spiffeID "$WL" \
    -selector unix:uid:2102 \
    -selector unix:path:/opt/linkerd-proxy/linkerd-proxy
fi

$SP bundle show > "$HOME/spire-bundle.pem"
echo "bundle -> $HOME/spire-bundle.pem ($(grep -c CERTIFICATE "$HOME/spire-bundle.pem") cert(s))"
echo "join token:"
$SP token generate -spiffeID "$AGENT"
