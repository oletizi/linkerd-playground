#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Generates the Linkerd trust anchor (root) + issuer.
# ca.crt/ca.key are later copied to the edge as SPIRE's UpstreamAuthority.
set -euo pipefail
DIR="${HOME}/linkerd-certs"
mkdir -p "$DIR"; cd "$DIR"

install_step() {
  command -v step >/dev/null 2>&1 && return 0
  local arch url
  arch="$(dpkg --print-architecture)"   # amd64 | arm64
  # Resolve the .deb URL from the release assets (names carry a Debian revision, e.g. _0.30.6-1_arm64.deb).
  url="$(curl -sSf https://api.github.com/repos/smallstep/cli/releases/latest \
    | jq -r --arg a "$arch" '.assets[] | select(.name | test("_" + $a + "\\.deb$")) | .browser_download_url' | head -1)"
  [ -n "$url" ] || { echo "could not resolve step-cli .deb for arch $arch" >&2; exit 1; }
  curl -sSLf "$url" -o /tmp/step.deb
  sudo dpkg -i /tmp/step.deb
}

if [ ! -f ca.crt ]; then
  install_step
  step certificate create root.linkerd.cluster.local ca.crt ca.key \
    --profile root-ca --no-password --insecure --not-after=87600h
  step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
    --profile intermediate-ca --not-after 8760h --no-password --insecure \
    --ca ca.crt --ca-key ca.key
fi
step certificate inspect ca.crt --short
