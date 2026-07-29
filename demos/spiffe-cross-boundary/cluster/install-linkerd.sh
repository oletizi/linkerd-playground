#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Installs Linkerd rooted at our trust anchor + viz.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
CERTS="${HOME}/linkerd-certs"

if ! command -v linkerd >/dev/null 2>&1; then
  curl -sL https://run.linkerd.io/install-edge | LINKERD2_VERSION="${LINKERD_EDGE_VERSION}" sh
fi
export PATH="${HOME}/.linkerd2/bin:${PATH}"

linkerd install --crds | kubectl apply -f -
linkerd install \
  --identity-trust-anchors-file "${CERTS}/ca.crt" \
  --identity-issuer-certificate-file "${CERTS}/issuer.crt" \
  --identity-issuer-key-file "${CERTS}/issuer.key" \
  | kubectl apply -f -
linkerd check
linkerd viz install | kubectl apply -f -
linkerd check
