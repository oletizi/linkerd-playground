#!/usr/bin/env bash
# Lab-supplied webhook serving credentials (design section 1.1): one lab webhook CA and
# one serving certificate per Linkerd webhook, each with its own lifetime and the
# webhook Service's DNS name as its SAN. RSA 2048, the key type Linkerd's own
# generated webhook certificates use. Source after lib/common.sh; do not execute.
# Keys stay in the VM under $CERTS_ROOT; only certificates ever reach evidence.

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

make_webhook_certs() { # DIR SPEC: the lab webhook CA plus one serving certificate per component
  local dir="${1:?}" spec="${2:?make_webhook_certs: SPEC required}" comp life
  make_webhook_ca "$dir"
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
