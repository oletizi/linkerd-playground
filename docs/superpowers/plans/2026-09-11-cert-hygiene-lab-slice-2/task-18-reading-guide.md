# Task 18: Evidence-reading helpers and write-up instructions

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Close the parked plan-Task-10 item (design § 1.4, "Write-up instructions"). Slice 1's write-up commands read `probes/<probe>.log`, a file per probe written once at the end of the run by `kubectl logs deploy/<probe>`. It held only the pods alive at the end, which is why the first issuer write-up had to reconstruct history from `logs/pre-recover/`. Probe history now lives per pod, in `probes/<label>/<pod>.log` and `<pod>-previous.log`, one label per snapshot. Restart stages replace pods, so a continuous history means merging every snapshot. This task adds three small read-only helpers, tested, and a reading guide that Phase 3 follows. The helpers change the harness tree, so they land in Phase 1.

**Files:**
- Create: `demos/cert-hygiene/scripts/probe-lines.sh`, `demos/cert-hygiene/scripts/pod-series.sh`, `demos/cert-hygiene/scripts/gate-table.sh`
- Create: `demos/cert-hygiene/lab/tests/test-read.sh`
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md`
- Create (discovery, committed): `demos/cert-hygiene/runs/_discovery/<stamp>-timestamps/FINDINGS.md` (the time zone of container log timestamps)
- Modify: `docs/articles/cert-hygiene/README.md` (list the guide)

**Interfaces:**
- Consumes: the evidence layout from Tasks 4–17.
- Produces (read-only, runnable on the host or in the VM; POSIX `awk`, `sort`, `find`):
  - `scripts/probe-lines.sh RUN_DIR PROBE [FROM_UTC] [TO_UTC]` → every line PROBE wrote in any file under `RUN_DIR/probes/`, deduplicated and time-sorted, optionally limited to `[FROM, TO)`. It dies when there are no lines. It also reads slice-1's flat `probes/<probe>.log` files. It is the host-side twin of `_all_probe_lines` (`lab/lib-evidence-control.sh`, Task 8), kept as a separate implementation because this script must run on the host (macOS bash 3.2 / POSIX awk) while the lib runs inside the VM (bash 5); Step 1's test feeds one fixture to both and checks they agree.
  - `scripts/pod-series.sh RUN_DIR POD_PREFIX METRIC` → one line `<tick> <tick-utc> <pod> <series> <value>` per tick (timeline order), per series named exactly METRIC or METRIC with labels, per lab pod that is either every lab pod (POD_PREFIX `''`) or exactly one Deployment's: `POD_PREFIX` followed by exactly two dash-separated segments (`<pod-prefix>-<replicaset-hash>-<pod-suffix>`), so `probe-tcp-new` never also matches `probe-tcp-new-b`'s pods.
  - `scripts/gate-table.sh RUN_DIR` → per `gates/<stage>.txt`: `stage= restarted= gate= unmet=`, its `cell` lines and its `leaf` lines.
  - The reading guide, which every Phase 3 task follows.

- [ ] **Step 1: Failing tests, `demos/cert-hygiene/lab/tests/test-read.sh`**

```bash
#!/usr/bin/env bash
# Unit tests for the read-only evidence helpers in scripts/.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/lib-evidence.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
R="$T/run"
mkdir -p "$R/probes/pre-stage2" "$R/probes/final" "$R/metrics" "$R/gates"
printf '$ kubectl logs\n2026-09-11T10:00:02Z probe-tcp-new seq=2 ok\n2026-09-11T10:00:00Z probe-tcp-new seq=1 ok\n[exit 0]\n' > "$R/probes/pre-stage2/probe-tcp-new-a.log"
printf '2026-09-11T10:00:02Z probe-tcp-new seq=2 ok\n2026-09-11T10:05:00Z probe-tcp-new seq=1 fail socat_rc=1\n2026-09-11T10:00:01Z probe-http seq=1 ok http=200\n' > "$R/probes/final/probe-tcp-new-b.log"
out="$(bash "$DEMO/scripts/probe-lines.sh" "$R" probe-tcp-new)"
assert_eq "$(wc -l <<< "$out" | tr -d ' ')" 3 "merged across snapshots, duplicates removed, other probes excluded"
assert_eq "$(head -n 1 <<< "$out")" "2026-09-11T10:00:00Z probe-tcp-new seq=1 ok" "time order"
assert_eq "$(bash "$DEMO/scripts/probe-lines.sh" "$R" probe-tcp-new 2026-09-11T10:00:01Z 2026-09-11T10:05:00Z)" \
  "2026-09-11T10:00:02Z probe-tcp-new seq=2 ok" "window [from, to)"
assert_fails "no lines for a probe dies" bash "$DEMO/scripts/probe-lines.sh" "$R" probe-nope

# ---- probe-lines.sh and _all_probe_lines (lab/lib-evidence-control.sh, Task 8) agree ----
# Twins that must not drift: probe-lines.sh runs on the host (macOS bash 3.2 / POSIX
# awk); _all_probe_lines runs inside the lab VM (bash 5). Same fixture as above, same
# merge (find every probes/*/*.log, keep field 2 == probe, dedup and sort).
assert_eq "$(bash "$DEMO/scripts/probe-lines.sh" "$R" probe-tcp-new)" "$(_all_probe_lines "$R" probe-tcp-new)" \
  "probe-lines.sh and _all_probe_lines merge the same fixture identically"

printf '2026-09-11T10:00:00Z tick baseline\n2026-09-11T10:00:30Z tick pre-1\n' > "$R/timeline.log"
printf 'sampled_at_epoch=1\n== lab/probe-http-abc12-x1y2 :4191\ntcp_open_total{direction="outbound",peer="dst"} 1\nother 2\n== lab/probe-http-b-abc12-x1y2 :4191\ntcp_open_total{direction="outbound",peer="dst"} 9\n== lab/server-abc12-y3z4 :4191\ntcp_open_total{direction="inbound"} 5\n' > "$R/metrics/baseline.txt"
printf 'sampled_at_epoch=2\n== lab/probe-http-abc12-x1y2 :4191\ntcp_open_total{direction="outbound",peer="dst"} 1\n' > "$R/metrics/pre-1.txt"
out="$(bash "$DEMO/scripts/pod-series.sh" "$R" probe-http tcp_open_total)"
assert_eq "$(wc -l <<< "$out" | tr -d ' ')" 2 "one line per tick for the matching pod only; probe-http-b-... (a different Deployment) is excluded"
assert_contains "$out" 'pre-1 2026-09-11T10:00:30Z probe-http-abc12-x1y2 tcp_open_total{direction="outbound",peer="dst"} 1' "tick, time, pod, series, value"
out_b="$(bash "$DEMO/scripts/pod-series.sh" "$R" probe-http-b tcp_open_total)"
assert_eq "$(wc -l <<< "$out_b" | tr -d ' ')" 1 "the -b Deployment's own prefix matches only its own pod"
assert_contains "$out_b" 'probe-http-b-abc12-x1y2 tcp_open_total{direction="outbound",peer="dst"} 9' "prefix matching is exact, not a bare substring"

printf 'stage=stage2-client-a\nrestarted=probe-tcp-new\ngate=pass\ncell pair=A ok=10 fail=0 status=classified\nleaf t role=clientA pod=p refresh=1 expiry=2 ok=1 err=0\n' > "$R/gates/stage2-client-a.txt"
printf 'stage=s04-restart\nrestarted=server\ngate=pass\ncell pair=A ok=10 fail=0 status=classified\n' > "$R/gates/s04-restart.txt"
out="$(bash "$DEMO/scripts/gate-table.sh" "$R")"
assert_contains "$out" "stage=stage2-client-a restarted=probe-tcp-new gate=pass unmet=-" "gate header"
assert_contains "$out" "cell pair=A ok=10 fail=0 status=classified" "cells"
assert_contains "$out" "leaf t role=clientA" "leaf lines"
assert_contains "$out" "stage=s04-restart restarted=server gate=pass unmet=-" "a stage named -restart is listed too"

finish test-read
```

Run: `just demo cert-hygiene test`
Expected: `test-read` fails (the scripts don't exist).

- [ ] **Step 2: Write `demos/cert-hygiene/scripts/probe-lines.sh`**

```bash
#!/usr/bin/env bash
# Evidence reading; runs on the host or in the VM, and only reads. Prints every line a
# probe wrote, from every file under RUN_DIR/probes/ (per-pod snapshots, current and
# previous containers; slice-1 runs' flat probes/<probe>.log files too), deduplicated
# and in time order: the probe's continuous history across restarts. With FROM and TO
# (UTC ISO-8601), only lines in [FROM, TO).
# Twin: lab/lib-evidence-control.sh's _all_probe_lines (Task 8) does the same merge
# inside the VM (bash 5); kept separate because this script must also run on the host
# (macOS bash 3.2 / POSIX awk). lab/tests/test-read.sh checks the two agree.
# Usage: probe-lines.sh <run-dir> <probe> [from-utc] [to-utc]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
run="${1:?usage: probe-lines.sh <run-dir> <probe> [from-utc] [to-utc]}"
probe="${2:?usage: probe-lines.sh <run-dir> <probe> [from-utc] [to-utc]}"
from="${3:-}"; to="${4:-}"
[ -d "$run/probes" ] || die "$run has no probes/ directory"
lines="$(find "$run/probes" -type f -name '*.log' -exec awk -v p="$probe" '$2 == p' {} + | sort -u \
  | awk -v f="$from" -v t="$to" '(f == "" || $1 >= f) && (t == "" || $1 < t)')"
[ -n "$lines" ] || die "no $probe lines under $run/probes${from:+ from $from}${to:+ to $to}"
printf '%s\n' "$lines"
```

- [ ] **Step 3: Write `demos/cert-hygiene/scripts/pod-series.sh`**

```bash
#!/usr/bin/env bash
# Evidence reading; runs on the host or in the VM, and only reads. For every tick, in
# timeline order, prints "<tick> <tick-utc> <pod> <series> <value>" for each lab pod that
# is either every lab pod (POD_PREFIX '') or exactly one Deployment's -- POD_PREFIX
# followed by exactly two dash-separated segments (<deploy>-<replicaset-hash>-<pod-
# suffix>), so "probe-tcp-new" never also matches "probe-tcp-new-b"'s pods -- for each
# series named METRIC, with or without labels.
# Example: pod-series.sh RUN probe-http tcp_open_total
# Usage: pod-series.sh <run-dir> <pod-prefix> <metric>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
run="${1:?usage: pod-series.sh <run-dir> <pod-prefix> <metric>}"
[ $# -eq 3 ] || die "usage: pod-series.sh <run-dir> <pod-prefix, '' for every pod> <metric>"
prefix="$2"
metric="${3:?usage: pod-series.sh <run-dir> <pod-prefix> <metric>}"
[ -f "$run/timeline.log" ] || die "$run has no timeline.log"
awk '$2 == "tick" { print $1, $3 }' "$run/timeline.log" | while read -r utc tick; do
  [ -f "$run/metrics/$tick.txt" ] || continue
  awk -v pre="$prefix" -v m="$metric" -v t="$tick" -v u="$utc" '
    function pod_matches(pod,    rest) {
      if (pre == "") return 1
      if (index(pod, pre "-") != 1) return 0
      return split(substr(pod, length(pre) + 2), rest, "-") == 2
    }
    /^== / { split($2, a, "/"); pod = a[2]; on = (a[1] == "lab" && pod_matches(pod)); next }
    on && ($1 == m || index($1, m "{") == 1) { print t, u, pod, $1, $2 }' "$run/metrics/$tick.txt"
done
```

- [ ] **Step 4: Write `demos/cert-hygiene/scripts/gate-table.sh`**

```bash
#!/usr/bin/env bash
# Evidence reading; runs on the host or in the VM, and only reads. Summarises every
# restart-stage gate record (gates/<stage>.txt): its header, cells and leaf lines.
# Usage: gate-table.sh <run-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
run="${1:?usage: gate-table.sh <run-dir>}"
[ -d "$run/gates" ] || die "$run has no gates/ directory"
for f in "$run"/gates/*.txt; do
  awk -F= '
    $1 == "stage" { s = $2 } $1 == "restarted" { r = $2 } $1 == "gate" { g = $2 } $1 == "unmet" { u = $2 }
    END { printf "stage=%s restarted=%s gate=%s unmet=%s\n", s, r, g, (u == "" ? "-" : u) }' "$f"
  awk '/^(cell|leaf) / { print "  " $0 }' "$f"
done
```

Run: `just demo cert-hygiene test`
Expected: six `PASS:` lines, including `PASS: test-read`.

- [ ] **Step 4b: Discovery — which time zone do container log timestamps carry?**

The first issuer write-up read the `--timestamps` prefixes as the VM's local time (−07:00). Kubernetes documents `kubectl logs --timestamps` as RFC3339, which the kubelet usually writes in UTC. The guide states neither reading until it is recorded.

With a lab up (if none is, `just demo cert-hygiene reset long`, then `just demo cert-hygiene deploy baseline`), run:
`bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c 'date -u +%Y-%m-%dT%H:%M:%SZ; date +%z; kubectl -n lab logs deploy/probe-http -c probe --timestamps --tail=1; kubectl -n lab logs deploy/probe-http -c linkerd-proxy --timestamps --tail=1'`
Expected: four lines: the UTC time, the VM's offset, and two log lines, each starting with a timestamp prefix, then the container's own text. The probe's own text starts with its UTC time, so the prefix's zone is visible by comparison.

Write `demos/cert-hygiene/runs/_discovery/<stamp>-timestamps/FINDINGS.md` with the Write tool: the four lines quoted, and one sentence saying which zone the prefix carries (UTC with a `Z` suffix, or a stated offset). Also say whether the first issuer run's −07:00 reading still holds for that run. Check it against one `logs/pre-recover/` line in `runs/05-issuer-expiry/20260911T021157Z` and that run's `timeline.log`.

In the guide (Step 5), replace `<ZONE SENTENCE FROM STEP 4b>` with that finding in plain words. For example, "the prefix is UTC, with a `Z` suffix (recorded in `demos/cert-hygiene/runs/_discovery/<stamp>-timestamps/FINDINGS.md`)", or the recorded offset. Add the note about the first issuer run if it differs.

- [ ] **Step 5: Write `docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md`**

````markdown
# Reading the lab's raw evidence

How to read a run directory under `demos/cert-hygiene/runs/<scenario>/<UTC>/` when writing an evidence note. It covers runs recorded from the second round of experiments on; the section "Older runs" covers the first issuer run. The helpers named here are in `demos/cert-hygiene/scripts/` and only read files.

## Before anything else

- Read `validity.txt`. A run that says `evidence_valid=no` is never evidence for a hypothesis. It can be described as a failed attempt, with its reasons. A run holding `discovery.txt` (under `runs/_discovery/`) is a discovery run and never evidence, whatever else it shows.
- For a fault the harness performs, use the recorded action time, not T_mark: the `fault-identity-down` marker in the identity outage, and the `s-hard-swap` marker (and `swap_epoch` in `s-hard/stage1-condition.txt`) in the one-step anchor replacement. `tick fault-minus10` can take more than 10 s, so the action can fire after T_mark.
- Read `git-state.txt` in both the run and its control. The `harness_tree_sha256` values must match.
- Take T_mark from the `t_mark` line of `timeline.log`. Write times as `T+N` seconds. Step-driven runs (the `linkerd check` threshold and staged-rotation scenarios) have no T_mark: use the step markers.
- Container log lines (`--timestamps` in `logs/`): <ZONE SENTENCE FROM STEP 4b>. Either way, check one line against the matching `timeline.log` marker before converting times.

## What a run directory holds

| Path | What it is |
| --- | --- |
| `timeline.log` | Every marker and tick, in order, with UTC times |
| `validity.txt`, `credential-plan.txt`, `leaf-lifetime.txt`, `control-criteria.txt` | The harness's mechanical verdicts (never hypothesis verdicts) |
| `checks/<tick>-check.txt`, `checks/<tick>-check-proxy.txt` | `linkerd check` and `linkerd check --proxy` at each tick |
| `metrics/<tick>.txt` | Per lab proxy (`== lab/<pod> :4191` sections): identity series and connection series (`tcp_open_total`, `tcp_close_total`, `tcp_open_connections`, `outbound_tcp_route_open_total`, `outbound_tcp_route_close_total`); the identity controller's `issuer_cert_ttl_seconds` |
| `credentials/<tick>.txt` | Trust-roots hash, issuer and webhook certificate fingerprints, serials, `notAfter`s, SANs |
| `trust/<tick>.txt` | The trust-roots hash and each pod's `linkerd.io/trust-root-sha256` annotation |
| `webhooks/<tick>.txt` | Each webhook's `failurePolicy` and caBundle hash; each serving certificate's identity |
| `controlplane/<tick>.txt` | Control-plane pods (UID, start time, readiness) and Deployments (generation, template hash) |
| `pods/<tick>.txt`, `pods/<tick>-<pod>.yaml`, `-describe.txt` | Pod listings and details |
| `probes/<label>/<pod>.log`, `<pod>-previous.log`, `pods.txt` | Probe history per pod, captured at each snapshot label |
| `logs/<label>/<pod>-<container>.txt`, `pods.txt` | Container logs, including every `linkerd-proxy`, at each snapshot label; `identity.txt`, `identity-proxy.txt`; `logs/final/k3s-journal.txt` (supplementary only) |
| `gates/<stage>.txt` | A restart stage: the five gate conditions per poll, then fresh-connection samples per pair and the pairs' leaf state |
| `restarts/<stage>.txt` | The `kubectl rollout restart` command a stage ran, and its output |
| `discovery.txt`, `discovery-windows.txt` | Present only in discovery runs (never evidence): the discovery marker, and any shortened windows applied |
| `events/<label>.txt` | Kubernetes events |
| `recover/`, `fault/`, `swap/`, `steps/`, `k/`, `s-hard/`, `admission/` | Scenario-specific records, named in each scenario's plan task |

## Probe history

Restart stages replace probe pods, so no single snapshot holds a probe's history. Use:

```
bash demos/cert-hygiene/scripts/probe-lines.sh <run> probe-tcp-new [from-utc] [to-utc]
```

It merges every `probes/<label>/` snapshot, current and previous containers, deduplicated and time-sorted. The four probes are `probe-http` (a fresh `curl` per attempt; the proxies may reuse a connection), `probe-tcp-new` and `probe-tcp-new-b` (a new opaque-TCP connection per attempt, to `server`), and `probe-tcp-stream` (one opaque-TCP connection held open; `connect` and `closed` lines bound it). The first `fail` after a moment and the last `ok` before it are the boundary to quote.

## Per-proxy series across ticks

```
bash demos/cert-hygiene/scripts/pod-series.sh <run> probe-tcp-new control_identity_cert_expiration_timestamp_seconds
bash demos/cert-hygiene/scripts/pod-series.sh <run> probe-http tcp_open_total
```

Pod names change at restarts; `pod-series.sh` selects a Deployment's pods exactly, not by a bare prefix match: a pod name is the Deployment's name followed by exactly two dash-separated segments (`<deploy>-<replicaset-hash>-<pod-suffix>`), so `probe-tcp-new` never also pulls in `probe-tcp-new-b`'s pods. For connection reuse, read the outbound series whose labels name `server` (`peer="dst"`, `authority="server.lab.svc.cluster.local:8080"` for HTTP, `:9000` for opaque TCP) and compare values across ticks.

## Restart stages

```
bash demos/cert-hygiene/scripts/gate-table.sh <run>
```

A stage's cell is classified by its samples only when its gate is `pass` (or `none`, for a stage with no restarts). `timeout` means unclassified: quote the `unmet=` conditions and the `check` lines instead of a cell result. Compare every stage's samples with the same stage in the control: the control's failures during restarts are the disruption rollouts cause on their own.

## Judging a hypothesis

- **Confirmed:** quoted evidence shows the predicted behaviour directly.
- **Falsified:** quoted evidence shows different behaviour.
- **Inconclusive:** the evidence can't decide it. Say which observation would.
- Quote the exact lines, with paths relative to the run directory, and times relative to T_mark.
- Label anything from the source notes as source-derived; don't present it as observed.
- A scenario is written up as reproduced only when every acceptance condition in design § 13 holds; check them first and say which do.
- Never edit a run. If the evidence cannot answer something, say so.

## Older runs

The first issuer run (`runs/05-issuer-expiry/20260911T021157Z`) predates this layout. Its `probes/<probe>.log` files hold only the pods alive at the end of the run; the earlier pods' probe history is in `logs/pre-recover/<pod>-probe.txt`, and it has no workload `linkerd-proxy` logs. `probe-lines.sh` still reads its flat files, but for the earlier pods, read `logs/pre-recover/` directly.
````

- [ ] **Step 6: List the guide in `docs/articles/cert-hygiene/README.md`**

Under "Start here", item 3, add after the `lab-evidence-review-2026-09-11.md` line:

```markdown
   - [notes/lab-evidence-reading-guide.md](notes/lab-evidence-reading-guide.md) — how to read the lab's raw recordings when checking a claim.
```

- [ ] **Step 7: Shellcheck and commit**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scripts/*.sh lab/tests/*.sh'`
Expected: no findings.

```bash
git add demos/cert-hygiene/scripts demos/cert-hygiene/lab/tests/test-read.sh demos/cert-hygiene/runs/_discovery docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene add evidence-reading helpers and a reading guide for the per-pod layout"
git push
```
