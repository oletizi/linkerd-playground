#!/usr/bin/env bash
# Runs INSIDE the lab VM. A fresh cluster with Linkerd rooted at freshly generated lab
# credentials shaped by a credential profile (lab/profiles/<profile>.env, design 1.1).
# Usage: reset.sh <profile> <cert-set-name>
# Every image is pulled BEFORE the certificates are generated, so pulls never eat into a
# short lifetime. When the profile sets WEBHOOK_CERT_LIFETIMES, the three webhook serving
# certificates are lab-supplied through --set-file instead of Linkerd-generated. When the
# profile sets TAP_CERT_LIFETIME, Viz is installed after the control plane is serving,
# with a lab-supplied tap serving certificate signed by the same lab webhook CA.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"

profile="${1:?usage: reset.sh <profile> <cert-set-name>}"
name="${2:?usage: reset.sh <profile> <cert-set-name>}"
load_profile "$profile"
certs="$CERTS_ROOT/$name"
[ ! -e "$certs" ] || die "$certs already exists; every reset gets a new cert set"
require_pinned_images

reset_k3s
ensure_linkerd_cli "$LINKERD_EDGE_VERSION"
install_gateway_crds "$GATEWAY_API_VERSION"
linkerd install --crds | kubectl apply -f -
prepull_linkerd_images
prepull_workload_images

# The clock on every short lifetime starts here.
ensure_step
make_trust_anchor "$certs" "$ANCHOR_LIFETIME"
make_issuer "$certs" "$ISSUER_LIFETIME" "$certs"
install_args=(--identity-issuance-lifetime "$LEAF_LIFETIME")
if [ -n "$WEBHOOK_CERT_LIFETIMES" ]; then
  make_webhook_certs "$certs/webhooks" "$WEBHOOK_CERT_LIFETIMES"
  mapfile -t webhook_args < <(webhook_install_args "$certs/webhooks")
  install_args+=("${webhook_args[@]}")
fi
read -r -a extra_args <<< "$EXTRA_INSTALL_FLAGS"
install_args+=("${extra_args[@]}")
linkerd_install "$certs/ca.crt" "$certs/issuer.crt" "$certs/issuer.key" "${install_args[@]}"

if [ -n "$TAP_CERT_LIFETIME" ]; then
  # The webhook CA may already exist (WEBHOOK_CERT_LIFETIMES set too); make_webhook_certs
  # also reuses it rather than dying on make_webhook_ca's overwrite guard.
  [ -f "$certs/webhooks/ca.crt" ] || make_webhook_ca "$certs/webhooks"
  make_tap_cert "$certs/webhooks" "$TAP_CERT_LIFETIME"
  mapfile -t tap_args < <(tap_install_args "$certs/webhooks")
  linkerd_viz_install "${tap_args[@]}"
fi
log "reset complete: profile=$profile certs=$certs"
