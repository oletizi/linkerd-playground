#!/usr/bin/env bash
# Unit tests for lab/lib-webhook.sh: the lab-supplied webhook and tap serving credentials,
# and load_profile's TAP_CERT_LIFETIME required key (lib-lab.sh; slice 3 Task 1 added the
# key, untested until now). lib-webhook.sh had no test file before this task.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
# lib-lab.sh sources lib/certs.sh, lib/k3s.sh, lib/linkerd.sh, lib-evidence.sh and, last,
# lib-webhook.sh itself -- the same chain every scenario file sources (via
# scenario-common.sh) before it ever touches a certificate.
# shellcheck source=/dev/null
. "$DEMO/lab/lib-lab.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---- webhook_service / webhook_secret / webhook_lifetime ----
assert_eq "$(webhook_service proxyInjector)" linkerd-proxy-injector "proxyInjector's Service"
assert_eq "$(webhook_service policyValidator)" linkerd-policy-validator "policyValidator's Service"
assert_eq "$(webhook_service profileValidator)" linkerd-sp-validator "profileValidator's Service"
assert_fails "an unknown component dies (webhook_service)" webhook_service nope
assert_eq "$(webhook_secret proxyInjector)" linkerd-proxy-injector-k8s-tls "the Secret is <service>-k8s-tls"
assert_eq "$(webhook_lifetime 'proxyInjector=15m policyValidator=20m' policyValidator)" 20m \
  "webhook_lifetime picks its own component out of the spec"
assert_fails "webhook_lifetime dies when its component is absent from SPEC" webhook_lifetime 'proxyInjector=15m' policyValidator

# ---- make_webhook_ca / make_webhook_cert ----
make_webhook_ca "$T/ca1"
assert_succeeds "make_webhook_ca writes ca.crt" test -s "$T/ca1/ca.crt"
assert_succeeds "make_webhook_ca writes ca.key" test -s "$T/ca1/ca.key"
assert_fails "make_webhook_ca refuses to overwrite an existing CA" make_webhook_ca "$T/ca1"
make_webhook_cert "$T/ca1" proxyInjector 15m
assert_succeeds "make_webhook_cert writes the component's cert" test -s "$T/ca1/proxyInjector.crt"
assert_contains "$(openssl x509 -noout -subject -in "$T/ca1/proxyInjector.crt")" linkerd-proxy-injector.linkerd.svc \
  "the leaf's subject is the webhook Service's DNS name"
assert_contains "$(openssl x509 -noout -text -in "$T/ca1/proxyInjector.crt")" DNS:linkerd-proxy-injector.linkerd.svc \
  "the leaf's SAN is the webhook Service's DNS name"
assert_fails "make_webhook_cert refuses to overwrite an existing cert" make_webhook_cert "$T/ca1" proxyInjector 15m
assert_fails "make_webhook_cert dies without a CA in DIR" make_webhook_cert "$T/noca" proxyInjector 15m

# ---- make_webhook_certs: all three components, and CA reuse rather than the overwrite die ----
make_webhook_certs "$T/ca2" 'proxyInjector=15m policyValidator=20m profileValidator=25m'
for c in proxyInjector policyValidator profileValidator; do
  assert_succeeds "make_webhook_certs writes $c.crt" test -s "$T/ca2/$c.crt"
done
make_webhook_ca "$T/ca3"   # a CA already present before make_webhook_certs runs
assert_succeeds "make_webhook_certs reuses an existing CA instead of dying on its overwrite guard" \
  make_webhook_certs "$T/ca3" 'proxyInjector=15m policyValidator=20m profileValidator=25m'
assert_fails "make_webhook_certs dies when SPEC omits one component's lifetime" \
  make_webhook_certs "$T/ca5" 'proxyInjector=15m policyValidator=20m'

# ---- webhook_install_args / tap_install_args: pure formatting ----
assert_eq "$(webhook_install_args /d | wc -l | tr -d ' ')" 6 "one --set-file pair per component, 3 components"
assert_contains "$(webhook_install_args /d)" \
  "$(printf -- '--set-file\nproxyInjector.crtPEM=/d/proxyInjector.crt,proxyInjector.keyPEM=/d/proxyInjector.key,proxyInjector.caBundle=/d/ca.crt')" \
  "webhook_install_args names proxyInjector's cert, key and caBundle"
assert_eq "$(tap_install_args /d)" \
  "$(printf -- '--set-file\ntap.crtPEM=/d/tap.crt,tap.keyPEM=/d/tap.key,tap.caBundle=/d/ca.crt')" \
  "tap_install_args names tap's cert, key and caBundle"

# ---- make_tap_cert ----
make_tap_cert "$T/ca1" 15m
assert_succeeds "make_tap_cert writes tap.crt" test -s "$T/ca1/tap.crt"
assert_contains "$(openssl x509 -noout -subject -in "$T/ca1/tap.crt")" tap.linkerd-viz.svc \
  "the tap leaf's subject is tap's own Service DNS name, not a webhook's"
assert_contains "$(openssl x509 -noout -text -in "$T/ca1/tap.crt")" DNS:tap.linkerd-viz.svc \
  "the tap leaf's SAN is tap.linkerd-viz.svc"
assert_fails "make_tap_cert refuses to overwrite an existing tap cert" make_tap_cert "$T/ca1" 15m
assert_fails "make_tap_cert dies without a CA in DIR" make_tap_cert "$T/noca2" 15m

# ---- load_profile: TAP_CERT_LIFETIME, the required key slice 3 Task 1 added ----
profile() { # DIR NAME BODY: a fixture credential profile at DIR/profiles/NAME.env
  mkdir -p "$1/profiles"
  printf '%s\n' "$3" > "$1/profiles/$2.env"
}
lp() { LAB_DIR="$1" load_profile "$2"; } # LAB_DIR PROFILE
COMPLETE='ANCHOR_LIFETIME=87600h
ISSUER_LIFETIME=8760h
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES=
EXTRA_INSTALL_FLAGS='
profile "$T/lab" missing-tap "$COMPLETE"
assert_fails "load_profile dies when a profile does not define TAP_CERT_LIFETIME" lp "$T/lab" missing-tap
assert_contains "$(lp "$T/lab" missing-tap 2>&1)" "does not define TAP_CERT_LIFETIME" "the error names the missing key"
profile "$T/lab" with-tap "$COMPLETE
TAP_CERT_LIFETIME="
assert_succeeds "load_profile accepts TAP_CERT_LIFETIME defined empty (unused, per its own comment convention)" lp "$T/lab" with-tap
assert_eq "$PROFILE" with-tap "load_profile exports PROFILE"
profile "$T/lab" tap-set "$COMPLETE
TAP_CERT_LIFETIME=15m"
assert_succeeds "load_profile accepts TAP_CERT_LIFETIME set to a real duration" lp "$T/lab" tap-set
assert_eq "$TAP_CERT_LIFETIME" 15m "load_profile exports the profile's TAP_CERT_LIFETIME"
profile "$T/lab" no-anchor 'ISSUER_LIFETIME=8760h
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES=
EXTRA_INSTALL_FLAGS=
TAP_CERT_LIFETIME='
assert_fails "load_profile still dies on a missing pre-existing required key (ANCHOR_LIFETIME)" lp "$T/lab" no-anchor
assert_fails "load_profile dies on an unknown profile" lp "$T/lab" nope-does-not-exist

finish test-lib-webhook
