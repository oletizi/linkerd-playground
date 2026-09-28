# Task 6: Workloads, probes, and discovery

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** Deploy the spec § 2 workloads (server, three probes, restart target) and make their output match the probe contract. Then run a discovery pass that settles two open questions (spec § 7):
- the exported names of the proxy identity metrics
- whether each new application connection to the opaque port gets its own proxy-to-proxy connection

**This task has a stop gate.** If the opaque-port assumption is false, stop and report. The probe design has to be revised before any scenario runs.

**Files:**
- Create: `demos/cert-hygiene/lab/workloads/namespace.yaml`, `demos/cert-hygiene/lab/workloads/baseline.yaml`, `demos/cert-hygiene/lab/workloads/probe-new.yaml`
- Create: `demos/cert-hygiene/lab/probes/probe-http.sh`, `probe-tcp-new.sh`, `probe-tcp-stream.sh`, `stream-session.sh`
- Create: `demos/cert-hygiene/lab/deploy.sh`, `demos/cert-hygiene/lab/discover.sh`
- Create (output, committed): `demos/cert-hygiene/runs/_discovery/<UTC>/` including `FINDINGS.md`
- Modify: `demos/cert-hygiene/config.example.env` (add `LEAF_EXPIRY_METRIC`, `ISSUER_TTL_METRIC`)
- Modify: `demos/cert-hygiene/Justfile` (add `deploy`, `discover`)
- Modify: `docs/superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md` (§ 7 rows → resolved)

**Interfaces:**
- Consumes: `lab/lib-lab.sh` (`require_pinned_images`, `LAB_DIR`, config), `lab/reset.sh` (Task 5)
- Produces (names later tasks rely on):
  - Namespace `$LAB_NS` (`lab`), meshed through the `linkerd.io/inject: enabled` annotation.
  - Deployments, each with label `app=<name>` and one replica: `server` (containers `http`, `echo`), `probe-http`, `probe-tcp-new`, `probe-tcp-stream` (container `probe` each), `restart-target` (container `idle`), and `probe-new` (container `idle`, only when deployed).
  - Service `server`: port 8080 (http) and port 9000 (echo, opaque).
  - ConfigMap `lab-probes`, built from `lab/probes/`.
  - Probe line contract, on the `probe` container's stdout: `<UTC ISO-8601> <probe> seq=<n> [conn=<id>] <ok|fail|connect|closed> <detail>`.
  - `lab/deploy.sh <baseline|probe-new>`. `baseline` waits for all five rollouts; `probe-new` applies without waiting.
  - Config: `LEAF_EXPIRY_METRIC`, the proxy's leaf-expiry gauge name as discovered; `ISSUER_TTL_METRIC=issuer_cert_ttl_seconds`.

- [ ] **Step 1: Write `demos/cert-hygiene/lab/workloads/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_NS}
  annotations:
    linkerd.io/inject: enabled
```

- [ ] **Step 2: Write `demos/cert-hygiene/lab/workloads/baseline.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: server
  namespace: ${LAB_NS}
  annotations:
    config.linkerd.io/opaque-ports: "9000"
spec:
  selector:
    app: server
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: echo
      port: 9000
      targetPort: 9000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: server
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: server
  template:
    metadata:
      labels:
        app: server
      annotations:
        config.linkerd.io/opaque-ports: "9000"
    spec:
      containers:
        - name: http
          image: ${IMAGE_BUSYBOX}
          command: ["sh", "-c", "mkdir -p /www && echo ok > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
        - name: echo
          image: ${IMAGE_SOCAT}
          args: ["TCP-LISTEN:9000,fork,reuseaddr", "EXEC:cat"]
          ports:
            - containerPort: 9000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-http
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-http
  template:
    metadata:
      labels:
        app: probe-http
    spec:
      containers:
        - name: probe
          image: ${IMAGE_CURL}
          command: ["sh", "/probes/probe-http.sh"]
          env:
            - name: TARGET_URL
              value: http://server.${LAB_NS}.svc.cluster.local:8080/
            - name: PROBE_INTERVAL_S
              value: "${PROBE_INTERVAL_S}"
          volumeMounts:
            - name: probes
              mountPath: /probes
      volumes:
        - name: probes
          configMap:
            name: lab-probes
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-tcp-new
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-tcp-new
  template:
    metadata:
      labels:
        app: probe-tcp-new
    spec:
      containers:
        - name: probe
          image: ${IMAGE_SOCAT}
          command: ["sh", "/probes/probe-tcp-new.sh"]
          env:
            - name: TARGET_HOST
              value: server.${LAB_NS}.svc.cluster.local
            - name: TARGET_PORT
              value: "9000"
            - name: PROBE_INTERVAL_S
              value: "${PROBE_INTERVAL_S}"
          volumeMounts:
            - name: probes
              mountPath: /probes
      volumes:
        - name: probes
          configMap:
            name: lab-probes
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-tcp-stream
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-tcp-stream
  template:
    metadata:
      labels:
        app: probe-tcp-stream
    spec:
      containers:
        - name: probe
          image: ${IMAGE_SOCAT}
          command: ["sh", "/probes/probe-tcp-stream.sh"]
          env:
            - name: TARGET_HOST
              value: server.${LAB_NS}.svc.cluster.local
            - name: TARGET_PORT
              value: "9000"
            - name: PROBE_INTERVAL_S
              value: "${PROBE_INTERVAL_S}"
            - name: POD_UID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.uid
          volumeMounts:
            - name: probes
              mountPath: /probes
      volumes:
        - name: probes
          configMap:
            name: lab-probes
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: restart-target
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: restart-target
  template:
    metadata:
      labels:
        app: restart-target
    spec:
      containers:
        - name: idle
          image: ${IMAGE_BUSYBOX}
          command: ["sh", "-c", "while :; do sleep 3600; done"]
```

- [ ] **Step 3: Write `demos/cert-hygiene/lab/workloads/probe-new.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-new
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-new
  template:
    metadata:
      labels:
        app: probe-new
    spec:
      containers:
        - name: idle
          image: ${IMAGE_BUSYBOX}
          command: ["sh", "-c", "while :; do sleep 3600; done"]
```

- [ ] **Step 4: Write `demos/cert-hygiene/lab/probes/probe-http.sh`**

```sh
#!/bin/sh
# One HTTP request to the lab server per attempt. No client retries (a single curl,
# no --retry); connection reuse between proxies stays on, deliberately: this is what an
# ordinary application sees. Output: <UTC> probe-http seq=<n> <ok|fail> <detail>
: "${TARGET_URL:?}" "${PROBE_INTERVAL_S:?}"
seq=0
while :; do
  seq=$((seq + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$TARGET_URL" 2>/tmp/curl.err)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
    echo "$ts probe-http seq=$seq ok http=$code"
  else
    echo "$ts probe-http seq=$seq fail curl_rc=$rc http=$code err=$(tr '\n' ' ' < /tmp/curl.err)"
  fi
  sleep "$PROBE_INTERVAL_S"
done
```

- [ ] **Step 5: Write `demos/cert-hygiene/lab/probes/probe-tcp-new.sh`**

```sh
#!/bin/sh
# A NEW TCP connection to the opaque echo port on every attempt: send one line, expect
# it back, close. Output: <UTC> probe-tcp-new seq=<n> <ok|fail> <detail>
: "${TARGET_HOST:?}" "${TARGET_PORT:?}" "${PROBE_INTERVAL_S:?}"
seq=0
while :; do
  seq=$((seq + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reply="$(echo "seq=$seq" | socat -t 2 -T 3 - "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=3" 2>/tmp/socat.err)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$reply" = "seq=$seq" ]; then
    echo "$ts probe-tcp-new seq=$seq ok"
  else
    echo "$ts probe-tcp-new seq=$seq fail socat_rc=$rc reply=$reply err=$(tr '\n' ' ' < /tmp/socat.err)"
  fi
  sleep "$PROBE_INTERVAL_S"
done
```

- [ ] **Step 6: Write `demos/cert-hygiene/lab/probes/probe-tcp-stream.sh`**

```sh
#!/bin/sh
# ONE TCP connection to the opaque echo port, held for the pod's life. FAILS CLOSED:
# when the connection ends it logs that and idles -- it never reconnects, so every ok
# line after an expiry belongs to the connection opened before it. The conn id embeds
# the pod UID and connect time, so even a container restart shows up as a new id.
: "${TARGET_HOST:?}" "${TARGET_PORT:?}" "${PROBE_INTERVAL_S:?}" "${POD_UID:?}"
CONN="$(echo "$POD_UID" | cut -c1-8)-$(date -u +%s)"
export CONN PROBE_INTERVAL_S
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) probe-tcp-stream seq=0 conn=$CONN connect target=$TARGET_HOST:$TARGET_PORT"
socat "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=5" "EXEC:sh /probes/stream-session.sh"
rc=$?
last="$(cat /tmp/stream.seq 2>/dev/null || echo 0)"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) probe-tcp-stream seq=$last conn=$CONN closed socat_rc=$rc fail-closed, not reconnecting"
while :; do sleep 3600; done
```

- [ ] **Step 7: Write `demos/cert-hygiene/lab/probes/stream-session.sh`**

```sh
#!/bin/sh
# Runs under socat EXEC: stdin/stdout ARE the TCP connection; log lines go to stderr
# (the container log). One exchange per interval. A read that fails well before its
# timeout means end-of-stream: the connection is gone, so exit and let the caller log it.
seq=0
while :; do
  seq=$((seq + 1))
  echo "$seq" > /tmp/stream.seq
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start="$(date -u +%s)"
  echo "seq=$seq" || { echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail write-error" >&2; exit 1; }
  if read -r -t 5 reply; then
    if [ "$reply" = "seq=$seq" ]; then
      echo "$ts probe-tcp-stream seq=$seq conn=$CONN ok" >&2
    else
      echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail unexpected-reply=$reply" >&2
    fi
  else
    rc=$?
    if [ $(( $(date -u +%s) - start )) -lt 4 ]; then
      echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail end-of-stream read_rc=$rc" >&2
      exit 0
    fi
    echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail no-reply-within-5s read_rc=$rc" >&2
  fi
  sleep "$PROBE_INTERVAL_S"
done
```

- [ ] **Step 8: Write `demos/cert-hygiene/lab/deploy.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. Renders and applies the lab workloads.
# Usage: deploy.sh <baseline|probe-new>
#   baseline:  namespace, probe-script ConfigMap, server, the three probes and
#              restart-target; waits for every rollout.
#   probe-new: the workload first created after T_iss. Applied WITHOUT waiting: after
#              issuer expiry it is expected never to become Ready.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
what="${1:?usage: deploy.sh <baseline|probe-new>}"
require_pinned_images
export LAB_NS IMAGE_CURL IMAGE_SOCAT IMAGE_BUSYBOX PROBE_INTERVAL_S

render() { # workload-file-stem; substitutes only the listed variables
  # shellcheck disable=SC2016
  envsubst '${LAB_NS} ${IMAGE_CURL} ${IMAGE_SOCAT} ${IMAGE_BUSYBOX} ${PROBE_INTERVAL_S}' < "$LAB_DIR/workloads/$1.yaml"
}

case "$what" in
  baseline)
    render namespace | kubectl apply -f -
    kubectl -n "$LAB_NS" create configmap lab-probes --from-file="$LAB_DIR/probes" \
      --dry-run=client -o yaml | kubectl apply -f -
    render baseline | kubectl apply -f -
    for d in server probe-http probe-tcp-new probe-tcp-stream restart-target; do
      kubectl -n "$LAB_NS" rollout status "deploy/$d" --timeout=5m
    done
    ;;
  probe-new)
    render probe-new | kubectl apply -f -
    ;;
  *) die "usage: deploy.sh <baseline|probe-new>" ;;
esac
```

- [ ] **Step 9: Write `demos/cert-hygiene/lab/discover.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a lab with baseline workloads deployed. Answers the
# design's open lab questions from raw data: which identity metrics the proxy and the
# identity controller export, and which proxy counters grow per probe attempt.
# Usage: discover.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
out="${1:?usage: discover.sh <out-dir>}"
[ ! -e "$out" ] || die "$out exists; refusing to overwrite"
mkdir -p "$out"
apps=(probe-http probe-tcp-new probe-tcp-stream server restart-target)

pod_of() { kubectl -n "$LAB_NS" get pod -l "app=$1" -o jsonpath='{.items[0].metadata.name}'; }
metrics() { kubectl get --raw "/api/v1/namespaces/$1/pods/$2:$3/proxy/metrics"; }
idpod="$(kubectl -n linkerd get pod -l linkerd.io/control-plane-component=identity -o jsonpath='{.items[0].metadata.name}')"

snap() { # label
  local app
  for app in "${apps[@]}"; do metrics "$LAB_NS" "$(pod_of "$app")" 4191 > "$out/$app-$1.txt"; done
  metrics linkerd "$idpod" 9990 > "$out/identity-$1.txt"
}

snap t0
sleep 30
snap t1
for app in probe-http probe-tcp-new probe-tcp-stream; do
  kubectl -n "$LAB_NS" logs "deploy/$app" -c probe --since=40s > "$out/$app.log"
done

# Every sample whose value changed between t0 and t1: "<delta> <series>".
for app in "${apps[@]}"; do
  awk 'FNR == NR && !/^#/ { k = $0; sub(/ [^ ]+$/, "", k); a[k] = $NF; next }
       !/^#/ { k = $0; sub(/ [^ ]+$/, "", k); if ((k in a) && $NF != a[k]) print $NF - a[k], k }' \
    "$out/$app-t0.txt" "$out/$app-t1.txt" | sort -k2 > "$out/$app-delta.txt"
done

# Metric names mentioning identity or issuer, from the proxies and the controller.
cat "$out"/*-t1.txt | awk '!/^#/ { n = $1; sub(/\{.*/, "", n); print n }' \
  | grep -i -e identity -e issuer | sort -u > "$out/identity-metric-names.txt"
log "discovery data in $out"
```

- [ ] **Step 10: Add `deploy` and `discover` to `demos/cert-hygiene/Justfile`**

Append:

```just

# Deploy lab workloads into the current lab cluster (WHAT: baseline | probe-new)
deploy WHAT="baseline":
    bash scripts/in-lab.sh lab/deploy.sh {{WHAT}}

# Record raw data answering the design's open lab questions (spec section 7)
discover:
    bash scripts/in-lab.sh lab/discover.sh runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)
```

- [ ] **Step 11: Syntax-check and shellcheck**

Run: `cd demos/cert-hygiene && for f in lab/deploy.sh lab/discover.sh lab/probes/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/deploy.sh lab/discover.sh && shellcheck -s sh lab/probes/*.sh'`
Expected: no output.

- [ ] **Step 12: Start from a long-lived lab and deploy**

Use `long` mode: a short issuer from an earlier reset may already have expired.

Run: `just demo cert-hygiene reset long`, then `just demo cert-hygiene deploy baseline`
Expected: both exit 0, with five `successfully rolled out` lines.

- [ ] **Step 13: Verify the probe contract**

After about 20 seconds, run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'for d in probe-http probe-tcp-new probe-tcp-stream; do kubectl -n lab logs deploy/$d -c probe --tail=3; done'`
Expected, one example per probe:

```
2026-09-10T15:00:01Z probe-http seq=10 ok http=200
2026-09-10T15:00:01Z probe-tcp-new seq=10 ok
2026-09-10T15:00:01Z probe-tcp-stream seq=10 conn=1a2b3c4d-1789050000 ok
```

Every line must match `^[0-9-]+T[0-9:]+Z probe-[a-z-]+ seq=[0-9]+ ` followed by `ok`, with `conn=` present only on stream lines. The stream log must contain exactly one `connect` line: `kubectl -n lab logs deploy/probe-tcp-stream -c probe | grep -c ' connect '` prints `1`.

- [ ] **Step 14: Run discovery**

Run: `just demo cert-hygiene discover`
Expected: `[discover.sh] discovery data in runs/_discovery/<stamp>`.

- [ ] **Step 15: Interpret it and write `runs/_discovery/<stamp>/FINDINGS.md`**

Read the files in the discovery directory and answer three questions. Quote the exact lines you rely on.

1. **Leaf-expiry metric name.** From `identity-metric-names.txt` and `probe-http-t1.txt`, which gauge carries the workload certificate's expiry time (source stem `expiration_timestamp`)? Its value must be an epoch roughly `LEAF_LIFETIME` ahead. Also name the refresh-count and refresh-time series. Confirm that `issuer_cert_ttl_seconds` is present in `identity-t1.txt`.
2. **Opaque-port connections.** Count the `ok` lines in `probe-tcp-new.log` that fall within the 30s window. In `probe-tcp-new-delta.txt`, find an **outbound TLS connection-open counter** whose delta roughly equals that count. **The assumption holds** if one exists. **It fails** if no connection counter grows with attempts (connections are being reused).
3. **HTTP pooling, for context.** Compare `probe-http-delta.txt`: its request counters should grow with attempts while its connection-open counter stays near 0. Record what you see; either way, it is context, not a gate.

In `FINDINGS.md`, write one heading per question with the quoted lines and a one-sentence answer.

**STOP GATE:** if question 2's answer is "fails", commit the discovery data and `FINDINGS.md`, then stop and report to the user. Don't continue to Task 7.

- [ ] **Step 16: Record the answers in config and spec**

Add to `demos/cert-hygiene/config.example.env`, using the name found in question 1:

```bash

# ---- Metrics (confirmed by lab/discover.sh; see runs/_discovery/) ----
LEAF_EXPIRY_METRIC=<gauge name from FINDINGS.md question 1>
ISSUER_TTL_METRIC=issuer_cert_ttl_seconds
```

In the spec's § 7 table, change the "Resolved by" cell of the "Opaque-port connection-per-connection behavior" and "Exported proxy identity metric names" rows to `Resolved: <one-line answer>, see demos/cert-hygiene/runs/_discovery/<stamp>/FINDINGS.md`. Change the "OrbStack home mount" row to `Resolved: mounted at the same path (Task 1 lab-up check)`.

- [ ] **Step 17: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` row to `In progress: probes live; metric names and opaque-port behaviour confirmed (plan Task 6 of 10)`.

```bash
git add demos/cert-hygiene/lab/workloads demos/cert-hygiene/lab/probes demos/cert-hygiene/lab/deploy.sh demos/cert-hygiene/lab/discover.sh demos/cert-hygiene/runs/_discovery demos/cert-hygiene/config.example.env demos/cert-hygiene/Justfile docs/superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene add lab workloads and probes; confirm metric names and opaque-port behaviour"
git push
```
