#!/usr/bin/env bash
# Runs INSIDE the edge VM. The ONLY networking the playground performs.
# Assumes CLUSTER_NODE_ADDR is already reachable by whatever means you run (LAN/VPN/overlay).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
[ "$CLUSTER_NODE_ADDR" != "CHANGE_ME" ] || die "set CLUSTER_NODE_ADDR in config.local.env"

ping -c1 -W2 "$CLUSTER_NODE_ADDR" >/dev/null || die "cluster node $CLUSTER_NODE_ADDR not reachable — fix your base network first"

# Route the cluster pod + service CIDRs to the cluster node.
for cidr in "$POD_CIDR" "$SVC_CIDR"; do
  sudo ip route replace "$cidr" via "$CLUSTER_NODE_ADDR"
done

# Resolve *.cluster.local via CoreDNS (Ubuntu 24.04 uses systemd-resolved).
sudo mkdir -p /etc/systemd/resolved.conf.d
{ echo '[Resolve]'; echo "DNS=${COREDNS_ADDR}"; echo 'Domains=~cluster.local'; } \
  | sudo tee /etc/systemd/resolved.conf.d/cluster.conf >/dev/null
sudo systemctl restart systemd-resolved

log "route + cluster DNS shim applied (pod=${POD_CIDR} svc=${SVC_CIDR} dns=${COREDNS_ADDR})"
