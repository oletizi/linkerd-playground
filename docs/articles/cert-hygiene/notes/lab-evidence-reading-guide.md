# Reading the lab's raw evidence

How to read a run directory under `demos/cert-hygiene/runs/<scenario>/<UTC>/` when writing an evidence note. It covers runs recorded from the second round of experiments on; the section "Older runs" covers the first issuer run. The helpers named here are in `demos/cert-hygiene/scripts/` and only read files.

## Where the runs live

The recorded runs are not in this repository — they are tens of thousands of files, and this repository is meant to stay small enough to clone and run the demos from. What stays here is one manifest per run (`runs/<scenario>/<UTC>.manifest.txt`), listing every file with its size and SHA-256.

Every path in this guide, and every citation in the evidence notes, is a path *within* a run. Resolve one with:

```
tools/evidence.sh cat   runs/06-anchor-expiry/20260912T125027Z logs/pre-recover/identity.txt
tools/evidence.sh fetch runs/06-anchor-expiry/20260912T125027Z
```

`cat` prints one file and checks it against the manifest. `fetch` downloads the whole run in a single request, verifies every file against the manifest, and puts it where this guide says it lives — after which the `scripts/` helpers work exactly as described below.

Reads go through a CDN, never Backblaze's API, which is rate-limited; see `tools/evidence-cdn/README.md`.

## Before anything else

- Read `validity.txt`. A run that says `evidence_valid=no` is never evidence for a hypothesis. It can be described as a failed attempt, with its reasons. A run holding `discovery.txt` (under `runs/_discovery/`) is a discovery run and never evidence, whatever else it shows.
- For a fault the harness performs, use the recorded action time, not T_mark: the `fault-identity-down` marker in the identity outage, and the `s-hard-swap` marker (and `swap_epoch` in `s-hard/stage1-condition.txt`) in the one-step anchor replacement. `tick fault-minus10` can take more than 10 s, so the action can fire after T_mark.
- Read `git-state.txt` in both the run and its control. The `harness_tree_sha256` values must match.
- Take T_mark from the `t_mark` line of `timeline.log`. Write times as `T+N` seconds. Step-driven runs (the `linkerd check` threshold and staged-rotation scenarios) have no T_mark: use the step markers.
- Container log lines (`--timestamps` in `logs/`): the prefix carries the VM's local offset, not UTC -- for example `-07:00` (recorded in `demos/cert-hygiene/runs/_discovery/20260911T163304Z-timestamps/FINDINGS.md`). The first issuer run's `-07:00` reading still holds: its own `--timestamps` prefixes match the same offset, checked against its `timeline.log`. Either way, check one line against the matching `timeline.log` marker before converting times, since the offset is VM-dependent and not guaranteed stable across VM instances.

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
