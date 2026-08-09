#!/usr/bin/env bash
# Runs INSIDE the edge VM. App-scoped redirect: only the store-pos app's uid (1000)
# has its outbound TCP sent to the Linkerd proxy (outbound port 4140). Everything else
# on the host — the SPIRE agent, DNS, SSH, the proxy's own egress — is untouched.
# Invariant:  app uid 1000 -> proxy ;  all other host traffic -> normal networking.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
APP_UID="${APP_UID:-1000}"
PROXY_OUTBOUND_PORT=4140

if sudo iptables -t nat -n -L PROXY_APP_OUTPUT >/dev/null 2>&1; then echo "iptables already configured"; exit 0; fi
sudo iptables -t nat -N PROXY_APP_OUTPUT
sudo iptables -t nat -A PROXY_APP_OUTPUT -o lo -j RETURN
sudo iptables -t nat -A PROXY_APP_OUTPUT -p tcp -j REDIRECT --to-port "$PROXY_OUTBOUND_PORT"
sudo iptables -t nat -A OUTPUT -m owner --uid-owner "$APP_UID" -p tcp -j PROXY_APP_OUTPUT
echo "app-scoped redirect installed (uid $APP_UID -> :$PROXY_OUTBOUND_PORT)"
sudo iptables-save -t nat | grep -E 'PROXY_APP_OUTPUT|--uid-owner'
