#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Deploys the RetailCloud demo: store-pos ExternalWorkload,
# the retail-cloud app (code via ConfigMap), and the authorization policy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$DEMO/../.." && pwd)/lib/common.sh"; load_config "$DEMO"
[ "$EDGE_ADDR" != "CHANGE_ME" ] || die "set EDGE_ADDR in config.local.env"
export PATH="${HOME}/.linkerd2/bin:${PATH}"

echo "== retail-cloud app code -> ConfigMap =="
kubectl -n mixed-env create configmap retail-cloud-app \
  --from-file=server.js="$DEMO/retail-cloud/server.js" \
  --from-file=index.html="$DEMO/retail-cloud/index.html" \
  --from-file=tutorial.html="$DEMO/retail-cloud/tutorial.html" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== clean up stale pull-model resources (if present) =="
kubectl -n mixed-env delete svc store-pos --ignore-not-found >/dev/null 2>&1 || true
kubectl -n mixed-env delete server store-pos-http --ignore-not-found >/dev/null 2>&1 || true
kubectl -n mixed-env delete authorizationpolicy store-pos-allow-cloud --ignore-not-found >/dev/null 2>&1 || true
kubectl -n mixed-env delete meshtlsauthentication allow-retail-cloud --ignore-not-found >/dev/null 2>&1 || true

echo "== store-pos ExternalWorkload (client identity; no fronting Service) =="
render() { while IFS= read -r line; do echo "${line/__EDGE_ADDR__/$EDGE_ADDR}"; done < "$HERE/store-pos.yaml"; }
render | kubectl apply -f -
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl -n mixed-env patch externalworkload store-pos --subresource=status --type=merge \
  -p "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"ManuallyReady\",\"message\":\"demo\",\"lastTransitionTime\":\"${NOW}\"}]}}"

echo "== retail-cloud app + authz =="
kubectl apply -f "$HERE/retail-cloud.yaml"
kubectl apply -f "$HERE/authz.yaml"
kubectl -n mixed-env rollout restart deploy/retail-cloud
kubectl -n mixed-env rollout status deploy/retail-cloud --timeout=120s

echo "== expose on the node (tailnet-reachable) =="
kubectl -n mixed-env delete svc retail-cloud-lan --ignore-not-found >/dev/null 2>&1
kubectl -n mixed-env expose deployment retail-cloud --name=retail-cloud-lan --type=NodePort --port=8080 --target-port=8080 >/dev/null
kubectl -n mixed-env patch svc retail-cloud-lan --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]' >/dev/null
NODEPORT=$(kubectl -n mixed-env get svc retail-cloud-lan -o jsonpath='{.spec.ports[0].nodePort}')
NODEIP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "NODEPORT=${NODEPORT}"
echo "cluster node IP: ${NODEIP}"
echo "open the dashboard at:  http://${CLUSTER_NODE_ADDR}:${NODEPORT}/"
