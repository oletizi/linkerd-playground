#!/usr/bin/env bash
# Runs INSIDE the lab VM. Removes everything refactor-check.sh installed, so the next
# run (or the cert-hygiene lab itself) starts from the same clean machine: k3s, the
# Linkerd CLI, the step CLI package, and the SPIFFE demo's cert directory.
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  log "uninstalling k3s"
  sudo /usr/local/bin/k3s-uninstall.sh
fi
rm -rf "$HOME/linkerd-certs" "$HOME/.linkerd2" "$HOME/.kube"
sudo rm -f /usr/local/bin/linkerd
if dpkg -s step-cli >/dev/null 2>&1; then
  log "removing the step-cli package"
  sudo dpkg -r step-cli
fi

for leftover in /usr/local/bin/k3s /usr/local/bin/linkerd "$HOME/linkerd-certs"; do
  [ ! -e "$leftover" ] || die "cleanup left $leftover behind"
done
command -v step >/dev/null 2>&1 && die "cleanup left the step CLI installed"
log "lab VM is clean"
