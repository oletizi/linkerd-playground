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

# The three Linkerd webhook configurations, in WEBHOOK_COMPONENTS order. Only ever
# iterated in that fixed order (snap_webhooks), never indexed against WEBHOOK_COMPONENTS
# by a second caller: webhook_config (lib-webhook.sh) is the name-keyed lookup for that
# (_w_facts, w_cert_state_line), so no caller pairs the two arrays by position.
WEBHOOK_CONFIGS=(mutatingwebhookconfiguration/linkerd-proxy-injector-webhook-config
  validatingwebhookconfiguration/linkerd-policy-validator-webhook-config
  validatingwebhookconfiguration/linkerd-sp-validator-webhook-config)

# w_backing_write FILE COMPONENT...: each COMPONENT's Service's backing Deployment(s) to
# FILE (truncated first, directory created), derived from its selector (w_backing_line).
# The Deployment listing is read once and shared across every COMPONENT; a failed read,
# or a failed per-Service read, is recorded on that component's line, never fatal. Shared
# by W (reconnect/backing.txt, all three components) and N (scale/backing.txt, one).
w_backing_write() {
  local f="${1:?w_backing_write: FILE required}" tmp comp svc derr=""
  shift
  [ $# -ge 1 ] || die "w_backing_write: at least one COMPONENT required"
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp -d)"
  : > "$f"
  _record "linkerd Deployment listing" kubectl -n linkerd get deploy -o json > "$tmp/d.json" || derr="$(cat "$tmp/d.json")"
  for comp in "$@"; do
    svc="$(webhook_service "$comp")"
    if [ -n "$derr" ]; then w_backing_line "$comp" "$svc" "$tmp/d.json" "$tmp/d.json" "$derr" >> "$f"
    elif _record "Service $svc read" kubectl -n linkerd get svc "$svc" -o json > "$tmp/s.json"; then
      w_backing_line "$comp" "$svc" "$tmp/s.json" "$tmp/d.json" >> "$f"
    else w_backing_line "$comp" "$svc" "$tmp/s.json" "$tmp/d.json" "$(cat "$tmp/s.json")" >> "$f"; fi
  done
  rm -rf "$tmp"
}

# w_cert_state_line COMPONENT SUPPLIED_DIR TMPDIR NOW: one component's certificate-state
# line (w_fact_line), read from its live Secret and its own webhook configuration's
# caBundle (webhook_config, never an index-paired array), against the lab-supplied
# certificate at SUPPLIED_DIR/COMPONENT.crt. Shared by W's per-component recovery-facts
# loop (_w_facts) and N's per-tick certificate-state record (_n_cert_state).
w_cert_state_line() {
  local comp="${1:?w_cert_state_line: COMPONENT required}" sup="${2:?w_cert_state_line: SUPPLIED_DIR required}"
  local tmp="${3:?w_cert_state_line: TMPDIR required}" now="${4:?w_cert_state_line: NOW required}" sfp
  sfp="$(cert_facts s < "$sup/$comp.crt" | awk -F= '$1 == "s_sha256" { print $2 }')" \
    || die "w_cert_state_line: cannot read the lab-supplied certificate $sup/$comp.crt"
  kubectl -n linkerd get secret "$(webhook_secret "$comp")" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "$tmp/$comp.crt" 2>/dev/null || true
  kubectl get "$(webhook_config "$comp")" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null \
    | base64 -d > "$tmp/$comp-ca.pem" 2>/dev/null || true
  w_fact_line "$comp" "$sfp" "$tmp/$comp.crt" "$tmp/$comp-ca.pem" "$now"
}

# deploy_selector NAMESPACE DEPLOY: DEPLOY's own .spec.selector.matchLabels as a
# "k=v,k=v" -l value, never a hardcoded label -- a caller's backing Deployment is itself
# derived (w_backing_write/w_backing_deployments), so the label wait_pods_gone waits on
# has to be derived too. Shared by N (scale/pods-gone.txt) and G (swap/pods-gone-*.txt).
deploy_selector() {
  local ns="${1:?deploy_selector: NAMESPACE required}" d="${2:?deploy_selector: DEPLOY required}" json
  json="$(kubectl -n "$ns" get deploy "$d" -o jsonpath='{.spec.selector.matchLabels}')" \
    || die "deploy_selector: cannot read $d's selector"
  [ -n "$json" ] || die "deploy_selector: $d's selector is empty"
  jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' <<< "$json" \
    || die "deploy_selector: cannot parse $d's selector: $json"
}

# wait_pods_gone FILE NAMESPACE DEPLOY...: FILE (run-relative, passed to capture) --
# wait for every named Deployment's pre-change pods to actually be gone. `kubectl
# rollout status` alone is not enough: it can report success while the old pod is still
# Running and a live, Ready endpoint (seen in N's first discovery run,
# controlplane/fault-after.txt, sampled 2s after T_mark, after rollout-down.txt had
# already recorded [exit 0]). Without this, a probe landing in that gap would record a
# wrong observation with nothing in the artifacts flagging it. Shared by N's scale-to-
# zero fault and recovery and G's certificate-swap restart and restore.
wait_pods_gone() {
  local f="${1:?wait_pods_gone: FILE required}" ns="${2:?wait_pods_gone: NAMESPACE required}" d sels=()
  shift 2
  [ $# -ge 1 ] || die "wait_pods_gone: at least one DEPLOY required"
  for d in "$@"; do sels+=("$(deploy_selector "$ns" "$d")"); done
  # shellcheck disable=SC2016
  capture "$f" bash -c 'ns="$1"; shift
    for sel in "$@"; do kubectl -n "$ns" wait --for=delete pod -l "$sel" --timeout=120s || exit 1; done' \
    pods-gone "$ns" "${sels[@]}"
}

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

# _snap_namespace_state NAMESPACE FILE: NAMESPACE's pods (UID, start, readiness) and each
# Deployment's generation and pod-template hash. The shared body of snap_controlplane and
# snap_viz (design section 1.4): both read the same shape, so a reader who knows one
# knows the other.
_snap_namespace_state() {
  local ns="${1:?_snap_namespace_state: NAMESPACE required}" f="${2:?_snap_namespace_state: FILE required}" tmp d
  tmp="$(mktemp)"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    if _record "$ns pod listing" kubectl -n "$ns" get pods -o json > "$tmp"; then
      jq -r --arg ns "$ns" '.items[] | "pod \($ns)/\(.metadata.name) uid=\(.metadata.uid) start=\(.status.startTime // "-") phase=\(.status.phase) ready=\(([.status.conditions[]? | select(.type == "Ready") | .status] | first) // "-") restarts=\([.status.containerStatuses[]?.restartCount] | add // 0) trust=\(.metadata.annotations["linkerd.io/trust-root-sha256"] // "-")"' "$tmp"
    else
      cat "$tmp"
    fi
    if _record "$ns deployment listing" kubectl -n "$ns" get deploy -o json > "$tmp"; then
      for d in $(jq -r '.items[].metadata.name' "$tmp"); do
        jq -r --arg n "$d" --arg ns "$ns" '.items[] | select(.metadata.name == $n) | "deploy \($ns)/\(.metadata.name) generation=\(.metadata.generation) observedGeneration=\(.status.observedGeneration // "-") replicas=\(.spec.replicas) readyReplicas=\(.status.readyReplicas // 0)"' "$tmp" \
          | tr -d '\n'
        printf ' template_sha256=%s\n' "$(jq -S -c --arg n "$d" '.items[] | select(.metadata.name == $n) | .spec.template' "$tmp" | sha256sum | cut -d' ' -f1)"
      done
    else
      cat "$tmp"
    fi
  } > "$f"
  rm -f "$tmp"
}

snap_controlplane() { # NAME: linkerd pods (UID, start, readiness) and Deployments -> controlplane/NAME.txt
  mkdir -p "$RUN_DIR/controlplane"
  _snap_namespace_state linkerd "$RUN_DIR/controlplane/$1.txt"
}

# snap_viz NAME: linkerd-viz pods (UID, start, readiness) and Deployments, for V only
# (design section 1.4) -> viz/NAME.txt. Same shape as snap_controlplane.
snap_viz() {
  mkdir -p "$RUN_DIR/viz"
  _snap_namespace_state linkerd-viz "$RUN_DIR/viz/$1.txt"
}

# snap_apiservices NAME: v1alpha1.tap.linkerd.io's Available condition (status, reason,
# message), its caBundle's SHA-256, and its backing Service, for V only (design section
# 1.4) -> apiservices/NAME.txt. Field names follow discover-tap.sh (Task 1 discovery),
# which reads apiservice_available the same way.
snap_apiservices() {
  local f="$RUN_DIR/apiservices/$1.txt" tmp caBundle
  mkdir -p "$RUN_DIR/apiservices"
  tmp="$(mktemp)"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    if _record "v1alpha1.tap.linkerd.io read" kubectl get apiservice v1alpha1.tap.linkerd.io -o json > "$tmp"; then
      jq -r '(([.status.conditions[]? | select(.type == "Available")] | first) // {}) as $c
        | "apiservice_available_status=\($c.status // "-")\napiservice_available_reason=\($c.reason // "-")\napiservice_available_message=\($c.message // "-")\napiservice_backing_service=\(.spec.service.name // "<none>").\(.spec.service.namespace // "<none>").svc"' "$tmp"
      # A missing caBundle is "-", like every other neighbouring sentinel (_webhook_lines,
      # snap_trust): the SHA-256 of an empty string would otherwise be indistinguishable
      # from a real hash (review finding, slice 3 Task 3).
      caBundle="$(jq -r '.spec.caBundle // empty' "$tmp")"
      if [ -n "$caBundle" ]; then
        printf 'apiservice_cabundle_sha256=%s\n' "$(printf '%s' "$caBundle" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1)"
      else
        printf 'apiservice_cabundle_sha256=-\n'
      fi
    else
      cat "$tmp"
    fi
  } > "$f"
  rm -f "$tmp"
}
