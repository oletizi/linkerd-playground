#!/usr/bin/env bash
# Runs INSIDE the edge VM. Redirects inbound->4143 / outbound->4140 through the proxy.
set -euo pipefail
PROXY_INBOUND_PORT=4143
PROXY_OUTBOUND_PORT=4140
PROXY_USER_UID=$(id -u root)
INBOUND_PORTS_TO_IGNORE="4190,4191,4567,4568"
OUTBOUND_PORTS_TO_IGNORE="4567,4568"

if sudo iptables -t nat -n -L PROXY_INIT_REDIRECT >/dev/null 2>&1; then echo "iptables already configured"; exit 0; fi

sudo iptables -t nat -N PROXY_INIT_REDIRECT
sudo iptables -t nat -A PROXY_INIT_REDIRECT -p tcp --match multiport --dports "$INBOUND_PORTS_TO_IGNORE" -j RETURN
sudo iptables -t nat -A PROXY_INIT_REDIRECT -p tcp -j REDIRECT --to-port "$PROXY_INBOUND_PORT"
sudo iptables -t nat -A PREROUTING -j PROXY_INIT_REDIRECT

sudo iptables -t nat -N PROXY_INIT_OUTPUT
sudo iptables -t nat -A PROXY_INIT_OUTPUT -m owner --uid-owner "$PROXY_USER_UID" -j RETURN
sudo iptables -t nat -A PROXY_INIT_OUTPUT -o lo -j RETURN
sudo iptables -t nat -A PROXY_INIT_OUTPUT -p tcp --match multiport --dports "$OUTBOUND_PORTS_TO_IGNORE" -j RETURN
sudo iptables -t nat -A PROXY_INIT_OUTPUT -p tcp -j REDIRECT --to-port "$PROXY_OUTBOUND_PORT"
sudo iptables -t nat -A OUTPUT -j PROXY_INIT_OUTPUT
sudo iptables-save -t nat
