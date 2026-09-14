#!/usr/bin/env bash
# Lab-supplied webhook serving credentials (design section 1.1): one lab webhook CA and
# one serving certificate per Linkerd webhook, each with its own lifetime and the
# webhook Service's DNS name as its SAN. RSA 2048, the key type Linkerd's own
# generated webhook certificates use. Source after lib/common.sh; do not execute.
# Keys stay in the VM under $CERTS_ROOT; only certificates ever reach evidence.
#
# The tap serving credential (slice 3 Task 1) is a fourth lab-supplied credential of
# the same shape, signed by this same lab CA rather than a second CA mechanism.

# Helm value prefixes of Linkerd's three webhooks, in the fixed order every file uses.
WEBHOOK_COMPONENTS=(proxyInjector policyValidator profileValidator)

webhook_service() { # COMPONENT: the webhook's Service name in the linkerd namespace
  case "${1:?webhook_service: COMPONENT required}" in
    proxyInjector) echo linkerd-proxy-injector ;;
    policyValidator) echo linkerd-policy-validator ;;
    profileValidator) echo linkerd-sp-validator ;;
    *) die "webhook_service: unknown component '$1'" ;;
  esac
}

webhook_config() { # COMPONENT: the webhook configuration object naming COMPONENT's webhook
  # (the same identifiers WEBHOOK_CONFIGS, collect-state.sh, lists in WEBHOOK_COMPONENTS
  # order; this is the name-keyed lookup so callers never pair the two arrays by index)
  case "${1:?webhook_config: COMPONENT required}" in
    proxyInjector) echo mutatingwebhookconfiguration/linkerd-proxy-injector-webhook-config ;;
    policyValidator) echo validatingwebhookconfiguration/linkerd-policy-validator-webhook-config ;;
    profileValidator) echo validatingwebhookconfiguration/linkerd-sp-validator-webhook-config ;;
    *) die "webhook_config: unknown component '$1'" ;;
  esac
}

webhook_secret() { # COMPONENT: the Secret holding the webhook's serving certificate
  echo "$(webhook_service "$1")-k8s-tls"
}

webhook_lifetime() { # SPEC COMPONENT: COMPONENT's lifetime in SPEC ("proxyInjector=15m ...")
  local spec="$1" comp="$2" pair
  for pair in $spec; do
    if [ "${pair%%=*}" = "$comp" ]; then echo "${pair#*=}"; return 0; fi
  done
  die "webhook_lifetime: no lifetime for $comp in WEBHOOK_CERT_LIFETIMES='$spec'"
}

make_webhook_ca() { # DIR: DIR/ca.crt + DIR/ca.key. Never overwrites.
  local dir="${1:?make_webhook_ca: DIR required}"
  [ ! -e "$dir/ca.crt" ] || die "make_webhook_ca: $dir/ca.crt exists; refusing to overwrite"
  mkdir -p "$dir"
  step certificate create lab-webhook-ca "$dir/ca.crt" "$dir/ca.key" --profile root-ca \
    --kty RSA --size 2048 --not-after 87600h --no-password --insecure
}

make_webhook_cert() { # DIR COMPONENT LIFETIME: DIR/COMPONENT.{crt,key}, signed by DIR/ca.*
  local dir="${1:?}" comp="${2:?}" life="${3:?}" host
  host="$(webhook_service "$comp").linkerd.svc"
  if [ ! -f "$dir/ca.crt" ] || [ ! -f "$dir/ca.key" ]; then die "make_webhook_cert: no webhook CA in $dir"; fi
  [ ! -e "$dir/$comp.crt" ] || die "make_webhook_cert: $dir/$comp.crt exists; refusing to overwrite"
  step certificate create "$host" "$dir/$comp.crt" "$dir/$comp.key" --profile leaf \
    --ca "$dir/ca.crt" --ca-key "$dir/ca.key" --san "$host" --kty RSA --size 2048 \
    --not-after "$life" --no-password --insecure
}

# _SHA1_LEAF_TEMPLATE: the step certificate template that makes step emit a leaf whose
# signature algorithm the API server refuses (design section 4; slice 4 Task 3's
# finding). `step certificate create`'s own flags cannot ask for this: there is no
# -signature-algorithm flag, and an undersized RSA key is refused by Go itself before
# step ever gets to sign anything. But a certificate template is not a flag -- step
# honors whatever "signatureAlgorithm" a template names, without complaint. So step's
# flags are not a safeguard against emitting an insecure certificate; only their own,
# narrower policy is. SHA-1 is the one Task 3 proved this cluster's API server refuses.
_SHA1_LEAF_TEMPLATE='{
  "subject": {{ toJson .Subject }},
  "sans": {{ toJson .SANs }},
  "keyUsage": ["keyEncipherment", "digitalSignature"],
  "extKeyUsage": ["serverAuth"],
  "signatureAlgorithm": "SHA1-RSA"
}'

# make_webhook_cert_sha1 DIR COMPONENT LIFETIME: DIR/COMPONENT.{crt,key}, signed by
# DIR/ca.*, shaped exactly like make_webhook_cert (SAN, chain, lifetime) except its
# signature algorithm, produced through _SHA1_LEAF_TEMPLATE above rather than
# --profile leaf. Never overwrites. Used by scenario G (lab/scenario-g.sh) for its
# refused webhook credential -- everything about it correct except the thing under test.
make_webhook_cert_sha1() {
  local dir="${1:?}" comp="${2:?}" life="${3:?}" host tpl rc=0
  host="$(webhook_service "$comp").linkerd.svc"
  if [ ! -f "$dir/ca.crt" ] || [ ! -f "$dir/ca.key" ]; then die "make_webhook_cert_sha1: no webhook CA in $dir"; fi
  [ ! -e "$dir/$comp.crt" ] || die "make_webhook_cert_sha1: $dir/$comp.crt exists; refusing to overwrite"
  tpl="$(mktemp)"
  printf '%s\n' "$_SHA1_LEAF_TEMPLATE" > "$tpl"
  step certificate create "$host" "$dir/$comp.crt" "$dir/$comp.key" --template "$tpl" \
    --ca "$dir/ca.crt" --ca-key "$dir/ca.key" --san "$host" --kty RSA --size 2048 \
    --not-after "$life" --no-password --insecure || rc=$?
  rm -f "$tpl"
  return "$rc"
}

make_webhook_certs() { # DIR SPEC: the lab webhook CA plus one serving certificate per component
  local dir="${1:?}" spec="${2:?make_webhook_certs: SPEC required}" comp life
  # Reuse an already-created CA (e.g. one Task 1's tap certificate made first in the
  # same DIR) instead of dying on make_webhook_ca's overwrite guard.
  [ -f "$dir/ca.crt" ] || make_webhook_ca "$dir"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    life="$(webhook_lifetime "$spec" "$comp")" || die "make_webhook_certs: no lifetime for $comp"
    make_webhook_cert "$dir" "$comp" "$life"
  done
}

webhook_install_args() { # DIR: linkerd install/upgrade arguments passing DIR's certs, one per line
  local dir="${1:?}" comp
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    printf -- '--set-file\n%s.crtPEM=%s,%s.keyPEM=%s,%s.caBundle=%s\n' \
      "$comp" "$dir/$comp.crt" "$comp" "$dir/$comp.key" "$comp" "$dir/ca.crt"
  done
}

# make_tap_cert DIR LIFETIME: DIR/tap.{crt,key}, signed by DIR/ca.*, SAN tap.linkerd-viz.svc
# (the tap APIService's backing Service; discover-tap.sh checks that name against it).
make_tap_cert() {
  local dir="${1:?make_tap_cert: DIR required}" life="${2:?make_tap_cert: LIFETIME required}"
  local host="tap.linkerd-viz.svc"
  if [ ! -f "$dir/ca.crt" ] || [ ! -f "$dir/ca.key" ]; then die "make_tap_cert: no webhook CA in $dir"; fi
  [ ! -e "$dir/tap.crt" ] || die "make_tap_cert: $dir/tap.crt exists; refusing to overwrite"
  step certificate create "$host" "$dir/tap.crt" "$dir/tap.key" --profile leaf \
    --ca "$dir/ca.crt" --ca-key "$dir/ca.key" --san "$host" --kty RSA --size 2048 \
    --not-after "$life" --no-password --insecure
}

tap_install_args() { # DIR: linkerd viz install arguments passing DIR's tap cert, one per line
  local dir="${1:?}"
  printf -- '--set-file\ntap.crtPEM=%s,tap.keyPEM=%s,tap.caBundle=%s\n' \
    "$dir/tap.crt" "$dir/tap.key" "$dir/ca.crt"
}
