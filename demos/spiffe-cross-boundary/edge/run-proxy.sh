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
export LINKERD2_PROXY_IDENTITY_SPIRE_WORKLOAD_API_ADDRESS="unix:///tmp/spire-agent/public/api.sock"
LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"; export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS

# The proxy takes its identity from the SPIRE agent's workload API socket. Without
# it the proxy does not fail gracefully -- it panics in its spire-client with a
# Rust stack trace and a bare "NotFound" on the socket path, which reads as a proxy
# bug rather than a missing prerequisite. Check for the socket up front and say so.
SPIRE_SOCK="${LINKERD2_PROXY_IDENTITY_SPIRE_WORKLOAD_API_ADDRESS#unix://}"
if [ ! -S "$SPIRE_SOCK" ]; then
  die "no SPIRE agent: the workload API socket $SPIRE_SOCK does not exist.
  The proxy gets its identity there and cannot start without it.
  Run edge/install-spire-agent.sh (Build it step 4) before this script. If you
  already did, the agent has since exited -- check /tmp/spire-agent.log."
fi

# Ensure the dedicated non-root proxy user exists (idempotent).
id -u linkerd-proxy >/dev/null 2>&1 || sudo useradd -r -u "${PROXY_UID:-2102}" -s /usr/sbin/nologin linkerd-proxy

sudo pkill -f '/opt/linkerd-proxy/linkerd-proxy' 2>/dev/null || true
sudo rm -f /tmp/linkerd-proxy.log
# Run the proxy as the dedicated non-root uid. setpriv (unlike sudo) does not scrub the
# exported LINKERD2_PROXY_* env; sudo -E already preserves it on this host.
# shellcheck disable=SC2024
sudo -E setsid setpriv --reuid="${PROXY_UID:-2102}" --regid="${PROXY_UID:-2102}" --clear-groups \
  /opt/linkerd-proxy/linkerd-proxy >/tmp/linkerd-proxy.log 2>&1 </dev/null &
# Poll rather than sleeping a fixed time: certification takes as long as it takes,
# and a fixed wait either reports failure on a slow-but-fine start or passes before
# there is anything to see.
for _ in $(seq 1 15); do
  grep -Eqi 'certified identity|obtained.*identity|SVID' /tmp/linkerd-proxy.log 2>/dev/null && break
  grep -q 'spire client must gracefully handle errors' /tmp/linkerd-proxy.log 2>/dev/null && break
  sleep 1
done

if grep -Eqi 'certified identity|obtained.*identity|SVID' /tmp/linkerd-proxy.log; then
  echo "proxy has identity (uid $(id -u linkerd-proxy))"

  # The proxy having an identity is not the demo working: store-pos pushes on its
  # own interval and its first attempts can still fail while the proxy finishes
  # wiring up. Ending here leaves the reader to guess whether a quiet terminal
  # means success or a stall, so watch until the store actually pushes -- printing
  # a timestamped line each poll, so slow is visibly different from hung.
  if sudo docker inspect store-pos >/dev/null 2>&1; then
    WAIT="${PUSH_WAIT:-90}"
    log "watching store-pos for its first successful push (it retries every ~2s, give it up to ${WAIT}s)"
    deadline=$((SECONDS + WAIT))
    while [ "$SECONDS" -lt "$deadline" ]; do
      line="$(sudo docker logs --tail 1 store-pos 2>/dev/null | tr -d '\r' | tail -1)"
      printf '  [%s] %s\n' "$(date +%H:%M:%S)" "${line:-(no output yet)}"
      case "$line" in
        *'push -> 2'*)
          log "the store is pushing over the mesh — the demo is live."
          log "dashboard: http://${CLUSTER_NODE_ADDR}:30080/"
          exit 0 ;;
      esac
      sleep 3
    done
    die "the store never completed a push in ${WAIT}s (last line above).
  The proxy has its identity, so the remaining suspects are on the cluster side:
  check that step 5's cluster/retail/apply.sh ran, and 'sudo docker logs store-pos'
  for what it is getting back."
  else
    log "store-pos is not running here — start it with store-pos/run-store-pos.sh (step 4)"
  fi
elif grep -q 'spire client must gracefully handle errors' /tmp/linkerd-proxy.log; then
  # The panic names a socket, not a cause. Translate it.
  die "the proxy could not reach the SPIRE agent at $SPIRE_SOCK and panicked.
  The socket existed when this script started, so the agent has exited since --
  a join token is single-use, and an agent given a spent one dies seconds after
  reporting healthy. Check /tmp/spire-agent.log, then re-run
  cluster/spire/apply.sh for a fresh token, relay it, and run
  edge/install-spire-agent.sh again."
else
  die "the proxy started but never reported an identity. Last of /tmp/linkerd-proxy.log:
$(tail -n 20 /tmp/linkerd-proxy.log)"
fi
