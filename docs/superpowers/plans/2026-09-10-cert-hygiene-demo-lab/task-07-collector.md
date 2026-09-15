# Task 7: Collector

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** One sourced file of snapshot functions that writes the spec § 3 evidence layout from a live lab. It records failures as evidence and never dies because a command failed (after an expiry, failing commands *are* the observation). It never writes a private key. It is exercised here against a healthy lab through a `snapshot` verb.

**Files:**
- Create: `demos/cert-hygiene/lab/collect.sh`
- Create: `demos/cert-hygiene/lab/snapshot-once.sh`
- Modify: `demos/cert-hygiene/Justfile` (add `snapshot`)

**Interfaces:**
- Consumes: `lab/lib-lab.sh` (config, `LAB_NS`, `LEAF_EXPIRY_METRIC`, `ISSUER_TTL_METRIC`, `CERTS_ROOT`); `lab/lib-evidence.sh` (`cert_meta`); the Task 4 file contracts; the Task 6 workload names.
- Produces. Every function writes under the global `RUN_DIR`, which the caller sets and creates:
  - `mark PHASE [detail...]`: appends `<UTC> PHASE detail` to `timeline.log`.
  - `capture FILE CMD...`: runs CMD and writes `$ CMD`, its combined output, and `[exit N]` to `RUN_DIR/FILE`. It always returns 0.
  - `tick NAME`: `mark tick NAME`, then writes the four required per-tick files: `checks/NAME-check.txt`, `checks/NAME-check-proxy.txt` (both with `--wait 20s`, run in parallel), `metrics/NAME.txt`, `pods/NAME.txt`.
  - `snap_pod_detail NAME APP`: `pods/NAME-<pod>.yaml` and `pods/NAME-<pod>-describe.txt` for every pod with `app=APP`.
  - `snap_secret NAME`: `secrets/NAME-identity-issuer.txt`, holding `uid`, `resourceVersion`, and `cert_meta` of `crt.pem`. `key.pem` is never read.
  - `snap_trust NAME`: `trust/NAME.txt` in the Task 4 trust format.
  - `snap_logs NAME`: `logs/NAME/`, holding identity controller and identity proxy logs, plus every lab pod's containers (current and `--previous`).
  - `snap_events NAME`: `events/NAME.txt`. Kubernetes drops events after an hour, so scenarios call this twice.
  - `snap_journal NAME SINCE_EPOCH`: `logs/NAME/k3s-journal.txt`.
  - `snap_probes`: `probes/<probe>.log` for the three probes (full logs).
  - `write_versions SCENARIO CERT_SET`: writes `versions.txt`, once.
  - `write_cert NAME PEM_FILE`: `certs/NAME.pem` (the certificate only) and `certs/NAME.txt` (`step certificate inspect` + `cert_meta`). Dies if the file contains a private key.
  - `assert_no_keys`: dies if any file under `RUN_DIR` contains `PRIVATE KEY`.

- [ ] **Step 1: Write `demos/cert-hygiene/lab/collect.sh`**

```bash
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

_metrics_section() { # NS POD PORT FILTER-REGEX
  local body rc=0
  printf '== %s/%s :%s\n' "$1" "$2" "$3"
  body="$(kubectl get --raw "/api/v1/namespaces/$1/pods/$2:$3/proxy/metrics" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[metrics fetch failed: exit %s] %s\n' "$rc" "$(printf '%s' "$body" | tr '\n' ' ')"
  else
    printf '%s\n' "$body" | grep -E "$4" || printf '[no series matching %s]\n' "$4"
  fi
}

snap_metrics() { # NAME: identity-related series for every lab proxy + the issuer TTL
  local f="$RUN_DIR/metrics/$1.txt" pod idpod
  mkdir -p "$RUN_DIR/metrics"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    for pod in $(_lab_pods); do _metrics_section "$LAB_NS" "$pod" 4191 '^identity_'; done
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
```

- [ ] **Step 2: Write `demos/cert-hygiene/lab/snapshot-once.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. One full snapshot of the current lab into a fresh directory,
# using every collector function once. For exercising the collector and for poking
# at a lab by hand; it is not scenario evidence. Usage: snapshot-once.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"

RUN_DIR="${1:?usage: snapshot-once.sh <out-dir>}"
[ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists; refusing to overwrite"
mkdir -p "$RUN_DIR"
since="$(date -u +%s)"
certs="$(ls -dt "$CERTS_ROOT"/*/ | head -n 1)"
[ -n "$certs" ] || die "no cert set under $CERTS_ROOT; run a reset first"

mark snapshot-start
write_versions snapshot-once "$(basename "$certs")"
write_cert trust-anchor "$certs/ca.crt"
write_cert issuer-initial "$certs/issuer.crt"
tick manual
snap_secret manual
snap_trust manual
snap_pod_detail manual restart-target
snap_logs manual
snap_events manual
snap_journal manual "$(( since - 600 ))"
snap_probes
assert_no_keys
mark done
log "snapshot written to $RUN_DIR"
```

- [ ] **Step 3: Add `snapshot` to `demos/cert-hygiene/Justfile`**

Append:

```just

# One full evidence snapshot of the current lab into .lab-logs/ (not evidence)
snapshot:
    bash scripts/in-lab.sh lab/snapshot-once.sh .lab-logs/snapshot-$(date -u +%Y%m%dT%H%M%SZ)
```

- [ ] **Step 4: Syntax-check and shellcheck**

Run: `cd demos/cert-hygiene && bash -n lab/collect.sh && bash -n lab/snapshot-once.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/collect.sh lab/snapshot-once.sh'`
Expected: no output.

- [ ] **Step 5: Snapshot a healthy lab**

Task 6 left a `long`-mode lab with baseline workloads. If it's gone, run `just demo cert-hygiene reset long` and `just demo cert-hygiene deploy baseline` first.

Run: `just demo cert-hygiene snapshot`
Expected: ends with `[snapshot-once.sh] snapshot written to .lab-logs/snapshot-<stamp>`.

- [ ] **Step 6: Inspect the snapshot against the contracts**

Let `S` be the new directory under `demos/cert-hygiene/.lab-logs/`. Check each item:

- `timeline.log` has three lines: `snapshot-start`, `tick manual`, and `done`.
- `checks/manual-check.txt` and `checks/manual-check-proxy.txt` start with `$ linkerd check` and end `[exit 0]`.
- `metrics/manual.txt` has a `sampled_at_epoch=` line, one `== lab/<pod> :4191` section per lab pod containing a `$LEAF_EXPIRY_METRIC` line, and a `== linkerd/<pod> :9990` section containing `issuer_cert_ttl_seconds`.
- `pods/manual.txt` lists pods, and there is one `pods/manual-restart-target-*.yaml` with its `-describe.txt`.
- `secrets/manual-identity-issuer.txt` has `uid=`, `resourceVersion=`, `serial=`, and `notAfter=`.
- `trust/manual.txt` starts `configmap_sha256=` followed by 64 hex characters. Every `lab/` pod line carries the same non-`-` annotation.
- `versions.txt` has `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `retry_config_count=0`, and `config_LEAF_LIFETIME=5m`.
- `probes/` has three non-empty logs, and `logs/manual/` has identity and per-pod files.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh; S=$(ls -dt .lab-logs/snapshot-* | head -1); leaf_lifetime_check "$LEAF_EXPIRY_METRIC" "$(date -u +%s)" 400 "$S/metrics/manual.txt"; echo "leaf_check=$?"; trust_invariant_check "$S/trust/manual.txt" "$S/trust/manual.txt"; echo "trust_check=$?"'`
Expected: one `ok …` line per lab pod, then `leaf_check=0`; then `ok: trust configuration identical across 2 snapshots` and `trust_check=0`. This proves the collector's output feeds Task 4's checks.

Run: `grep -rl 'PRIVATE KEY' demos/cert-hygiene/.lab-logs || echo none`
Expected: `none`.

- [ ] **Step 7: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` row to `In progress: evidence collector verified on a live lab (plan Task 7 of 10)`.

```bash
git add demos/cert-hygiene/lab/collect.sh demos/cert-hygiene/lab/snapshot-once.sh demos/cert-hygiene/Justfile docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene add evidence collector"
git push
```
