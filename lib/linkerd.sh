#!/usr/bin/env bash
# Linkerd install helpers. Source after lib/common.sh; do not execute. Runs inside the VM.

# ensure_linkerd_cli VERSION: install the edge CLI at VERSION when no linkerd is on
# PATH, then make it reachable however the box is entered.
ensure_linkerd_cli() {
  local version="${1:?ensure_linkerd_cli: VERSION required}"
  if ! command -v linkerd >/dev/null 2>&1; then
    curl -sL https://run.linkerd.io/install-edge | LINKERD2_VERSION="${version}" sh
  fi
  export PATH="${HOME}/.linkerd2/bin:${PATH}"
  # The installer drops the CLI in ~/.linkerd2/bin, which no shell has on its PATH
  # -- not an interactive login, and not `ssh host '<command>'` either. Symlink it
  # next to k3s's kubectl so `linkerd ...` works as written, however you reach the box.
  sudo ln -sf "${HOME}/.linkerd2/bin/linkerd" /usr/local/bin/linkerd
}

# install_gateway_crds VERSION: Linkerd requires the Gateway API CRDs before install.
install_gateway_crds() {
  local version="${1:?install_gateway_crds: VERSION required}"
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${version}/standard-install.yaml"
}

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

# linkerd_install ANCHOR ISSUER_CRT ISSUER_KEY [linkerd install flags...]: install the
# CRDs and the control plane rooted at the given trust anchor and issuer, then wait
# for the rollouts. Runs no `linkerd check`: callers choose when to check and where
# its output goes.
linkerd_install() {
  local anchor="${1:?linkerd_install: ANCHOR required}" crt="${2:?linkerd_install: ISSUER_CRT required}"
  local key="${3:?linkerd_install: ISSUER_KEY required}"
  shift 3
  linkerd install --crds | kubectl apply -f -
  linkerd install \
    --identity-trust-anchors-file "$anchor" \
    --identity-issuer-certificate-file "$crt" \
    --identity-issuer-key-file "$key" \
    "$@" \
    | kubectl apply -f -
  wait_rollouts linkerd
}

# linkerd_viz_install [linkerd viz install flags...]: install Viz into the linkerd-viz
# namespace and wait for its rollouts. The control plane must already be installed and
# serving -- Viz's own pods are meshed, so this runs after linkerd_install, never before.
linkerd_viz_install() {
  linkerd viz install "$@" | kubectl apply -f -
  wait_rollouts linkerd-viz
}
