#!/usr/bin/env bash
# Runs INSIDE the lab VM, with k3s running. Pulls each probe image by tag and prints
# the config line that pins it to the digest just pulled (the multi-arch index digest
# containerd records for a by-tag pull). Paste the output into config.example.env.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
command -v k3s >/dev/null 2>&1 || die "k3s is not installed; run reset_k3s first"

for pair in \
    IMAGE_CURL=docker.io/curlimages/curl:latest \
    IMAGE_SOCAT=docker.io/alpine/socat:latest \
    IMAGE_BUSYBOX=docker.io/library/busybox:latest; do
  var="${pair%%=*}"; ref="${pair#*=}"
  sudo k3s crictl pull "$ref" >/dev/null
  digest="$(sudo k3s crictl inspecti -o json "$ref" | jq -r '.status.repoDigests[0]')"
  # die() always exits, so A && B || C here is not if-then-else risk.
  # shellcheck disable=SC2015
  [ -n "$digest" ] && [ "$digest" != null ] || die "no repo digest recorded for $ref"
  printf '%s=%s   # pinned from %s on %s\n' "$var" "$digest" "$ref" "$(date -u +%Y-%m-%d)"
done
