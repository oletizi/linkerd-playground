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
# Token sources, in order: argument, environment, then the file the host relay
# drops here (cluster/spire/apply.sh writes it; see the README's relay step). The
# file exists so the token does not have to be moved by eye.
TOKEN_FILE=/opt/spire/join-token
TOKEN="${1:-${SPIRE_JOIN_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  [ -n "$TOKEN" ] && log "using the join token relayed to $TOKEN_FILE"
fi
[ -n "$TOKEN" ] || die "no join token.
  Pass one as an argument, set SPIRE_JOIN_TOKEN, or relay $TOKEN_FILE from the
  cluster (cluster/spire/apply.sh writes it to ~/spire-join-token)."
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
# The agent opens its workload API socket BEFORE node attestation finishes, so a
# healthcheck on its own is not evidence of a working agent: with a spent join
# token it answers "healthy", keeps retrying attestation, and dies about 20s later
# -- by which time this script has already exited 0 and the reader has moved on.
# The next symptom is the proxy panicking with a missing socket, two steps away
# from the actual cause.
#
# So wait for a definite outcome: a failure signature in the log, the process
# going away, or the agent still alive and healthy past the retry interval.
SETTLE="${SPIRE_AGENT_SETTLE:-25}"
log "waiting up to ${SETTLE}s for the agent to attest (it must outlive its first attestation retry)"
deadline=$((SECONDS + SETTLE))
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -qE 'Agent crashed|join token does not exist or has already been used' /tmp/spire-agent.log 2>/dev/null; then
    die "the SPIRE agent failed to attest and exited:
$(grep -E 'level=(error|warning)' /tmp/spire-agent.log | tail -3)

  A join token is single-use. Get a fresh one by re-running cluster/spire/apply.sh
  on the cluster, relay it again, then re-run this script."
  fi
  pgrep -f 'spire-agent run' >/dev/null 2>&1 \
    || die "the SPIRE agent exited. Last lines of /tmp/spire-agent.log:
$(tail -5 /tmp/spire-agent.log 2>/dev/null)"
  sleep 1
done

sudo /opt/spire/bin/spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
log "agent attested and still running after ${SETTLE}s"
