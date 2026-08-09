#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Restricts the SPIRE NodePort (30081) to the Tailscale
# interface, so the identity-control-plane listener is not exposed on other node
# interfaces. This is defense in depth; the pinned bundle + join token + server cert
# chain are the actual authentication. mangle/PREROUTING runs before kube-proxy's
# nat DNAT, so the drop applies to the original :30081 dest before it is rewritten.
set -euo pipefail
IFACE="${TAILSCALE_IFACE:-tailscale0}"
ip link show "$IFACE" >/dev/null 2>&1 || { echo "no $IFACE interface on this host" >&2; exit 1; }
if sudo iptables -t mangle -C PREROUTING -p tcp --dport 30081 ! -i "$IFACE" -j DROP 2>/dev/null; then
  echo "spire nodeport firewall already present"
else
  sudo iptables -t mangle -A PREROUTING -p tcp --dport 30081 ! -i "$IFACE" -j DROP
  echo "spire nodeport restricted to $IFACE"
fi
sudo iptables -t mangle -L PREROUTING -n | grep 30081
