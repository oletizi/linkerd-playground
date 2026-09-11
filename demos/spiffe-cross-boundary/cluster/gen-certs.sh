#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Generates the Linkerd trust anchor (root) + issuer.
# ca.crt/ca.key are later copied to the edge as SPIRE's UpstreamAuthority.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/certs.sh"
DIR="${HOME}/linkerd-certs"

if [ ! -f "$DIR/ca.crt" ]; then
  ensure_step
  make_trust_anchor "$DIR" 87600h
  make_issuer "$DIR" 8760h "$DIR"
fi
step certificate inspect "$DIR/ca.crt" --short
