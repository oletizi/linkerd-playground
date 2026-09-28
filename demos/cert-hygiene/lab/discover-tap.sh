#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a lab just reset with the tap-long profile
# (lab-supplied tap certificate) and with baseline workloads deployed. Records whether
# Linkerd serves the lab-supplied tap certificate and whether tap works while it is
# valid: the tap Secret's certificate against the supplied one, the SAN this lab signs
# against the Service the tap APIService actually names, the v1alpha1.tap.linkerd.io
# APIService's Available condition, linkerd viz check, and a short linkerd viz tap
# capture while baseline traffic runs. Usage: discover-tap.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
out="${1:?usage: discover-tap.sh <out-dir>}"
[ ! -e "$out" ] || die "$out exists; refusing to overwrite"
# shellcheck disable=SC2012
certs="$(ls -dt "$CERTS_ROOT"/*/ | head -n 1)"
[ -f "$certs/webhooks/tap.crt" ] || die "newest cert set $certs has no webhooks/tap.crt; reset with tap-long first"
mkdir -p "$out"

fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; } # PEM on stdin
yn() { if [ "$1" = "$2" ]; then echo yes; else echo no; fi; }    # A B: yes when equal

# The Service the tap APIService actually points at, checked against the SAN
# make_tap_cert signs (tap.linkerd-viz.svc) before trusting that name.
apisvc_name="$(kubectl get apiservice v1alpha1.tap.linkerd.io -o jsonpath='{.spec.service.name}' 2>/dev/null || true)"
apisvc_ns="$(kubectl get apiservice v1alpha1.tap.linkerd.io -o jsonpath='{.spec.service.namespace}' 2>/dev/null || true)"
apisvc_fqdn="${apisvc_name:-<none>}.${apisvc_ns:-<none>}.svc"
tap_san="$(openssl x509 -noout -ext subjectAltName -in "$certs/webhooks/tap.crt" | tail -n 1 | tr -d ' ' | sed 's/DNS://')"

linkerd viz check > "$out/check.txt" 2>&1 || true

supplied="$(fp < "$certs/webhooks/tap.crt")"
served="$(kubectl -n linkerd-viz get secret tap-k8s-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | fp)"
# Fingerprint, not raw bytes: the caBundle loses the PEM's trailing newline in the
# Helm/API round trip, so a byte comparison reports a mismatch for the same certificate.
bundle="$(kubectl get apiservice v1alpha1.tap.linkerd.io -o jsonpath='{.spec.caBundle}' 2>/dev/null | base64 -d | fp)"
ca="$(fp < "$certs/webhooks/ca.crt")"
available="$(kubectl get apiservice v1alpha1.tap.linkerd.io -o jsonpath="{.status.conditions[?(@.type=='Available')].status}" 2>/dev/null || true)"

{
  printf 'cert_set=%s\n' "$certs"
  printf 'apiservice_backing_service=%s\n' "$apisvc_fqdn"
  printf 'tap_cert_san=%s\n' "$tap_san"
  printf 'san_matches_apiservice_service=%s\n' "$(yn "$tap_san" "$apisvc_fqdn")"
  printf 'secret_matches_supplied=%s\n' "$(yn "$supplied" "$served")"
  printf 'cabundle_matches_supplied_ca=%s\n' "$(yn "$bundle" "$ca")"
  printf 'apiservice_available=%s\n' "${available:-unknown}"
} > "$out/summary.txt"

grep -E 'tap API (service|server) has valid cert|tap api service|Linkerd-Viz' "$out/check.txt" >> "$out/summary.txt" || true

# A couple of tap events while baseline traffic runs. `linkerd viz tap` has no
# --timeout flag of its own (it streams pretty-printed JSON objects until killed),
# so the shell's `timeout` bounds it to 10s; `jq -c .` compacts each event to one
# line and `head` keeps only the first couple, complete events rather than a
# truncated fragment of one.
timeout 10s linkerd viz tap deploy/server -n "$LAB_NS" -o json 2>"$out/tap-stderr.txt" \
  | jq -c . 2>>"$out/tap-stderr.txt" | head -n 2 > "$out/tap-events.json" || true
event_count="$(wc -l < "$out/tap-events.json" | tr -d ' ')"
printf 'tap_event_count=%s\n' "$event_count" >> "$out/summary.txt"

log "tap discovery data in $out"
cat "$out/summary.txt"
