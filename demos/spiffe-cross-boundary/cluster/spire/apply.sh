#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Deploys the in-cluster SPIRE server: the Linkerd root
# (ca.crt+ca.key) as a read-only Secret, server.cfg as a ConfigMap, the StatefulSet +
# NodePort Service, and a firewall on the NodePort. Then registers the workload
# entry, exports the trust bundle, and mints a one-time join token.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$DEMO/../.." && pwd)/lib/common.sh"; load_config "$DEMO"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
CERTS="${HOME}/linkerd-certs"

# firewall.sh restricts the SPIRE NodePort to the interface the edge box reaches
# this host on. Work it out from EDGE_ADDR unless the caller said otherwise, so
# the common case needs no configuration. Falls back to firewall.sh's own default.
if [ -z "${SPIRE_NODEPORT_IFACE:-}" ] && [ -z "${TAILSCALE_IFACE:-}" ] && [ "${EDGE_ADDR:-CHANGE_ME}" != "CHANGE_ME" ]; then
  SPIRE_NODEPORT_IFACE="$(ip -o route get "$EDGE_ADDR" 2>/dev/null | grep -oP 'dev \K\S+' || true)"
  [ -n "$SPIRE_NODEPORT_IFACE" ] && export SPIRE_NODEPORT_IFACE \
    && log "SPIRE NodePort will be restricted to $SPIRE_NODEPORT_IFACE (route to EDGE_ADDR=$EDGE_ADDR)"
fi
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
echo "spire server ready; NodePort ${SPIRE_SERVER_PORT}"

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
echo "bundle -> $HOME/spire-bundle.pem ($(grep -c 'BEGIN CERTIFICATE' "$HOME/spire-bundle.pem") cert(s))"

# The join token is bootstrap material exactly like the bundle, so give it a file
# too and let the same host-relay step carry it to the store. Printing it only to
# stdout made it the one thing a reader had to move by eye, which is easy to skip
# and easy to lose to scrollback.
$SP token generate -spiffeID "$AGENT" | awk '/Token:/ {print $2}' > "$HOME/spire-join-token"
chmod 600 "$HOME/spire-join-token"
[ -s "$HOME/spire-join-token" ] || die "spire-server issued no join token"
echo "join token -> $HOME/spire-join-token ($(cat "$HOME/spire-join-token"))"
