# Task 7: Restart-stage gates

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 1.6. After a restart stage, no probe sample counts until a gate has checked every restarted workload for five conditions:
1. **Ready:** the new pod is Ready and every pre-restart pod is gone.
2. **Serving:** where the workload has a Service of the same name (only `server`), the new pod is a ready endpoint in its EndpointSlice.
3. **Trust state:** the pod's `linkerd.io/trust-root-sha256` annotation equals the trust-roots ConfigMap's current hash. That is the trust state the credential plan puts on a pod restarted at this stage, because the proxy-injector reads the ConfigMap on every admission (source notes § 4).
4. **Certificate state:** its proxy's `control_identity_cert_refresh_timestamp_seconds` is after the pod's start time and its `control_identity_cert_expiration_timestamp_seconds` is in the future.
5. **Non-TLS readiness:** every application container is Ready.

Then each client→server pair gets `GATE_SAMPLES` fresh-connection samples, one `kubectl exec` of `sample-once.sh` in the client pod each, `GATE_SAMPLE_INTERVAL_S` apart (10 × 2 s by default). The samples classify the stage's cells. A gate that doesn't pass within `GATE_TIMEOUT_S` records `gate=timeout` and the unmet conditions; its cells are `unclassified`. That is a finding, never an invalid run.

**Design point resolved here:** the design says that "if the scenario predicts that it can't obtain [a leaf], the gate records that instead". No slice-2 stage makes that prediction: every gated stage restarts pods after a signer able to issue for them is in place. So every gate requires all five conditions, and every gate record carries the certificate state (refresh time, expiry, refresh counts) of each restarted pod on every poll, and of each pair's endpoints at sample time. A stage whose pods can't get a leaf therefore ends `gate=timeout` with `unmet=<deploy>:leaf`, and the write-up classifies the cell from those recorded values.

A discovery run measures how long healthy restarts take to pass the gate, and sets `GATE_TIMEOUT_S`.

**Files:**
- Create: `demos/cert-hygiene/lab/gates.sh`, `demos/cert-hygiene/lab/probes/sample-once.sh`, `demos/cert-hygiene/lab/discover-gates.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence-control.sh` (add `gate_summary`), `demos/cert-hygiene/lab/tests/test-control.sh`
- Modify: `demos/cert-hygiene/config.example.env` (gate settings), `demos/cert-hygiene/Justfile` (`discover-gates`)
- Create (discovery, committed): `demos/cert-hygiene/runs/_discovery/<stamp>-gates/` with `FINDINGS.md`

**Interfaces:**
- Consumes: collector (`mark`, `capture`, `_utc`), `LAB_NS`, Task 6's `probe-tcp-new-b`.
- Produces:
  - `GATE_PAIRS=("A probe-tcp-new server" "B probe-tcp-new-b server")`.
  - `lab_deployments` → lab Deployment names, one per line.
  - `restart_and_gate STAGE DEPLOY...`: records pre-restart pods, restarts the Deployments (the command's capture goes to `restarts/STAGE.txt`), polls the gate, then calls `stage_samples STAGE`. Timeline markers `restart <STAGE>: <deploys>` and `gate <STAGE> pass|timeout …`. `gates/` holds only gate records, so readers never select files by name. A stage may itself be named `…-restart`, as S-staged's are (Task 16).
  - Every cluster read in `gates.sh` tolerates failure. An unreadable ConfigMap, pod list or EndpointSlice yields `-` or nothing, which leaves a gate condition unmet and is recorded on the next `check` line. It never ends the run: the most likely moment for such a failure is a control-plane rollout, an hour into a run.
  - `stage_samples STAGE`: samples every pair and records cells. On a stage with no restarts it first writes a header with `gate=none` (marker `stage <STAGE>: samples, no restarts`).
  - `gates/<STAGE>.txt` contract, in order:
    - `stage=`, `restarted=<d1,d2|->`, `started_at=<UTC>`, `started_epoch=`
    - `before <deploy> <pod> <uid>` per pre-restart pod
    - `check <UTC> <deploy> pod=<pod|-> ready=<yes|no> old_gone=<yes|no> serving=<yes|no|n/a> trust=<yes|no> leaf=<yes|no> app_ready=<yes|no> refresh=<epoch|-> expiry=<epoch|-> unmet=<cond,…|->` per deployment per poll
    - `expected_trust_sha256=`, `gate=<pass|timeout|none>`, `unmet=<deploy:cond,…>` (timeout only), `gate_at=`, `gate_epoch=`
    - `sample <UTC> pair=<A|B> client=<pod> server=<pod> n=<i> ok|fail <detail>`
    - `cell pair=<A|B> ok=<n> fail=<n> status=<classified|unclassified>` after each pair's samples
    - `leaf <UTC> role=<clientA|clientB|server> pod=<pod> refresh=<epoch|-> expiry=<epoch|-> ok=<n|-> err=<n|->`
  - `gate_summary FILE` (pure) → `gate=<v> A=<ok>/<fail>/<status> B=<ok>/<fail>/<status>`; returns 1 when the file has no `gate=` line or no `cell` line.
  - Config: `GATE_TIMEOUT_S` (discovered), `GATE_POLL_S=5`, `GATE_SAMPLES=10`, `GATE_SAMPLE_INTERVAL_S=2`.

- [ ] **Step 1: Failing tests for `gate_summary`**

In `demos/cert-hygiene/lab/tests/test-control.sh`, before `finish test-control`, add:

```bash
# ---- gate_summary ----
gate_file() { # FILE GATE A_OK A_FAIL B_OK B_FAIL STATUS
  printf 'stage=s\nrestarted=server\nstarted_at=x\nstarted_epoch=1\ngate=%s\ngate_at=y\n' "$2" > "$1"
  printf 'sample t pair=A client=c server=s n=1 ok\n' >> "$1"
  printf 'cell pair=A ok=%s fail=%s status=%s\ncell pair=B ok=%s fail=%s status=%s\n' "$3" "$4" "$7" "$5" "$6" "$7" >> "$1"
}
gate_file "$T/g1.txt" pass 10 0 10 0 classified
assert_eq "$(gate_summary "$T/g1.txt")" "gate=pass A=10/0/classified B=10/0/classified" "passed gate summary"
gate_file "$T/g2.txt" timeout 3 7 0 10 unclassified
assert_eq "$(gate_summary "$T/g2.txt")" "gate=timeout A=3/7/unclassified B=0/10/unclassified" "timed-out gate summary"
printf 'stage=s\ncell pair=A ok=1 fail=0 status=classified\n' > "$T/g3.txt"
assert_fails "no gate line fails" gate_summary "$T/g3.txt"
printf 'stage=s\ngate=none\n' > "$T/g4.txt"
assert_fails "no cell line fails" gate_summary "$T/g4.txt"
```

Run: `just demo cert-hygiene test`
Expected: `test-control` fails with `gate_summary: command not found`.

- [ ] **Step 2: Implement `gate_summary` in `demos/cert-hygiene/lab/lib-evidence-control.sh`**

Append:

```bash
# gate_summary FILE: one line summarising a restart-stage gate record (gates/<stage>.txt):
# "gate=<pass|timeout|none> <pair>=<ok>/<fail>/<status> ...". Returns 1 if the record
# has no gate line or no cell line.
gate_summary() {
  local f="${1:?gate_summary: FILE required}" g cells
  g="$(awk -F= '$1 == "gate" { v = $2 } END { print v }' "$f" 2>/dev/null)"
  [ -n "$g" ] || { echo "fail: $f has no gate line"; return 1; }
  cells="$(awk '$1 == "cell" {
      split($2, p, "="); split($3, o, "="); split($4, x, "="); split($5, s, "=")
      printf " %s=%s/%s/%s", p[2], o[2], x[2], s[2] }' "$f")"
  [ -n "$cells" ] || { echo "fail: $f has no cell line"; return 1; }
  echo "gate=$g$cells"
}
```

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 3: Write `demos/cert-hygiene/lab/probes/sample-once.sh`**

```sh
#!/bin/sh
# One fresh TCP connection to the opaque echo port, for a restart-stage sample (design
# 1.6), run by kubectl exec in a client pod: send one line, expect it back, close.
# Prints "ok" or "fail <detail>"; always exits 0. TARGET_* come from the pod's env.
: "${TARGET_HOST:?}" "${TARGET_PORT:?}"
n="${1:?usage: sample-once.sh <n>}"
reply="$(echo "sample=$n" | socat -t 2 -T 3 - "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=3" 2>/tmp/sample.err)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$reply" = "sample=$n" ]; then
  echo ok
else
  echo "fail socat_rc=$rc reply=$reply err=$(tr '\n' ' ' < /tmp/sample.err)"
fi
```

`deploy.sh` builds the `lab-probes` ConfigMap from every file in `lab/probes/`, so the script reaches both clients with no manifest change.

- [ ] **Step 4: Write `demos/cert-hygiene/lab/gates.sh`**

```bash
#!/usr/bin/env bash
# Restart-stage gates and samples (design section 1.6). After a stage restarts its
# workloads, the gate waits until every restarted workload is Ready with its old pods
# gone, serving (where it has a Service of its own name), carrying the current trust
# bundle, holding a leaf obtained since it started, and with its application containers
# Ready. Then every client->server pair gets GATE_SAMPLES fresh-connection samples. A gate
# that times out leaves the stage's cells unclassified, with the unmet conditions; it
# never invalidates a run. Source after lab/collect.sh with RUN_DIR set; do not execute.

GATE_PAIRS=("A probe-tcp-new server" "B probe-tcp-new-b server") # pair client server

lab_deployments() { kubectl -n "$LAB_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }

_gate_file() { echo "$RUN_DIR/gates/$1.txt"; }
_yn() { if [ "$1" = "$2" ]; then echo yes; else echo no; fi; } # A B: yes when equal
_csv_or_dash() { if [ $# -eq 0 ]; then echo -; else (IFS=,; echo "$*"); fi; } # ITEM...

_trust_now() { # the trust-roots ConfigMap hash, as pods' trust-root-sha256 annotations
  # carry it (hashed from a file: a command substitution would strip the final newline);
  # "-" when unreadable, which leaves the trust condition unmet
  local tmp
  tmp="$(mktemp)"
  if kubectl -n linkerd get cm linkerd-identity-trust-roots -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp" 2>/dev/null; then
    sha256sum < "$tmp" | cut -d' ' -f1
  else
    echo -
  fi
  rm -f "$tmp"
}

_deploy_pods() { # DEPLOY: "name uid start_epoch deleting ready trust app_ready" per pod;
  # nothing when the pod list is unreadable
  local js
  js="$(kubectl -n "$LAB_NS" get pods -l "app=$1" -o json 2>/dev/null)" || return 0
  jq -r '.items[] | [
      .metadata.name, .metadata.uid,
      ((.status.startTime // "") | if . == "" then "0" else (fromdateiso8601 | tostring) end),
      (if .metadata.deletionTimestamp then "yes" else "no" end),
      (([.status.conditions[]? | select(.type == "Ready") | .status] | first) // "False"),
      (.metadata.annotations["linkerd.io/trust-root-sha256"] // "-"),
      (if ([.status.containerStatuses[]?.ready] | length) > 0 and ([.status.containerStatuses[]?.ready] | all)
       then "yes" else "no" end)
    ] | join(" ")' <<< "$js"
}

_current_pod() { _deploy_pods "$1" | awk '$4 == "no" { p = $1 } END { print p }'; } # DEPLOY

_leaf_state() { # POD: "refresh expiry ok err" from its proxy's metrics; "- - - -" if unreadable
  local body
  if ! body="$(kubectl get --raw "/api/v1/namespaces/$LAB_NS/pods/$1:4191/proxy/metrics" 2>/dev/null)"; then
    echo "- - - -"; return 0
  fi
  awk '$1 == "control_identity_cert_refresh_timestamp_seconds" { r = $2 }
       $1 == "control_identity_cert_expiration_timestamp_seconds" { e = $2 }
       $1 == "control_identity_cert_refreshes_total{result=\"ok\"}" { ok = $2 }
       $1 == "control_identity_cert_refreshes_total{result=\"error\"}" { er = $2 }
       END { printf "%s %s %s %s\n", (r == "" ? "-" : r), (e == "" ? "-" : e), (ok == "" ? "-" : ok), (er == "" ? "-" : er) }' <<< "$body"
}

_serving() { # DEPLOY POD: yes|no when a Service named DEPLOY exists, n/a otherwise
  local n
  kubectl -n "$LAB_NS" get svc "$1" >/dev/null 2>&1 || { echo n/a; return 0; }
  n="$(kubectl -n "$LAB_NS" get endpointslices -l "kubernetes.io/service-name=$1" -o json 2>/dev/null \
    | jq --arg p "$2" '[.items[].endpoints[]? | select(.targetRef.name == $p and .conditions.ready == true)] | length' || true)"
  if [ "${n:-0}" -gt 0 ]; then
    echo yes
  else
    echo no
  fi
}

_gate_check() { # STAGE DEPLOY TRUST: one check line; returns 0 when all five conditions hold
  local stage="$1" d="$2" trust="$3" before now name uid start del ready ptrust app
  local new=- nstart=0 nready=False ntrust=- napp=no old=no serving=n/a refresh=- expiry=- unmet=() leaf=no
  before="$(awk -v d="$d" '$1 == "before" && $2 == d { print $4 }' "$(_gate_file "$stage")")"
  now="$(date -u +%s)"
  while read -r name uid start del ready ptrust app; do
    [ -n "$name" ] || continue
    if grep -qx "$uid" <<< "$before"; then old=yes
    elif [ "$del" = no ]; then new="$name"; nstart="$start"; nready="$ready"; ntrust="$ptrust"; napp="$app"; fi
  done < <(_deploy_pods "$d")
  if [ "$new" = - ] || [ "$nready" != True ] || [ "$old" = yes ]; then unmet+=(ready); fi
  if [ "$new" != - ]; then
    serving="$(_serving "$d" "$new")"
    read -r refresh expiry _ _ < <(_leaf_state "$new")
    if awk -v r="$refresh" -v e="$expiry" -v s="$nstart" -v n="$now" \
        'BEGIN { exit !(r != "-" && e != "-" && r + 0 > s + 0 && e + 0 > n + 0) }'; then leaf=yes; fi
  fi
  [ "$serving" != no ] || unmet+=(serving)
  [ "$ntrust" = "$trust" ] || unmet+=(trust)
  [ "$leaf" = yes ] || unmet+=(leaf)
  [ "$napp" = yes ] || unmet+=(app-ready)
  printf 'check %s %s pod=%s ready=%s old_gone=%s serving=%s trust=%s leaf=%s app_ready=%s refresh=%s expiry=%s unmet=%s\n' \
    "$(_utc)" "$d" "$new" "$(_yn "$nready" True)" "$(_yn "$old" no)" \
    "$serving" "$(_yn "$ntrust" "$trust")" "$leaf" "$napp" "$refresh" "$expiry" "$(_csv_or_dash "${unmet[@]}")"
  [ ${#unmet[@]} -eq 0 ]
}

# restart_and_gate STAGE DEPLOY...: restart DEPLOYs, gate them, then sample every pair.
restart_and_gate() {
  local stage="$1" f d line trust pass deadline args=() unmet=()
  shift
  [ $# -ge 1 ] || die "restart_and_gate: at least one DEPLOY required"
  f="$(_gate_file "$stage")"
  [ ! -e "$f" ] || die "restart_and_gate: $f exists; evidence is written once"
  mkdir -p "$RUN_DIR/gates"
  {
    printf 'stage=%s\nrestarted=%s\nstarted_at=%s\nstarted_epoch=%s\n' "$stage" "$(IFS=,; echo "$*")" "$(_utc)" "$(date -u +%s)"
    for d in "$@"; do _deploy_pods "$d" | awk -v d="$d" '{ print "before", d, $1, $2 }'; done
  } > "$f"
  for d in "$@"; do args+=("deploy/$d"); done
  mark restart "$stage: $*"
  capture "restarts/$stage.txt" kubectl -n "$LAB_NS" rollout restart "${args[@]}"
  deadline=$(( $(date -u +%s) + GATE_TIMEOUT_S ))
  while :; do
    trust="$(_trust_now)"
    pass=yes; unmet=()
    for d in "$@"; do
      if line="$(_gate_check "$stage" "$d" "$trust")"; then :; else pass=no; unmet+=("$d:${line##* unmet=}"); fi
      echo "$line" >> "$f"
    done
    [ "$pass" = no ] || break
    [ "$(date -u +%s)" -lt "$deadline" ] || break
    sleep "$GATE_POLL_S"
  done
  printf 'expected_trust_sha256=%s\n' "$trust" >> "$f"
  if [ "$pass" = yes ]; then
    printf 'gate=pass\ngate_at=%s\ngate_epoch=%s\n' "$(_utc)" "$(date -u +%s)" >> "$f"
    mark gate "$stage pass"
  else
    printf 'gate=timeout\nunmet=%s\ngate_at=%s\ngate_epoch=%s\n' "$(IFS=' '; echo "${unmet[*]}")" "$(_utc)" "$(date -u +%s)" >> "$f"
    mark gate "$stage timeout after ${GATE_TIMEOUT_S}s: ${unmet[*]}"
  fi
  stage_samples "$stage"
}

# stage_samples STAGE: GATE_SAMPLES fresh-connection samples per pair, the pairs'
# endpoint certificate state, and one cell line per pair.
stage_samples() {
  local stage="$1" f gate status pair name client server cpod spod n out ok fail role d state
  f="$(_gate_file "$stage")"
  if [ ! -e "$f" ]; then
    mkdir -p "$RUN_DIR/gates"
    printf 'stage=%s\nrestarted=-\nstarted_at=%s\nstarted_epoch=%s\ngate=none\n' "$stage" "$(_utc)" "$(date -u +%s)" > "$f"
    mark stage "$stage: samples, no restarts"
  fi
  gate="$(awk -F= '$1 == "gate" { v = $2 } END { print v }' "$f")"
  status=classified
  [ "$gate" != timeout ] || status=unclassified
  for pair in "${GATE_PAIRS[@]}"; do
    read -r name client server <<< "$pair"
    cpod="$(_current_pod "$client")"; spod="$(_current_pod "$server")"
    ok=0; fail=0
    for ((n = 1; n <= GATE_SAMPLES; n++)); do
      out="$(timeout 20 kubectl -n "$LAB_NS" exec "$cpod" -c probe -- sh /probes/sample-once.sh "$n" 2>&1)" \
        || out="fail exec_rc=$? $(tr '\n' ' ' <<< "$out")"
      if [ "$out" = ok ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
      printf 'sample %s pair=%s client=%s server=%s n=%s %s\n' "$(_utc)" "$name" "$cpod" "$spod" "$n" "$(tr '\n' ' ' <<< "$out")" >> "$f"
      sleep "$GATE_SAMPLE_INTERVAL_S"
    done
    printf 'cell pair=%s ok=%s fail=%s status=%s\n' "$name" "$ok" "$fail" "$status" >> "$f"
  done
  for role in clientA:probe-tcp-new clientB:probe-tcp-new-b server:server; do
    d="${role#*:}"; cpod="$(_current_pod "$d")"
    read -r -a state < <(_leaf_state "$cpod")
    printf 'leaf %s role=%s pod=%s refresh=%s expiry=%s ok=%s err=%s\n' \
      "$(_utc)" "${role%%:*}" "$cpod" "${state[0]}" "${state[1]}" "${state[2]}" "${state[3]}" >> "$f"
  done
}
```

- [ ] **Step 5: Gate settings in `demos/cert-hygiene/config.example.env`**

Append to the `# ---- Timing (seconds) ----` section:

```bash
# Restart-stage gates (design 1.6). GATE_TIMEOUT_S is set from measured healthy
# restarts (Task 7 discovery, runs/_discovery/<stamp>-gates/FINDINGS.md).
GATE_TIMEOUT_S=600
GATE_POLL_S=5
GATE_SAMPLES=10
GATE_SAMPLE_INTERVAL_S=2
```

`600` is the ceiling the discovery run uses; Step 9 replaces it.

- [ ] **Step 6: Write `demos/cert-hygiene/lab/discover-gates.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a long-profile lab with baseline workloads deployed.
# Exercises the restart-stage gates on healthy restarts (design section 10): client A,
# then server, then every other lab Deployment, recording how long each gate took.
# Usage: discover-gates.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/gates.sh"
RUN_DIR="${1:?usage: discover-gates.sh <out-dir>}"
[ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists; refusing to overwrite"
mkdir -p "$RUN_DIR"

mark discover-gates start
stage_samples g0-no-restart
restart_and_gate g1-client-a probe-tcp-new
restart_and_gate g2-server server
mapfile -t rest < <(lab_deployments | grep -vx -e probe-tcp-new -e server)
restart_and_gate g3-all "${rest[@]}"
for s in g1-client-a g2-server g3-all; do
  f="$RUN_DIR/gates/$s.txt"
  printf 'stage=%s gate=%s seconds_to_gate=%s summary=%s\n' "$s" "$(_kv gate "$f")" \
    "$(( $(_kv gate_epoch "$f") - $(_kv started_epoch "$f") ))" "$(gate_summary "$f")"
done > "$RUN_DIR/durations.txt"
# shellcheck disable=SC1010
mark discover-gates done
cat "$RUN_DIR/durations.txt"
```

Append to `demos/cert-hygiene/Justfile`:

```just

# Discovery: how long healthy restarts take to pass the restart-stage gates
discover-gates:
    bash scripts/in-lab.sh lab/discover-gates.sh runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)-gates
```

- [ ] **Step 7: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && for f in lab/*.sh lab/probes/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/gates.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh && shellcheck -s sh lab/probes/*.sh'`
Expected: no errors; `gates.sh` under 300 lines; no findings.

- [ ] **Step 8: Discovery — healthy restart gates**

Run: `just demo cert-hygiene reset long` (repeat the wait if it times out), then `just demo cert-hygiene deploy baseline`. Discovery takes several minutes, longer than one Bash call may last, so launch it detached from `demos/cert-hygiene` rather than through the `discover-gates` verb: `bash scripts/in-lab.sh --detach .lab-logs/discover-gates.log lab/discover-gates.sh runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)-gates`, then `bash scripts/wait-log.sh .lab-logs/discover-gates.log 540`, repeated until it prints the tail.
Expected: three `durations.txt` lines, each `gate=pass` with a summary `gate=pass A=10/0/classified B=10/0/classified`; `gates/g0-no-restart.txt` has two `cell … ok=10 fail=0` lines.

If any gate timed out or any sample failed on these healthy restarts, read its `check` lines: the `unmet=` field names the condition. Fix `gates.sh` and repeat this step with a fresh `<stamp>`. Keep every discovery directory.

- [ ] **Step 9: Set `GATE_TIMEOUT_S` and record the finding**

Let `L` be the largest `seconds_to_gate` in `durations.txt`. Set `GATE_TIMEOUT_S` in `config.example.env` to `max(120, 30 × ceil(3 × L / 30))`: three times the slowest healthy restart, rounded up to 30 s, never under 2 minutes. Replace the `GATE_TIMEOUT_S=600` line with that value, keeping the comment.

Write `runs/_discovery/<stamp>-gates/FINDINGS.md` with the Write tool: the three `durations.txt` lines quoted, `L`, the computed `GATE_TIMEOUT_S`, and "recorded in `config.example.env`".

- [ ] **Step 10: Commit**

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/config.example.env demos/cert-hygiene/Justfile demos/cert-hygiene/runs/_discovery
git commit -m "cert-hygiene add restart-stage gates; set the gate timeout from healthy restarts"
git push
```
