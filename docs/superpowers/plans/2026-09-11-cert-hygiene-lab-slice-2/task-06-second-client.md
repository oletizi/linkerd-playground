# Task 6: Second forced-new-connection client

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Add `probe-tcp-new-b`, a second client identical to `probe-tcp-new` that opens a new connection to `server`'s opaque port on every attempt (design § 1.5). Restarting client A, then `server`, then everything fills all four client/server certificate-state combinations in one run. The probe script takes its name from `PROBE_NAME` so each client's lines are distinguishable. `probe-tcp-new-b` is part of the baseline, so the control and every scenario include it. A discovery pass confirms it meets the probe line contract and opens one proxy-to-proxy connection per attempt (design § 10).

**Files:**
- Modify: `demos/cert-hygiene/lab/probes/probe-tcp-new.sh` (`PROBE_NAME`)
- Modify: `demos/cert-hygiene/lab/workloads/baseline.yaml` (`PROBE_NAME` for `probe-tcp-new`; new Deployment `probe-tcp-new-b`)
- Modify: `demos/cert-hygiene/lab/deploy.sh`, `demos/cert-hygiene/lab/discover.sh`, `demos/cert-hygiene/lab/scenario-common.sh` (`PROBES`), `demos/cert-hygiene/lab/collect-logs.sh` (`snap_probes` selector), `demos/cert-hygiene/lab/lib-evidence-control.sh` (probe list), `demos/cert-hygiene/lab/tests/test-control.sh`
- Create (discovery, committed): `demos/cert-hygiene/runs/_discovery/<stamp>/` (from `discover.sh`) with `FINDINGS.md`

**Interfaces:**
- Consumes: slice-1 workloads and probe line contract (`<UTC ISO-8601> <probe> seq=<n> [conn=<id>] <ok|fail|connect|closed> <detail>`).
- Produces:
  - Deployment `probe-tcp-new-b` (label `app=probe-tcp-new-b`, container `probe`, env `PROBE_NAME=probe-tcp-new-b`, `TARGET_HOST=server.<ns>.svc.cluster.local`, `TARGET_PORT=9000`).
  - Probe lines `<UTC> probe-tcp-new-b seq=<n> <ok|fail> <detail>`.
  - The lab's probe set, used everywhere a list appears: `probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream`.

- [ ] **Step 1: Failing test for the control's probe list**

In `demos/cert-hygiene/lab/tests/test-control.sh`, inside `make_ctl`, after the line writing `probe-tcp-new-1.log`, add:

```bash
  printf '2026-09-10T10:05:01Z probe-tcp-new-b seq=2 ok\n' > "$p/probe-tcp-new-b-1.log"
```

and before `finish test-control`, add:

```bash
make_ctl "$T/ccb"; rm "$T/ccb/probes/final/probe-tcp-new-b-1.log"
assert_fails "the control needs the second client's lines" control_criteria_check "$T/ccb"
make_ctl "$T/ccb2"; printf '2026-09-10T10:20:00Z probe-tcp-new-b seq=9 fail socat_rc=1\n' >> "$T/ccb2/probes/final/probe-tcp-new-b-1.log"
assert_fails "a second-client failure after baseline breaks the control" control_criteria_check "$T/ccb2"
```

Run: `just demo cert-hygiene test`
Expected: `test-control` fails on "the control needs the second client's lines".

- [ ] **Step 2: Add the client to the control's probe list**

In `demos/cert-hygiene/lab/lib-evidence-control.sh`, `control_criteria_check`, change `for p in probe-http probe-tcp-new probe-tcp-stream; do` to:

```bash
  for p in probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream; do
```

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 3: Parameterise `demos/cert-hygiene/lab/probes/probe-tcp-new.sh`**

```sh
#!/bin/sh
# A NEW TCP connection to the opaque echo port on every attempt: send one line, expect
# it back, close. Two Deployments run it (probe-tcp-new, probe-tcp-new-b), told apart by
# PROBE_NAME. Output: <UTC> <PROBE_NAME> seq=<n> <ok|fail> <detail>
: "${PROBE_NAME:?}" "${TARGET_HOST:?}" "${TARGET_PORT:?}" "${PROBE_INTERVAL_S:?}"
seq=0
while :; do
  seq=$((seq + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reply="$(echo "seq=$seq" | socat -t 2 -T 3 - "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=3" 2>/tmp/socat.err)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$reply" = "seq=$seq" ]; then
    echo "$ts $PROBE_NAME seq=$seq ok"
  else
    echo "$ts $PROBE_NAME seq=$seq fail socat_rc=$rc reply=$reply err=$(tr '\n' ' ' < /tmp/socat.err)"
  fi
  sleep "$PROBE_INTERVAL_S"
done
```

- [ ] **Step 4: Update `demos/cert-hygiene/lab/workloads/baseline.yaml`**

In the `probe-tcp-new` Deployment's `env:` list, add as the first entry:

```yaml
            - name: PROBE_NAME
              value: probe-tcp-new
```

Insert this Deployment immediately after the `probe-tcp-new` Deployment (before the `---` that precedes `probe-tcp-stream`):

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-tcp-new-b
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-tcp-new-b
  template:
    metadata:
      labels:
        app: probe-tcp-new-b
    spec:
      containers:
        - name: probe
          image: ${IMAGE_SOCAT}
          command: ["sh", "/probes/probe-tcp-new.sh"]
          env:
            - name: PROBE_NAME
              value: probe-tcp-new-b
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
```

- [ ] **Step 5: Add the client to every probe list**

- `demos/cert-hygiene/lab/deploy.sh`: change `for d in server probe-http probe-tcp-new probe-tcp-stream restart-target; do` to `for d in server probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream restart-target; do`, and in the header comment change "the three probes" to "the four probes".
- `demos/cert-hygiene/lab/discover.sh`: change `apps=(probe-http probe-tcp-new probe-tcp-stream server restart-target)` to `apps=(probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream server restart-target)` and `for app in probe-http probe-tcp-new probe-tcp-stream; do` to `for app in probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream; do`. Also make each snapshot record its time: in `snap()`, add as its first line `date -u +%Y-%m-%dT%H:%M:%SZ > "$out/$1.utc"`.
- `demos/cert-hygiene/lab/scenario-common.sh`: change `PROBES=(probe-http probe-tcp-new probe-tcp-stream)` to `PROBES=(probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream)`.
- `demos/cert-hygiene/lab/collect-logs.sh`, `snap_probes`: change `sel='app in (probe-http,probe-tcp-new,probe-tcp-stream)'` to `sel='app in (probe-http,probe-tcp-new,probe-tcp-new-b,probe-tcp-stream)'`.

- [ ] **Step 6: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && for f in lab/*.sh lab/probes/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh scenarios/*.sh && shellcheck -s sh lab/probes/*.sh'`
Expected: no output.

- [ ] **Step 7: Discovery — does `probe-tcp-new-b` meet the probe line contract?**

Run: `just demo cert-hygiene reset long` (repeat the wait if it times out), then `just demo cert-hygiene deploy baseline`.
Expected: six `successfully rolled out` lines, including `deployment "probe-tcp-new-b" successfully rolled out`.

After about 20 seconds, run: `just demo cert-hygiene discover`
Expected: `[discover.sh] discovery data in runs/_discovery/<stamp>`.

Let `D=demos/cert-hygiene/runs/_discovery/<stamp>`. Check:
1. **Line contract.** Every line of `$D/probe-tcp-new-b.log` matches `^[0-9-]+T[0-9:]+Z probe-tcp-new-b seq=[0-9]+ ok$`: `grep -cvE '^[0-9-]+T[0-9:]+Z probe-tcp-new-b seq=[0-9]+ ok$' $D/probe-tcp-new-b.log` prints `0`, and `wc -l < $D/probe-tcp-new-b.log` is at least 10. `$D/probe-tcp-new.log` still names `probe-tcp-new` in field 2.
2. **One connection per attempt.** Count the attempts inside the snapshot window: `awk -v a="$(cat $D/t0.utc)" -v b="$(cat $D/t1.utc)" '$1 >= a && $1 <= b && / ok$/' $D/probe-tcp-new-b.log | wc -l`. `$D/probe-tcp-new-b-delta.txt` holds lines of the form `<delta> <series>`. Take the line whose second field starts `tcp_open_total{direction="outbound",peer="dst",authority="server.lab.svc.cluster.local:9000"` and contains `tls="true"`: its first field, the delta, must be within 1 of that count (an attempt can straddle a snapshot boundary), as the slice-1 FINDINGS showed for `probe-tcp-new`.

Write `$D/FINDINGS.md` with the Write tool: one heading per check, the quoted lines, and one-sentence answers.

**If either check fails**, commit the discovery directory and stop: report to the user. The matrix in design § 2 depends on this client.

- [ ] **Step 8: Update the article README and commit**

No README status change.

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/runs/_discovery
git commit -m "cert-hygiene add a second forced-new-connection client"
git push
```
