#!/usr/bin/env bash
# In-VM environment for the cert-hygiene lab scripts. Source; do not execute.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$LAB_DIR/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
load_config "$DEMO"
# shellcheck source=/dev/null
. "$ROOT/lib/certs.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/k3s.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/linkerd.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/lib-evidence.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/lib-webhook.sh"

# load_profile PROFILE: export the credential profile lab/profiles/PROFILE.env
# (design section 1.1) and PROFILE itself. Dies on an unknown profile or a missing key.
load_profile() {
  local p="${1:?load_profile: PROFILE required}" f v
  f="$LAB_DIR/profiles/$p.env"
  [ -f "$f" ] || die "no credential profile '$p' (expected $f)"
  set -a
  # shellcheck source=/dev/null
  . "$f"
  set +a
  # Both loops ask the FILE, not the environment. Profiles are sourced with `set -a`,
  # so a value left over from an earlier load_profile call — or exported by whatever
  # ran before this script — would satisfy a bare `[ -n "$v" ]` and let a profile that
  # never defines the key through, silently running on someone else's lifetime.
  for v in ANCHOR_LIFETIME ISSUER_LIFETIME LEAF_LIFETIME; do
    grep -q "^$v=" "$f" || die "$f does not set $v"
    [ -n "${!v:-}" ] || die "$f sets $v empty; it needs a duration"
  done
  for v in WEBHOOK_CERT_LIFETIMES EXTRA_INSTALL_FLAGS TAP_CERT_LIFETIME; do
    grep -q "^$v=" "$f" || die "$f does not define $v (define it empty when unused)"
  done
  PROFILE="$p"
  export PROFILE
}

# Lab keys live here, inside the VM, never under the repo (which is a Mac path).
# Used by every script that sources this file (reset.sh and later tasks), not by this
# file itself.
# shellcheck disable=SC2034
CERTS_ROOT="$HOME/cert-hygiene-certs"
export PATH="$HOME/.linkerd2/bin:$PATH"

# require_pinned_images: the probe images must be pinned by digest (Task 5 Step 6).
require_pinned_images() {
  local v
  for v in IMAGE_CURL IMAGE_SOCAT IMAGE_BUSYBOX; do
    case "${!v:-}" in
      *@sha256:*) ;;
      *) die "$v is not pinned by digest in config.example.env; run lab/resolve-images.sh and paste its output" ;;
    esac
  done
}

# prepull_linkerd_images: pull every image the control plane uses. Renders the
# install manifest without lab certificates (the CLI then generates throwaway ones)
# purely to read its image list -- nothing is applied.
prepull_linkerd_images() {
  local manifest images img
  # set -euo pipefail does not catch a failure inside a command substitution used as
  # a for loop's word-list, so capture and check the manifest explicitly first.
  manifest="$(linkerd install)" || die "could not render the Linkerd install manifest to list its images"
  images="$(printf '%s\n' "$manifest" \
      | awk '{ for (i = 1; i < NF; i++) if ($i == "image:") print $(i + 1) }' \
      | tr -d '"' | sort -u)"
  [ -n "$images" ] || die "no images found in the Linkerd install manifest"
  for img in $images; do
    log "pulling $img"
    sudo k3s crictl pull "$img" >/dev/null
  done
}

# prepull_workload_images: pull the pinned probe and workload images.
prepull_workload_images() {
  local img
  require_pinned_images
  for img in "$IMAGE_CURL" "$IMAGE_SOCAT" "$IMAGE_BUSYBOX"; do
    log "pulling $img"
    sudo k3s crictl pull "$img" >/dev/null
  done
}
