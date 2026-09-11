#!/usr/bin/env bash
# Runs INSIDE the lab VM. A fresh cluster with Linkerd rooted at freshly generated lab
# credentials. Usage: reset.sh <short|long> <cert-set-name>
#   short: ANCHOR_LIFETIME / ISSUER_LIFETIME (scenario #5: the issuer expires mid-run)
#   long:  CONTROL_ANCHOR_LIFETIME / CONTROL_ISSUER_LIFETIME (the negative control)
# Every image is pulled BEFORE the certificates are generated, so pulls never eat into
# a short issuer's lifetime.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"

mode="${1:?usage: reset.sh <short|long> <cert-set-name>}"
name="${2:?usage: reset.sh <short|long> <cert-set-name>}"
case "$mode" in
  short) anchor_life="$ANCHOR_LIFETIME"; issuer_life="$ISSUER_LIFETIME" ;;
  long)  anchor_life="$CONTROL_ANCHOR_LIFETIME"; issuer_life="$CONTROL_ISSUER_LIFETIME" ;;
  *) die "mode must be short or long, not '$mode'" ;;
esac
certs="$CERTS_ROOT/$name"
[ ! -e "$certs" ] || die "$certs already exists; every reset gets a new cert set"
require_pinned_images

reset_k3s
ensure_linkerd_cli "$LINKERD_EDGE_VERSION"
install_gateway_crds "$GATEWAY_API_VERSION"
linkerd install --crds | kubectl apply -f -
prepull_linkerd_images
prepull_workload_images

# The clock on a short issuer starts here.
ensure_step
make_trust_anchor "$certs" "$anchor_life"
make_issuer "$certs" "$issuer_life" "$certs"
linkerd_install "$certs/ca.crt" "$certs/issuer.crt" "$certs/issuer.key" \
  --identity-issuance-lifetime "$LEAF_LIFETIME"
log "reset complete: mode=$mode certs=$certs"
