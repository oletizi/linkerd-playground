#!/usr/bin/env bash
# Runs INSIDE the edge VM. Launches linkerd2-proxy; identity comes from SPIRE.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"

export LINKERD2_PROXY_IDENTITY_SERVER_ID="${EDGE_SPIFFE_ID}"
export LINKERD2_PROXY_IDENTITY_SERVER_NAME="${EDGE_SERVER_NAME}"
export LINKERD2_PROXY_POLICY_WORKLOAD="{\"ns\":\"${DEMO_NS}\", \"external_workload\":\"${EDGE_WORKLOAD_NAME}\"}"
export LINKERD2_PROXY_DESTINATION_CONTEXT="{\"ns\":\"${DEMO_NS}\", \"nodeName\":\"${EDGE_VM}\", \"external_workload\":\"${EDGE_WORKLOAD_NAME}\"}"
export LINKERD2_PROXY_DESTINATION_SVC_ADDR="linkerd-dst-headless.linkerd.svc.cluster.local.:8086"
export LINKERD2_PROXY_DESTINATION_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
export LINKERD2_PROXY_POLICY_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
export LINKERD2_PROXY_POLICY_SVC_ADDR="linkerd-policy.linkerd.svc.cluster.local.:8090"
export LINKERD2_PROXY_IDENTITY_SPIRE_SOCKET="unix:///tmp/spire-agent/public/api.sock"
LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"; export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS

sudo pkill -f '/opt/linkerd-proxy/linkerd-proxy' 2>/dev/null || true
# shellcheck disable=SC2024
sudo -E nohup /opt/linkerd-proxy/linkerd-proxy >/tmp/linkerd-proxy.log 2>&1 &
sleep 5
if grep -Eq 'obtained.*identity|SVID|certified|identity verified' /tmp/linkerd-proxy.log; then
  echo "proxy has identity"
else
  echo "proxy identity not confirmed in log — inspect /tmp/linkerd-proxy.log for the issued SVID:" >&2
  tail -n 40 /tmp/linkerd-proxy.log >&2
  exit 1
fi
