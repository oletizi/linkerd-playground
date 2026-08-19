#!/usr/bin/env bash
# Runs INSIDE the edge VM. Extracts the linkerd2-proxy binary from the image.
# Version MUST match the installed control plane (LINKERD_EDGE_VERSION).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
if [ ! -x /opt/linkerd-proxy/linkerd-proxy ]; then
  sudo mkdir -p /opt/linkerd-proxy
  id=$(sudo docker create "cr.l5d.io/linkerd/proxy:${LINKERD_EDGE_VERSION}")
  sudo docker cp "$id:/usr/lib/linkerd/linkerd2-proxy" /opt/linkerd-proxy/linkerd-proxy
  sudo docker rm -v "$id"
fi
# Confirm the binary runs and report its release -- this script exists to keep the
# proxy in step with the control plane, so an unconfirmed version is a failure.
#
# The standalone proxy has no --version flag. It logs its release banner, then
# exits non-zero with "Invalid configuration: no destination service configured",
# because a real launch needs the environment edge/run-proxy.sh supplies. That is
# the expected outcome here, so read the release out of the banner and say so,
# rather than letting an error scroll past as though the extraction had failed.
out="$(timeout 30 /opt/linkerd-proxy/linkerd-proxy --version 2>&1 || true)"
release="$(printf '%s\n' "$out" \
  | awk '/linkerd2_proxy: release/ {for (i = 1; i <= NF; i++) if ($i == "release") { print $(i+1); exit }}')"

[ -n "$release" ] || die "the extracted proxy did not report a release, so its version cannot be
  matched against the control plane (${LINKERD_EDGE_VERSION}). Output was:
$out"

log "proxy ready: /opt/linkerd-proxy/linkerd-proxy (release $release, image ${LINKERD_EDGE_VERSION})"
log "it exits on its own here — that is expected, this was only a version check.
  edge/run-proxy.sh starts it with the identity and destination config it needs."
