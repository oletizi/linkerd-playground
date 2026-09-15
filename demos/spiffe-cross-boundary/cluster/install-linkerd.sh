#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Installs Linkerd rooted at our trust anchor + viz.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$HERE"
# shellcheck source=/dev/null
. "$ROOT/lib/linkerd.sh"
CERTS="${HOME}/linkerd-certs"

ensure_linkerd_cli "${LINKERD_EDGE_VERSION}"
install_gateway_crds v1.2.1
linkerd_install "${CERTS}/ca.crt" "${CERTS}/issuer.crt" "${CERTS}/issuer.key"
linkerd check
linkerd viz install | kubectl apply -f -
wait_rollouts linkerd-viz
linkerd check
