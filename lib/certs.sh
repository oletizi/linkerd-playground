#!/usr/bin/env bash
# Certificate helpers for Linkerd's mesh identity hierarchy: trust anchor (root CA)
# signs the identity issuer (intermediate CA). Source after lib/common.sh; do not
# execute. Runs inside a Debian/Ubuntu VM (ensure_step installs a .deb).

# ensure_step: install the smallstep CLI from its latest release if it is absent.
ensure_step() {
  command -v step >/dev/null 2>&1 && return 0
  local arch url
  arch="$(dpkg --print-architecture)"   # amd64 | arm64
  # Resolve the .deb URL from the release assets (names carry a Debian revision, e.g. _0.30.6-1_arm64.deb).
  url="$(curl -sSf https://api.github.com/repos/smallstep/cli/releases/latest \
    | jq -r --arg a "$arch" '.assets[] | select(.name | test("_" + $a + "\\.deb$")) | .browser_download_url' | head -1)"
  [ -n "$url" ] || die "could not resolve step-cli .deb for arch $arch"
  curl -sSLf "$url" -o /tmp/step.deb
  sudo dpkg -i /tmp/step.deb
}

# make_trust_anchor DIR LIFETIME: a self-signed root CA, DIR/ca.crt + DIR/ca.key.
# LIFETIME is step's --not-after syntax (e.g. 87600h, 720h). Never overwrites.
make_trust_anchor() {
  local dir="${1:?make_trust_anchor: DIR required}" lifetime="${2:?make_trust_anchor: LIFETIME required}"
  [ ! -e "$dir/ca.crt" ] || die "make_trust_anchor: $dir/ca.crt exists; refusing to overwrite a trust anchor"
  mkdir -p "$dir"
  step certificate create root.linkerd.cluster.local "$dir/ca.crt" "$dir/ca.key" \
    --profile root-ca --no-password --insecure --not-after="$lifetime"
}

# make_issuer DIR LIFETIME ANCHOR_DIR: an intermediate CA for Linkerd identity,
# DIR/issuer.crt + DIR/issuer.key, signed by ANCHOR_DIR/ca.crt + ca.key. Never overwrites.
make_issuer() {
  local dir="${1:?make_issuer: DIR required}" lifetime="${2:?make_issuer: LIFETIME required}"
  local anchor="${3:?make_issuer: ANCHOR_DIR required}"
  # die() always exits, so A && B || C here is not if-then-else risk.
  # shellcheck disable=SC2015
  [ -f "$anchor/ca.crt" ] && [ -f "$anchor/ca.key" ] || die "make_issuer: no trust anchor in $anchor"
  [ ! -e "$dir/issuer.crt" ] || die "make_issuer: $dir/issuer.crt exists; refusing to overwrite an issuer"
  mkdir -p "$dir"
  step certificate create identity.linkerd.cluster.local "$dir/issuer.crt" "$dir/issuer.key" \
    --profile intermediate-ca --not-after "$lifetime" --no-password --insecure \
    --ca "$anchor/ca.crt" --ca-key "$anchor/ca.key"
}
