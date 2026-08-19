#!/usr/bin/env bash
# Shared helpers for all demos. Source this; do not execute.
set -euo pipefail

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(basename "${0}")" "$*" >&2; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

# ubuntu_cloud_image_url <arch> [release]: the cloud image for a demo arch
# (amd64 | arm64, as detect_arch reports them).
ubuntu_cloud_image_url() {
  local arch="$1" rel="${2:-24.04}"
  [ -n "$arch" ] || die "ubuntu_cloud_image_url: arch required"
  echo "https://cloud-images.ubuntu.com/releases/${rel}/release/ubuntu-${rel}-server-cloudimg-${arch}.img"
}

# image_url_arch <url>: the arch a cloud-image URL names -- amd64 | arm64 |
# unknown. 'unknown' means the name carries no arch, not that it is invalid.
image_url_arch() {
  local url="$1"
  [ -n "$url" ] || die "image_url_arch: url required"
  case "$url" in
    *amd64*|*x86_64*) echo amd64 ;;
    *arm64*|*aarch64*) echo arm64 ;;
    *) echo unknown ;;
  esac
}

# require_matching_image_arch <url> <host-arch>: refuse a guest image whose
# architecture differs from the host's. Such a guest has no KVM to run on, so the
# hypervisor emulates it -- not an error, just unusably slow, and slow is easy to
# misread as "this demo is broken". An image whose name carries no arch cannot be
# checked, so it warns and proceeds.
#
# Reports the mismatch and RETURNS 1 rather than calling die: callers source this
# from the top level of another script, and bash emits 'pop_var_context: head of
# shell_variables not a function context' when a function holding `local`s exits
# during a source. Callers pair it with `|| exit 1`.
require_matching_image_arch() {
  local url="$1" host="$2" img
  img="$(image_url_arch "$url")"
  case "$img" in
    "$host") return 0 ;;
    unknown)
      log "warning: cannot tell the architecture of the guest image; proceeding,
  but it must be $host to run at native speed on this host:
    $url"
      return 0 ;;
    *)
      err "guest image is $img but this host is ${host}:
    $url
  A guest of a different architecture cannot use KVM; it would be emulated, and
  the demo becomes unusably slow rather than failing outright. Unset VM_IMAGE_URL
  to use the $host image, or point it at one built for $host."
      return 1 ;;
  esac
}

# load_config <demo-dir>: sources config.example.env then config.local.env (override).
load_config() {
  local dir="$1"
  [ -f "$dir/config.example.env" ] || die "no config.example.env in $dir"
  set -a
  # shellcheck source=/dev/null
  . "$dir/config.example.env"
  if [ -f "$dir/config.local.env" ]; then
    # shellcheck source=/dev/null
    . "$dir/config.local.env"
  fi
  set +a
}
