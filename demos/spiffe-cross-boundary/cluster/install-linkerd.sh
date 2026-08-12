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
# The installer drops the CLI in ~/.linkerd2/bin, which no shell has on its PATH
# -- not an interactive login, and not `ssh host '<command>'` either. Symlink it
# next to k3s's kubectl so the `linkerd ...` commands in the README work as
# written, however you reach the box.
sudo ln -sf "${HOME}/.linkerd2/bin/linkerd" /usr/local/bin/linkerd

# Linkerd requires the Gateway API CRDs to be present before install.
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

linkerd install --crds | kubectl apply -f -
linkerd install \
  --identity-trust-anchors-file "${CERTS}/ca.crt" \
  --identity-issuer-certificate-file "${CERTS}/issuer.crt" \
  --identity-issuer-key-file "${CERTS}/issuer.key" \
  | kubectl apply -f -
linkerd check
linkerd viz install | kubectl apply -f -
linkerd check
