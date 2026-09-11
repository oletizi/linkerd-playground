# Task 5: Collector additions

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** The rest of design § 1.4:
- webhook state per tick (`webhooks/<tick>.txt`);
- connection metrics alongside the identity series;
- control-plane pod identity and Deployment generations per tick (`controlplane/<tick>.txt`), including a hash of each Deployment's pod template (O's invariant, design § 4);
- `logs/<label>/pods.txt`, and a proxy-log rule driven by it, closing the parked "vacuous proxy-log rule" item: the slice-1 rule could pass when no lab pod's logs were captured at all.

Gate records (`gates/<stage>.txt`) come in Task 7. The k3s journal keeps being captured by `snap_journal` as supplementary evidence and is never a validity condition. APIService status is for V only and is not built (README, "Follow-up").

**Files:**
- Modify: `demos/cert-hygiene/lab/collect.sh` (`PROXY_METRIC_FILTER`; `tick`)
- Modify: `demos/cert-hygiene/lab/collect-state.sh` (add `snap_webhooks`, `snap_controlplane`)
- Modify: `demos/cert-hygiene/lab/collect-logs.sh` (`snap_logs` writes and follows `pods.txt`)
- Modify: `demos/cert-hygiene/lab/lib-evidence-rules.sh` (proxy-log rule reads `pods.txt`; drop `LAB_APP_CONTAINERS`)
- Modify: `demos/cert-hygiene/lab/tests/fixtures.sh`, `demos/cert-hygiene/lab/tests/test-rules.sh`

**Interfaces:**
- Consumes: Task 4 (`_cert_from_secret`, `WEBHOOK_COMPONENTS`, `webhook_secret`), `_record`, `capture`.
- Produces (file contracts):
  - `webhooks/<tick>.txt`: `sampled_at_epoch=`; one line per webhook in each configuration: `config <kind>/<name> webhook=<webhook name> failurePolicy=<Ignore|Fail> caBundle_sha256=<sha256 of the decoded caBundle, or ->`; then `secret_<component>_{sha256,serial,not_after_epoch,not_after,sans}=` per component.
  - `controlplane/<tick>.txt`: `sampled_at_epoch=`; `pod linkerd/<name> uid=<uid> start=<RFC3339|-> phase=<phase> ready=<True|False|-> restarts=<n> trust=<annotation|->` per pod; `deploy linkerd/<name> generation=<n> observedGeneration=<n|-> replicas=<n> readyReplicas=<n> template_sha256=<sha256 of the key-sorted .spec.template JSON>` per Deployment.
  - `logs/<label>/pods.txt`: one line per lab pod, `pod=<name> proxy=<yes|no> containers=<init and regular container names, comma-joined>`, or a `[lab pod listing failed: exit N] …` line. `snap_logs` captures exactly the pods and containers it lists.
  - `PROXY_METRIC_FILTER='^(identity_|control_identity_|tcp_open_total|tcp_close_total|tcp_open_connections|outbound_tcp_route_open_total|outbound_tcp_route_close_total)'` (design § 1.4; all five connection series are in `runs/_discovery/20260911T004528Z`).
  - `tick NAME` also writes `webhooks/NAME.txt` and `controlplane/NAME.txt`.
  - Proxy-log rule (in `_missing_proxy_logs RUN_DIR`), one reason per miss: `<label>: pods.txt missing`, `<label>: pods.txt records a failed listing`, `<label>: pods.txt lists no pod`, `<label>: <pod> has no <pod>-<container>.txt`. A pod listed `proxy=yes` therefore always needs `<pod>-linkerd-proxy.txt`; a pod listed `proxy=no` (W's un-injected pods) needs only its own containers' logs.

- [ ] **Step 1: Update the fixture and write the failing tests**

In `demos/cert-hygiene/lab/tests/fixtures.sh`, inside `make_run`, after the two `for f in …` loops that write `logs/`, add:

```bash
  printf 'pod=server-1 proxy=yes containers=linkerd-init,linkerd-proxy,http,echo\n' > "$d/logs/final/pods.txt"
  printf 'pod=probe-http-1 proxy=yes containers=linkerd-proxy,probe\n' > "$d/logs/pre-recover/pods.txt"
```

In `demos/cert-hygiene/lab/tests/test-rules.sh`, replace the line

```bash
assert_contains "$(reason "$T/noproxy")" "pre-recover: probe-http-1 has a probe log but no probe-http-1-linkerd-proxy.txt" "reason names the pod and label"
```

with

```bash
assert_contains "$(reason "$T/noproxy")" "pre-recover: probe-http-1 has no probe-http-1-linkerd-proxy.txt" "reason names the pod and label"
```

and insert this block immediately before `# ---- per-scenario rules ----`:

```bash
# ---- the proxy-log rule follows logs/<label>/pods.txt ----
make_run "$T/nolist" 00-baseline-control c1 h1 false
rm "$T/nolist/logs/final/pods.txt"
assert_fails "a log snapshot without pods.txt is invalid" evaluate_validity "$T/nolist" 00-baseline-control "$V"
assert_contains "$(reason "$T/nolist")" "final: pods.txt missing" "reason names the snapshot"
make_run "$T/badlist" 00-baseline-control c1 h1 false
printf '[lab pod listing failed: exit 1] connection refused\n' > "$T/badlist/logs/final/pods.txt"
assert_fails "a failed pod listing is invalid" evaluate_validity "$T/badlist" 00-baseline-control "$V"
make_run "$T/empty" 00-baseline-control c1 h1 false
: > "$T/empty/logs/final/pods.txt"
assert_fails "a snapshot listing no pod is invalid (the rule is never vacuous)" evaluate_validity "$T/empty" 00-baseline-control "$V"
make_run "$T/noapp" 00-baseline-control c1 h1 false
rm "$T/noapp/logs/final/server-1-echo.txt"
assert_fails "a listed container without its log is invalid" evaluate_validity "$T/noapp" 00-baseline-control "$V"
assert_contains "$(reason "$T/noapp")" "final: server-1 has no server-1-echo.txt" "reason names the container"
make_run "$T/uninjected" 02-webhook-expiry-ignore c2 h1 false
printf 'pod=inject-probe-post-3 proxy=no containers=idle\n' >> "$T/uninjected/logs/final/pods.txt"
echo x > "$T/uninjected/logs/final/inject-probe-post-3-idle.txt"
assert_succeeds "an un-injected pod needs no proxy log" evaluate_validity "$T/uninjected" 02-webhook-expiry-ignore "$V" "$T/ctl"
```

Run: `just demo cert-hygiene test`
Expected: `test-rules` fails (the new reasons are not produced yet); exit non-zero.

- [ ] **Step 2: Rewrite the proxy-log rule in `demos/cert-hygiene/lab/lib-evidence-rules.sh`**

Delete `LAB_APP_CONTAINERS` and the old `_missing_proxy_logs` (with their comments). Put in their place:

```bash
# _missing_proxy_logs RUN_DIR: the proxy-log rule. Every logs/<label>/ directory must
# hold pods.txt, the lab pods the snapshot captured (design section 1.4). Each listed
# container needs its <pod>-<container>.txt; a pod with proxy=yes lists linkerd-proxy
# (a native-sidecar init container), so its proxy log is always required. A snapshot
# that lists no pod fails, so the rule is never vacuous. Prints one line per miss.
_missing_proxy_logs() {
  local run="$1" dir label line pod containers c
  for dir in "$run"/logs/*/; do
    [ -d "$dir" ] || continue
    label="$(basename "$dir")"
    if [ ! -f "$dir/pods.txt" ]; then echo "$label: pods.txt missing"; continue; fi
    if grep -q '^\[' "$dir/pods.txt"; then echo "$label: pods.txt records a failed listing"; continue; fi
    if ! grep -q '^pod=' "$dir/pods.txt"; then echo "$label: pods.txt lists no pod"; continue; fi
    while read -r line; do
      pod="$(awk '{ print $1 }' <<< "$line")"; pod="${pod#pod=}"
      containers="$(awk '{ print $3 }' <<< "$line")"; containers="${containers#containers=}"
      for c in ${containers//,/ }; do
        [ -s "$dir$pod-$c.txt" ] || echo "$label: $pod has no $pod-$c.txt"
      done
    done < <(grep '^pod=' "$dir/pods.txt")
  done
  return 0
}
```

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 3: Connection metrics in `demos/cert-hygiene/lab/collect.sh`**

After the header comment, add:

```bash
# Proxy series recorded on every tick: identity (both prefixes, Ruling P1a) and the
# connection counters and gauges (design section 1.4).
PROXY_METRIC_FILTER='^(identity_|control_identity_|tcp_open_total|tcp_close_total|tcp_open_connections|outbound_tcp_route_open_total|outbound_tcp_route_close_total)'
```

Replace `_lab_pods` (now unused) with:

```bash
_lab_pod_mesh() { # "<pod> yes|no" per lab pod: does it have a linkerd-proxy container?
  kubectl -n "$LAB_NS" get pods -o json 2>/dev/null | jq -r '.items[]
    | "\(.metadata.name) \(if ([.spec.initContainers[]?.name, .spec.containers[].name] | index("linkerd-proxy")) then "yes" else "no" end)"' \
    || true
}
```

In `snap_metrics`, replace the `for pod in $(_lab_pods); do _metrics_section …` line with:

```bash
    while read -r pod meshed; do
      if [ "$meshed" = yes ]; then
        _metrics_section "$LAB_NS" "$pod" 4191 "$PROXY_METRIC_FILTER"
      else
        printf '== %s/%s :4191\n[no linkerd-proxy container: not scraped]\n' "$LAB_NS" "$pod"
      fi
    done < <(_lab_pod_mesh)
```

and change its comment to `# NAME: identity and connection series for every lab proxy + the issuer TTL`. A pod with no proxy (W's un-injected `inject-probe` pods) has no `:4191` endpoint, so it is listed rather than retried three times, which would slow every tick.

In `tick`, after `snap_credentials "$name"`, add:

```bash
  snap_trust "$name"
  snap_webhooks "$name"
  snap_controlplane "$name"
```

Each pod's trust-bundle hash is now recorded on every tick (design § 1.3, § 7), not only at three moments. In `demos/cert-hygiene/lab/scenario-common.sh`, `run_scenario`, delete the lines `snap_trust baseline` and `snap_trust verify`: the `baseline` and `verify` ticks now write those files, and evidence is written once. Keep `snap_trust pre-recover` (it is not a tick).

- [ ] **Step 4: Add `snap_webhooks` and `snap_controlplane` to `demos/cert-hygiene/lab/collect-state.sh`**

```bash
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
```

- [ ] **Step 5: `pods.txt` in `snap_logs` (`demos/cert-hygiene/lab/collect-logs.sh`)**

Replace `snap_logs` with:

```bash
snap_logs() { # NAME: identity logs, then every container of every lab pod listed in
  # logs/NAME/pods.txt. The linkerd-proxy is a native-sidecar INIT container, so both
  # container lists are walked; pods.txt makes the proxy-log rule non-vacuous.
  local dir="logs/$1" pod c tmp line containers
  mkdir -p "$RUN_DIR/$dir"
  capture "$dir/identity.txt" kubectl -n linkerd logs deploy/linkerd-identity -c identity --timestamps
  capture "$dir/identity-proxy.txt" kubectl -n linkerd logs deploy/linkerd-identity -c linkerd-proxy --timestamps
  tmp="$(mktemp)"
  if _record "lab pod listing" kubectl -n "$LAB_NS" get pods -o json > "$tmp"; then
    jq -r '.items[] | ([.spec.initContainers[]?.name] + [.spec.containers[].name]) as $c
      | "pod=\(.metadata.name) proxy=\(if ($c | index("linkerd-proxy")) then "yes" else "no" end) containers=\($c | join(","))"' \
      "$tmp" > "$RUN_DIR/$dir/pods.txt"
  else
    cp "$tmp" "$RUN_DIR/$dir/pods.txt"
  fi
  rm -f "$tmp"
  while read -r line; do
    pod="$(awk '{ print $1 }' <<< "$line")"; pod="${pod#pod=}"
    containers="$(awk '{ print $3 }' <<< "$line")"; containers="${containers#containers=}"
    for c in ${containers//,/ }; do
      capture "$dir/$pod-$c.txt" kubectl -n "$LAB_NS" logs "$pod" -c "$c" --timestamps
      capture "$dir/$pod-$c-previous.txt" kubectl -n "$LAB_NS" logs "$pod" -c "$c" --timestamps --previous
    done
  done < <(grep '^pod=' "$RUN_DIR/$dir/pods.txt" || true)
}
```

- [ ] **Step 6: Syntax, shellcheck, tests, line counts**

Run: `cd demos/cert-hygiene && for f in lab/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/collect*.sh lab/lib-evidence*.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh lab/tests/*.sh scenarios/*.sh'`
Expected: no errors, every file under 300 lines, no findings.

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 7: Exercise it against the live lab**

The lab from Task 4 Step 6 is still up (if not, repeat that step's reset and deploy). Run: `just demo cert-hygiene snapshot`, and let `S=demos/cert-hygiene/.lab-logs/snapshot-<stamp>`.

- `cat $S/webhooks/manual.txt` — three `config …` lines with `failurePolicy=Ignore` and a 64-hex `caBundle_sha256`, then five `secret_<component>_*` lines per component; no `[` line.
- `cat $S/controlplane/manual.txt` — a `pod linkerd/…` line per control-plane pod with `uid=` and `start=`, and `deploy linkerd/linkerd-identity … template_sha256=<hex>`, likewise for `linkerd-destination` and `linkerd-proxy-injector`.
- `grep -c '^tcp_open_total' $S/metrics/manual.txt` — a number greater than 0.
- `cat $S/logs/manual/pods.txt` — one `pod=… proxy=yes containers=…linkerd-proxy…` line per lab pod.
- `bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && _missing_proxy_logs .lab-logs/snapshot-<stamp>'` — no output.

- [ ] **Step 8: Commit**

```bash
git add demos/cert-hygiene/lab
git commit -m "cert-hygiene record webhook, connection and control-plane state; make the proxy-log rule follow pods.txt"
git push
```
