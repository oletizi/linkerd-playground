#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a lab just reset with the webhook-long profile
# (lab-supplied webhook certificates) and with baseline workloads deployed. Records
# whether Linkerd serves the lab-supplied webhook certificates: each Secret's certificate
# against the supplied one, each webhook configuration's caBundle against the supplied
# CA, linkerd check's webhook rows, a server-side dry-run pod create (the proxy-injector
# must add linkerd-proxy), and how many webhooks a render with webhookFailurePolicy=Fail
# (as webhook-short-fail installs) sets to Fail. The render is never applied or saved.
# Usage: discover-webhooks.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
out="${1:?usage: discover-webhooks.sh <out-dir>}"
[ ! -e "$out" ] || die "$out exists; refusing to overwrite"
# shellcheck disable=SC2012
certs="$(ls -dt "$CERTS_ROOT"/*/ | head -n 1)"
[ -d "$certs/webhooks" ] || die "newest cert set $certs has no webhooks/; reset with webhook-long first"
mkdir -p "$out"

fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; } # PEM on stdin
yn() { if [ "$1" = "$2" ]; then echo yes; else echo no; fi; }    # A B: yes when equal
config_of() { # COMPONENT: the kind/name of its webhook configuration
  case "$1" in
    proxyInjector) echo mutatingwebhookconfiguration/linkerd-proxy-injector-webhook-config ;;
    policyValidator) echo validatingwebhookconfiguration/linkerd-policy-validator-webhook-config ;;
    profileValidator) echo validatingwebhookconfiguration/linkerd-sp-validator-webhook-config ;;
  esac
}

linkerd check > "$out/check.txt" 2>&1 || true
{
  printf 'cert_set=%s\n' "$certs"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    supplied="$(fp < "$certs/webhooks/$comp.crt")"
    served="$(kubectl -n linkerd get secret "$(webhook_secret "$comp")" -o jsonpath='{.data.tls\.crt}' | base64 -d | fp)"
    # Fingerprint, not raw sha256sum: the caBundle loses the PEM's trailing newline in
    # the Helm/API round trip, so byte hashes differ for the same certificate.
    bundle="$(kubectl get "$(config_of "$comp")" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | fp)"
    ca="$(fp < "$certs/webhooks/ca.crt")"
    names="$(kubectl get "$(config_of "$comp")" -o jsonpath='{.webhooks[*].name}')"
    policy="$(kubectl get "$(config_of "$comp")" -o jsonpath='{.webhooks[*].failurePolicy}')"
    printf 'component=%s secret_matches_supplied=%s cabundle_matches_supplied_ca=%s webhook_names=%s failure_policy=%s\n' \
      "$comp" "$(yn "$supplied" "$served")" "$(yn "$bundle" "$ca")" "$names" "$policy"
  done
} > "$out/summary.txt"
kubectl -n "$LAB_NS" run discover-inject-probe --image="$IMAGE_BUSYBOX" --restart=Never \
  --dry-run=server -o yaml -- sleep 60 > "$out/inject-dry-run.yaml" 2>&1 || true
if grep -q 'name: linkerd-proxy$' "$out/inject-dry-run.yaml"; then
  echo injection=injected >> "$out/summary.txt"
else
  echo injection=not-injected >> "$out/summary.txt"
fi
grep -E 'webhook has valid cert|cert is valid for at least 60 days' "$out/check.txt" >> "$out/summary.txt" || true
mapfile -t wargs < <(webhook_install_args "$certs/webhooks")
fails="$(linkerd install --ignore-cluster "${wargs[@]}" --set webhookFailurePolicy=Fail 2>&1 \
  | grep -c 'failurePolicy: Fail' || true)"
echo "render_fail_policy_count=$fails" >> "$out/summary.txt"
log "webhook discovery data in $out"
cat "$out/summary.txt"
