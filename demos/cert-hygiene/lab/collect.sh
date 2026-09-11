#!/usr/bin/env bash
# Evidence snapshot functions for cert-hygiene scenarios. Source after lab/lib-lab.sh
# and set RUN_DIR. A command that fails is RECORDED (with its exit status), never
# fatal: after an expiry, failing commands are the observation. Nothing here ever
# reads a private key; assert_no_keys proves it.

# Proxy series recorded on every tick: identity (both prefixes, Ruling P1a) and the
# connection counters and gauges (design section 1.4).
PROXY_METRIC_FILTER='^(identity_|control_identity_|tcp_open_total|tcp_close_total|tcp_open_connections|outbound_tcp_route_open_total|outbound_tcp_route_close_total)'

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

_record() { # WHAT CMD...: CMD's stdout, byte for byte; if CMD fails, instead one line
  # "[WHAT failed: exit N] <stderr>". Returns CMD's status; callers record, never die.
  local what="$1" tmp rc=0
  shift
  tmp="$(mktemp -d)"
  "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [ "$rc" -eq 0 ]; then cat "$tmp/out"
  else printf '[%s failed: exit %s] %s\n' "$what" "$rc" "$(tr '\n' ' ' < "$tmp/err")"; fi
  rm -rf "$tmp"
  return "$rc"
}

_lab_pod_mesh() { # "<pod> yes|no" per lab pod: does it have a linkerd-proxy container?
  kubectl -n "$LAB_NS" get pods -o json 2>/dev/null | jq -r '.items[]
    | "\(.metadata.name) \(if ([.spec.initContainers[]?.name, .spec.containers[].name] | index("linkerd-proxy")) then "yes" else "no" end)"' \
    || true
}
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

snap_metrics() { # NAME: identity and connection series for every lab proxy + the issuer TTL
  local f="$RUN_DIR/metrics/$1.txt" pod meshed idpod
  mkdir -p "$RUN_DIR/metrics"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    while read -r pod meshed; do
      if [ "$meshed" = yes ]; then
        _metrics_section "$LAB_NS" "$pod" 4191 "$PROXY_METRIC_FILTER"
      else
        printf '== %s/%s :4191\n[no linkerd-proxy container: not scraped]\n' "$LAB_NS" "$pod"
      fi
    done < <(_lab_pod_mesh)
    idpod="$(_identity_pod)"
    if [ -n "$idpod" ]; then
      _metrics_section linkerd "$idpod" 9990 "^${ISSUER_TTL_METRIC}"
    else
      printf '[no identity controller pod found]\n'
    fi
  } > "$f"
}

tick() { # NAME: the seven files every tick must have (see evaluate_validity)
  local name="$1"
  # Read only by scenario_tick_extra implementations in later scenario files, not by
  # this file itself.
  # shellcheck disable=SC2034
  TICK_START_EPOCH="$(date -u +%s)"   # when this tick's checks begin; hooks compare against it
  mark tick "$name"
  capture "checks/$name-check.txt" linkerd check --wait 20s &
  capture "checks/$name-check-proxy.txt" linkerd check --proxy --wait 20s &
  snap_metrics "$name"
  capture "pods/$name.txt" kubectl get pods -A -o wide
  snap_credentials "$name"
  snap_trust "$name"
  snap_webhooks "$name"
  snap_controlplane "$name"
  wait
  if declare -F scenario_tick_extra > /dev/null; then scenario_tick_extra "$name"; fi
}

snap_pod_detail() { # NAME APP
  local pod
  for pod in $(kubectl -n "$LAB_NS" get pods -l "app=$2" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    capture "pods/$1-$pod.yaml" kubectl -n "$LAB_NS" get pod "$pod" -o yaml
    capture "pods/$1-$pod-describe.txt" kubectl -n "$LAB_NS" describe pod "$pod"
  done
}

snap_events() { # NAME
  capture "events/$1.txt" kubectl get events -A --sort-by=.lastTimestamp -o wide
}

write_versions() { # SCENARIO CERT_SET: runs once, before baseline; dies naming any
  # field it cannot read, so versions.txt is never written with a blank field.
  local f="$RUN_DIR/versions.txt" cli image args kube k3sv images retries routes cfg
  [ ! -e "$f" ] || die "write_versions: $f exists; evidence is written once"
  cli="$(linkerd version --client --short)" || die "write_versions: cannot read linkerd_cli_version"
  image="$(kubectl -n linkerd get deploy linkerd-identity \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="identity")].image}')" \
    || die "write_versions: cannot read linkerd_controller_image"
  [ -n "$image" ] || die "write_versions: linkerd_controller_image is empty"
  args="$(kubectl -n linkerd get deploy linkerd-identity \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="identity")].args}')" \
    || die "write_versions: cannot read identity_args"
  [ -n "$args" ] || die "write_versions: identity_args is empty"
  kube="$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
    || die "write_versions: cannot read kubernetes_version"
  k3sv="$(k3s --version)" || die "write_versions: cannot read k3s_version"
  images="$(kubectl get pods -A \
    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.image} {.imageID}{"\n"}{end}{end}')" \
    || die "write_versions: cannot read image"
  [ -n "$images" ] || die "write_versions: no image in any pod status"
  retries="$(kubectl -n "$LAB_NS" get svc,deploy -o json \
    | jq '[.. | objects | .annotations? // empty | to_entries[] | select(.key | test("retry"))] | length')" \
    || die "write_versions: cannot read retry_config_count"
  routes="$(kubectl get httproutes.policy.linkerd.io -A --no-headers)" \
    || die "write_versions: cannot read linkerd_httproutes"
  cfg="$(env | grep -E '^(LAB_|LINKERD_|GATEWAY_|ANCHOR_|ISSUER_|LEAF_|CONTROL_|REPLACEMENT_|PROBE_|OBSERVE_|POST_|RECOVER_|IMAGE_|PROFILE=|WEBHOOK_|EXTRA_|GATE_|OUTAGE_|FAULT_|S_HARD_|K_|POLICY_|SP_|NEW_|W_|DISCOVERY_)' | sort)" \
    || die "write_versions: cannot read config_* (no lab settings in the environment)"
  {
    printf 'scenario=%s\ncert_set=%s\nwritten_at=%s\n' "$1" "$2" "$(_utc)"
    printf 'linkerd_cli_version=%s\n' "$cli"
    printf 'linkerd_controller_image=%s\n' "$image"
    printf 'identity_args=%s\n' "$args"
    printf 'kubernetes_version=%s\n' "$kube"
    printf 'k3s_version=%s\n' "${k3sv%%$'\n'*}"
    printf 'vm_kernel=%s\n' "$(uname -r)"
    printf '%s\n' "$images" | sort -u | awk '{ print "image=" $0 }'
    printf 'retry_config_count=%s\n' "$retries"
    printf 'linkerd_httproutes=%s\n' "$(printf '%s' "$routes" | grep -c . || true)"
    printf '%s\n' "$cfg" | awk '{ print "config_" $0 }'
  } > "$f"
}

write_cert() { # NAME PEM_FILE: the certificate and its inspection -- never a key
  local name="$1" pem="$2"
  grep -q 'PRIVATE KEY' "$pem" && die "write_cert: $pem contains a private key"
  mkdir -p "$RUN_DIR/certs"
  cp "$pem" "$RUN_DIR/certs/$name.pem"
  { step certificate inspect "$pem"; echo; cert_meta < "$pem"; } > "$RUN_DIR/certs/$name.txt"
}

assert_no_keys() { # no private key in evidence, as PEM text or base64-encoded
  local hits
  hits="$(grep -rl 'PRIVATE KEY' "$RUN_DIR" 2>/dev/null || true)"
  [ -z "$hits" ] || die "private key material found in evidence: $hits"
  hits="$(b64_key_hits "$RUN_DIR")"
  [ -z "$hits" ] || die "base64-encoded private key material found in evidence: $hits"
}

# The rest of the collector, split by concern to keep each file short.
_COLLECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_COLLECT_DIR/collect-state.sh"
# shellcheck source=/dev/null
. "$_COLLECT_DIR/collect-logs.sh"
