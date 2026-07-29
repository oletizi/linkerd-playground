#!/usr/bin/env bash
# Runs INSIDE the edge VM. Installs + starts SPIRE server and agent (both local).
# Requires /opt/spire/certs/{ca.crt,ca.key} (Linkerd trust anchor) copied over first.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../../.." && pwd)/lib/common.sh"
ARCH="$(detect_arch)"
[ -f /opt/spire/certs/ca.crt ] || die "copy ca.crt+ca.key to /opt/spire/certs first (see README)"

if [ ! -x /opt/spire/bin/spire-server ]; then
  VER="$(curl -sSf https://api.github.com/repos/spiffe/spire/releases/latest | jq -r .tag_name | tr -d v)"
  [ -n "$VER" ] && [ "$VER" != "null" ] || die "could not resolve SPIRE latest release"
  curl -sSLf "https://github.com/spiffe/spire/releases/download/v${VER}/spire-${VER}-linux-${ARCH}-musl.tar.gz" -o /tmp/spire.tgz
  sudo mkdir -p /opt/spire/bin /opt/spire/data/server /opt/spire/data/agent
  tar -xzf /tmp/spire.tgz -C /tmp
  sudo cp "/tmp/spire-${VER}"/bin/spire-server "/tmp/spire-${VER}"/bin/spire-agent /opt/spire/bin/
fi
sudo cp "$HERE/spire/server.cfg" "$HERE/spire/agent.cfg" /opt/spire/

# (Re)start server, detached so it survives this shell session.
sudo pkill -f 'spire-server run' 2>/dev/null || true
# Log to /tmp (user-writable); the user-side redirect is intentional. SC2024 N/A here.
# shellcheck disable=SC2024
sudo nohup /opt/spire/bin/spire-server run -config /opt/spire/server.cfg >/tmp/spire-server.log 2>&1 &
sleep 3

TOKEN="$(sudo /opt/spire/bin/spire-server token generate -spiffeID spiffe://root.linkerd.cluster.local/agent | awk '{print $2}')"
[ -n "$TOKEN" ] || die "failed to generate SPIRE join token"

sudo pkill -f 'spire-agent run' 2>/dev/null || true
# shellcheck disable=SC2024
sudo nohup /opt/spire/bin/spire-agent run -config /opt/spire/agent.cfg -joinToken "$TOKEN" >/tmp/spire-agent.log 2>&1 &
sleep 3

sudo /opt/spire/bin/spire-server healthcheck
sudo /opt/spire/bin/spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
