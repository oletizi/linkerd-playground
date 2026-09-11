#!/usr/bin/env bash
# Credential and configuration state for cert-hygiene scenarios: the issuer Secret, the
# trust roots, and the credential state the plan walk reads (design section 1.3).
# Sourced by lab/collect.sh; do not execute. Only certificate fields are ever read from
# a Secret, never a key field; assert_no_keys proves it for every run.

_decode_cert() { base64 -d < "$1" | cert_meta; } # B64_FILE: metadata of the encoded cert

snap_secret() { # NAME: issuer Secret metadata and certificate facts -- never key.pem
  local f="$RUN_DIR/secrets/$1-identity-issuer.txt" tmp
  mkdir -p "$RUN_DIR/secrets"
  tmp="$(mktemp)"
  {
    printf 'sampled_at=%s\n' "$(_utc)"
    _record "issuer Secret metadata read" kubectl -n linkerd get secret linkerd-identity-issuer \
      -o jsonpath='uid={.metadata.uid}{"\n"}resourceVersion={.metadata.resourceVersion}{"\n"}' || true
    if _record "issuer Secret crt.pem read" kubectl -n linkerd get secret linkerd-identity-issuer \
        -o jsonpath='{.data.crt\.pem}' > "$tmp"; then
      _record "crt.pem decode and inspection" _decode_cert "$tmp" || true
    else
      cat "$tmp"
    fi
  } > "$f"
  rm -f "$tmp"
}

snap_trust() { # NAME: trust-roots ConfigMap hash + each pod's injected-bundle annotation.
  # A failed read is recorded as a "[... failed: exit N]" line.
  local f="$RUN_DIR/trust/$1.txt" tmp
  mkdir -p "$RUN_DIR/trust"
  tmp="$(mktemp)"
  {
    if _record "trust-roots ConfigMap read" kubectl -n linkerd get cm linkerd-identity-trust-roots \
        -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp"; then
      printf 'configmap_sha256=%s\n' "$(sha256sum < "$tmp" | cut -d' ' -f1)"
    else
      cat "$tmp"
    fi
    { _record "pod annotation listing" kubectl get pods -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations.linkerd\.io/trust-root-sha256}{"\n"}{end}' \
        || true; } | awk 'NF == 1 { print $1, "-"; next } { print }'
  } > "$f"
  rm -f "$tmp"
}

_b64_cert_facts() { base64 -d < "$2" | cert_facts "$1"; } # PREFIX B64_FILE

# _cert_from_secret PREFIX SECRET JSONPATH_KEY: cert_facts of the certificate held
# under JSONPATH_KEY (escaped, e.g. 'tls\.crt') in the linkerd-namespace Secret SECRET.
_cert_from_secret() {
  local prefix="$1" secret="$2" key="$3" tmp
  tmp="$(mktemp)"
  if _record "$secret $key read" kubectl -n linkerd get secret "$secret" -o jsonpath="{.data.$key}" > "$tmp"; then
    _record "$secret certificate decode and inspection" _b64_cert_facts "$prefix" "$tmp" || true
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

# snap_credentials NAME: the credential state (design section 1.3) -> credentials/NAME.txt.
snap_credentials() {
  local f="$RUN_DIR/credentials/$1.txt" tmp comp fp joined=""
  mkdir -p "$RUN_DIR/credentials"
  tmp="$(mktemp)"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    if _record "trust-roots ConfigMap read" kubectl -n linkerd get cm linkerd-identity-trust-roots \
        -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp"; then
      printf 'trust_roots_sha256=%s\n' "$(sha256sum < "$tmp" | cut -d' ' -f1)"
    else
      cat "$tmp"
    fi
    _cert_from_secret issuer linkerd-identity-issuer 'crt\.pem'
    for comp in "${WEBHOOK_COMPONENTS[@]}"; do
      _cert_from_secret "webhook_$comp" "$(webhook_secret "$comp")" 'tls\.crt'
    done
  } > "$f"
  rm -f "$tmp"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    fp="$(awk -F= -v k="webhook_${comp}_sha256" '$1 == k { print $2; exit }' "$f")"
    if [ -z "$fp" ]; then
      printf '[webhooks_sha256 not computed: no webhook_%s_sha256 in this snapshot]\n' "$comp" >> "$f"
      return 0
    fi
    joined="${joined:+$joined,}$fp"
  done
  printf 'webhooks_sha256=%s\n' "$(printf '%s' "$joined" | sha256sum | cut -d' ' -f1)" >> "$f"
}

# The three Linkerd webhook configurations, in WEBHOOK_COMPONENTS order.
WEBHOOK_CONFIGS=(mutatingwebhookconfiguration/linkerd-proxy-injector-webhook-config
  validatingwebhookconfiguration/linkerd-policy-validator-webhook-config
  validatingwebhookconfiguration/linkerd-sp-validator-webhook-config)

_webhook_lines() { # CONFIG JSON_FILE: one line per webhook, with the caBundle hashed
  local cfg="$1" name policy b64 hash
  while read -r name policy b64; do
    if [ "$b64" = "-" ]; then hash=-; else hash="$(printf '%s' "$b64" | base64 -d | sha256sum | cut -d' ' -f1)"; fi
    printf 'config %s webhook=%s failurePolicy=%s caBundle_sha256=%s\n' "$cfg" "$name" "$policy" "$hash"
  done < <(jq -r '.webhooks[] | "\(.name) \(.failurePolicy) \(.clientConfig.caBundle // "-")"' "$2")
}

snap_webhooks() { # NAME: webhook configurations and serving certificates -> webhooks/NAME.txt
  local f="$RUN_DIR/webhooks/$1.txt" tmp cfg comp
  mkdir -p "$RUN_DIR/webhooks"
  tmp="$(mktemp)"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    for cfg in "${WEBHOOK_CONFIGS[@]}"; do
      if _record "$cfg read" kubectl get "$cfg" -o json > "$tmp"; then _webhook_lines "$cfg" "$tmp"; else cat "$tmp"; fi
    done
    for comp in "${WEBHOOK_COMPONENTS[@]}"; do
      _cert_from_secret "secret_$comp" "$(webhook_secret "$comp")" 'tls\.crt'
    done
  } > "$f"
  rm -f "$tmp"
}

snap_controlplane() { # NAME: linkerd pods (UID, start, readiness) and Deployments -> controlplane/NAME.txt
  local f="$RUN_DIR/controlplane/$1.txt" tmp d
  mkdir -p "$RUN_DIR/controlplane"
  tmp="$(mktemp)"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    if _record "linkerd pod listing" kubectl -n linkerd get pods -o json > "$tmp"; then
      jq -r '.items[] | "pod linkerd/\(.metadata.name) uid=\(.metadata.uid) start=\(.status.startTime // "-") phase=\(.status.phase) ready=\(([.status.conditions[]? | select(.type == "Ready") | .status] | first) // "-") restarts=\([.status.containerStatuses[]?.restartCount] | add // 0) trust=\(.metadata.annotations["linkerd.io/trust-root-sha256"] // "-")"' "$tmp"
    else
      cat "$tmp"
    fi
    if _record "linkerd deployment listing" kubectl -n linkerd get deploy -o json > "$tmp"; then
      for d in $(jq -r '.items[].metadata.name' "$tmp"); do
        jq -r --arg n "$d" '.items[] | select(.metadata.name == $n) | "deploy linkerd/\(.metadata.name) generation=\(.metadata.generation) observedGeneration=\(.status.observedGeneration // "-") replicas=\(.spec.replicas) readyReplicas=\(.status.readyReplicas // 0)"' "$tmp" \
          | tr -d '\n'
        printf ' template_sha256=%s\n' "$(jq -S -c --arg n "$d" '.items[] | select(.metadata.name == $n) | .spec.template' "$tmp" | sha256sum | cut -d' ' -f1)"
      done
    else
      cat "$tmp"
    fi
  } > "$f"
  rm -f "$tmp"
}
