#!/usr/bin/env bash
# Shared helpers for all demos. Source this; do not execute.
set -euo pipefail

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(basename "${0}")" "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

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
