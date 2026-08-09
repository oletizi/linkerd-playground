#!/usr/bin/env bash
# Runs INSIDE the edge VM. Installs + starts the SPIRE AGENT only (no server, no root
# key). Requires the trust bundle at /opt/spire/certs/bundle.pem and a one-time join
# token (arg 1 or $SPIRE_JOIN_TOKEN), both produced by cluster/spire/apply.sh.
# The agent version is pinned to match the in-cluster server (avoids version skew).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../../.." && pwd)/lib/common.sh"; load_config "$(cd "$HERE/.." && pwd)"
ARCH="$(detect_arch)"
VER="${SPIRE_VERSION:-1.15.2}"
TOKEN="${1:-${SPIRE_JOIN_TOKEN:-}}"
[ -n "$TOKEN" ] || die "usage: install-spire-agent.sh <join-token>   (from cluster/spire/apply.sh)"
[ -f /opt/spire/certs/bundle.pem ] || die "copy the SPIRE bundle to /opt/spire/certs/bundle.pem first"
[ ! -e /opt/spire/certs/ca.key ] || die "refuse to run: ca.key must not be on the edge (remove it)"

# (Re)install the agent binary if missing or version-mismatched with the server.
have=""; [ -x /opt/spire/bin/spire-agent ] && have="$(/opt/spire/bin/spire-agent --version 2>&1 | tr -d v)"
if [ "$have" != "$VER" ]; then
  curl -sSLf "https://github.com/spiffe/spire/releases/download/v${VER}/spire-${VER}-linux-${ARCH}-musl.tar.gz" -o /tmp/spire.tgz
  sudo mkdir -p /opt/spire/bin /opt/spire/data/agent
  tar -xzf /tmp/spire.tgz -C /tmp
  sudo cp "/tmp/spire-${VER}/bin/spire-agent" /opt/spire/bin/
fi

# Render agent.cfg with the cluster server address/port (no sed; bash param expansion).
render() { while IFS= read -r line; do line="${line/__SERVER_ADDR__/$CLUSTER_NODE_ADDR}"; echo "${line/__SERVER_PORT__/$SPIRE_SERVER_PORT}"; done < "$HERE/spire/agent.cfg"; }
render | sudo tee /opt/spire/agent.cfg >/dev/null

sudo pkill -f 'spire-agent run' 2>/dev/null || true
# Enrollment uses a fresh single-use token, so start from a clean keystore — a node
# SVID persisted from a previous (or different) server would be reused instead of
# re-attesting, and the new server would reject it.
sudo rm -rf /opt/spire/data/agent && sudo mkdir -p /opt/spire/data/agent
# shellcheck disable=SC2024
sudo setsid /opt/spire/bin/spire-agent run -config /opt/spire/agent.cfg -joinToken "$TOKEN" \
  >/tmp/spire-agent.log 2>&1 </dev/null &
sleep 4
sudo /opt/spire/bin/spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
