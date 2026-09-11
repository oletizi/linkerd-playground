#!/usr/bin/env bash
# Evidence snapshot functions for cert-hygiene scenarios. Source after lab/lib-lab.sh
# and set RUN_DIR. A command that fails is RECORDED (with its exit status), never
# fatal: after an expiry, failing commands are the observation. Nothing here ever
# reads a private key; assert_no_keys proves it.

_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

mark() { # PHASE [detail...]
  printf '%s %s\n' "$(_utc)" "$*" >> "$RUN_DIR/timeline.log"
  log "$*"
}

capture() { # FILE CMD...: record a command, its output and its exit status
  local file="$RUN_DIR/$1" rc=0
  shift
  mkdir -p "$(dirname "$file")"
  {
    printf '$ %s\n' "$*"
    "$@" 2>&1 || rc=$?
    printf '[exit %s]\n' "$rc"
  } > "$file"
  return 0
}

_lab_pods() { kubectl -n "$LAB_NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; }
_identity_pod() {
  kubectl -n linkerd get pod -l linkerd.io/control-plane-component=identity \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

_metrics_section() { # NS POD PORT FILTER-REGEX: up to 3 attempts, 2s apart (Ruling P4)
  local ns="$1" pod="$2" port="$3" filter="$4" body rc attempt
  printf '== %s/%s :%s\n' "$ns" "$pod" "$port"
  for attempt in 1 2 3; do
    rc=0
    body="$(kubectl get --raw "/api/v1/namespaces/$ns/pods/$pod:$port/proxy/metrics" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$body" | grep -E "$filter" || printf '[no series matching %s]\n' "$filter"
      return 0
    fi
    printf '[metrics fetch attempt %s failed: exit %s] %s\n' "$attempt" "$rc" "$(printf '%s' "$body" | tr '\n' ' ')"
    [ "$attempt" -eq 3 ] || sleep 2
  done
}

snap_metrics() { # NAME: identity-related series for every lab proxy + the issuer TTL
  local f="$RUN_DIR/metrics/$1.txt" pod idpod
  mkdir -p "$RUN_DIR/metrics"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    # Ruling P1a: match both identity_* and control_identity_* -- the discovered
    # series all carry the control_identity_ prefix and must not be dropped.
    for pod in $(_lab_pods); do _metrics_section "$LAB_NS" "$pod" 4191 '^(identity_|control_identity_)'; done
    idpod="$(_identity_pod)"
    if [ -n "$idpod" ]; then
      _metrics_section linkerd "$idpod" 9990 "^${ISSUER_TTL_METRIC}"
    else
      printf '[no identity controller pod found]\n'
    fi
  } > "$f"
}

tick() { # NAME: the four files every tick must have (see evaluate_validity)
  local name="$1"
  mark tick "$name"
  capture "checks/$name-check.txt" linkerd check --wait 20s &
  capture "checks/$name-check-proxy.txt" linkerd check --proxy --wait 20s &
  snap_metrics "$name"
  capture "pods/$name.txt" kubectl get pods -A -o wide
  wait
}

snap_pod_detail() { # NAME APP
  local pod
  for pod in $(kubectl -n "$LAB_NS" get pods -l "app=$2" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    capture "pods/$1-$pod.yaml" kubectl -n "$LAB_NS" get pod "$pod" -o yaml
    capture "pods/$1-$pod-describe.txt" kubectl -n "$LAB_NS" describe pod "$pod"
  done
}

snap_secret() { # NAME: issuer Secret metadata and certificate facts -- never key.pem
  local f="$RUN_DIR/secrets/$1-identity-issuer.txt"
  mkdir -p "$RUN_DIR/secrets"
  {
    printf 'sampled_at=%s\n' "$(_utc)"
    kubectl -n linkerd get secret linkerd-identity-issuer \
      -o jsonpath='uid={.metadata.uid}{"\n"}resourceVersion={.metadata.resourceVersion}{"\n"}' 2>&1
    kubectl -n linkerd get secret linkerd-identity-issuer -o jsonpath='{.data.crt\.pem}' 2>&1 \
      | base64 -d | cert_meta 2>&1 || printf '[could not read crt.pem]\n'
  } > "$f"
}

snap_trust() { # NAME: trust-roots ConfigMap hash + each pod's injected-bundle annotation
  local f="$RUN_DIR/trust/$1.txt"
  mkdir -p "$RUN_DIR/trust"
  {
    printf 'configmap_sha256=%s\n' "$(kubectl -n linkerd get cm linkerd-identity-trust-roots \
      -o jsonpath='{.data.ca-bundle\.crt}' | sha256sum | cut -d' ' -f1)"
    kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations.linkerd\.io/trust-root-sha256}{"\n"}{end}' \
      | awk 'NF == 1 { print $1, "-"; next } { print }'
  } > "$f"
}

snap_logs() { # NAME
  local dir="logs/$1" pod c
  capture "$dir/identity.txt" kubectl -n linkerd logs deploy/linkerd-identity -c identity --timestamps
  capture "$dir/identity-proxy.txt" kubectl -n linkerd logs deploy/linkerd-identity -c linkerd-proxy --timestamps
  for pod in $(_lab_pods); do
    for c in $(kubectl -n "$LAB_NS" get pod "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      capture "$dir/$pod-$c.txt" kubectl -n "$LAB_NS" logs "$pod" -c "$c" --timestamps
      capture "$dir/$pod-$c-previous.txt" kubectl -n "$LAB_NS" logs "$pod" -c "$c" --timestamps --previous
    done
  done
}

snap_events() { # NAME
  capture "events/$1.txt" kubectl get events -A --sort-by=.lastTimestamp -o wide
}

snap_journal() { # NAME SINCE_EPOCH: API-server side of the run window
  capture "logs/$1/k3s-journal.txt" sudo journalctl -u k3s --since "@$2" --no-pager
}

snap_probes() {
  local p
  mkdir -p "$RUN_DIR/probes"
  for p in probe-http probe-tcp-new probe-tcp-stream; do
    kubectl -n "$LAB_NS" logs "deploy/$p" -c probe > "$RUN_DIR/probes/$p.log" 2>&1 \
      || printf '[kubectl logs failed: exit %s]\n' "$?" >> "$RUN_DIR/probes/$p.log"
  done
}

write_versions() { # SCENARIO CERT_SET
  local f="$RUN_DIR/versions.txt"
  [ ! -e "$f" ] || die "write_versions: $f exists; evidence is written once"
  {
    printf 'scenario=%s\ncert_set=%s\nwritten_at=%s\n' "$1" "$2" "$(_utc)"
    printf 'linkerd_cli_version=%s\n' "$(linkerd version --client --short)"
    printf 'linkerd_controller_image=%s\n' "$(kubectl -n linkerd get deploy linkerd-identity \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="identity")].image}')"
    printf 'identity_args=%s\n' "$(kubectl -n linkerd get deploy linkerd-identity \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="identity")].args}')"
    printf 'kubernetes_version=%s\n' "$(kubectl version -o json | jq -r .serverVersion.gitVersion)"
    printf 'k3s_version=%s\n' "$(k3s --version | head -n 1)"
    printf 'vm_kernel=%s\n' "$(uname -r)"
    kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.image} {.imageID}{"\n"}{end}{end}' \
      | sort -u | awk '{ print "image=" $0 }'
    printf 'retry_config_count=%s\n' "$(kubectl -n "$LAB_NS" get svc,deploy -o json \
      | jq '[.. | objects | .annotations? // empty | to_entries[] | select(.key | test("retry"))] | length')"
    printf 'linkerd_httproutes=%s\n' "$(kubectl get httproutes.policy.linkerd.io -A --no-headers 2>/dev/null | wc -l)"
    env | grep -E '^(LAB_|LINKERD_|GATEWAY_|ANCHOR_|ISSUER_|LEAF_|CONTROL_|REPLACEMENT_|PROBE_|OBSERVE_|POST_|RECOVER_|IMAGE_)' \
      | sort | awk '{ print "config_" $0 }'
  } > "$f"
}

write_cert() { # NAME PEM_FILE: the certificate and its inspection -- never a key
  local name="$1" pem="$2"
  grep -q 'PRIVATE KEY' "$pem" && die "write_cert: $pem contains a private key"
  mkdir -p "$RUN_DIR/certs"
  cp "$pem" "$RUN_DIR/certs/$name.pem"
  { step certificate inspect "$pem"; echo; cert_meta < "$pem"; } > "$RUN_DIR/certs/$name.txt"
}

assert_no_keys() {
  local hits
  hits="$(grep -rl 'PRIVATE KEY' "$RUN_DIR" 2>/dev/null || true)"
  [ -z "$hits" ] || die "private key material found in evidence: $hits"
}
