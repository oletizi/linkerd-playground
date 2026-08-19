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

# `linkerd check` polls in silence while images pull and pods become ready. On a
# first run that is minutes of a blank terminal, which reads as a hang -- the
# information exists (pods coming up, images pulling), it just never reaches the
# screen. `rollout status` prints a line per deployment as it progresses, so the
# wait is visible before `check` starts its quiet polling.
#
# Informational only: a rollout that does not finish in time does NOT stop the
# script. `linkerd check` runs next and is the authority on whether the install is
# good -- it diagnoses *what* is wrong, where a bare rollout timeout would only
# say that something took too long.
wait_rollouts() { # namespace
  local ns="$1" d
  log "waiting for $ns workloads to become ready (this is where the install spends its time)"
  for d in $(kubectl -n "$ns" get deploy -o name 2>/dev/null); do
    kubectl -n "$ns" rollout status "$d" --timeout="${ROLLOUT_TIMEOUT:-10m}" \
      || log "warning: $d is not ready yet; continuing to 'linkerd check' for the real diagnosis"
  done
}

linkerd install --crds | kubectl apply -f -
linkerd install \
  --identity-trust-anchors-file "${CERTS}/ca.crt" \
  --identity-issuer-certificate-file "${CERTS}/issuer.crt" \
  --identity-issuer-key-file "${CERTS}/issuer.key" \
  | kubectl apply -f -
wait_rollouts linkerd
linkerd check
linkerd viz install | kubectl apply -f -
wait_rollouts linkerd-viz
linkerd check
