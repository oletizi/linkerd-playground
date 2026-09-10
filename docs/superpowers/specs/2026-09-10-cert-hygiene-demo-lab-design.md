# Cert-Hygiene Demo Lab — Design

**Status:** Draft for review. Section 1 was presented in chat and still needs approval. Sections 2–6 appear here for the first time. Linkerd-specific facts marked **Unverified** will be settled in two ways: research against Linkerd source and docs, which is in progress, and the lab's first feasibility run (§ 4.1). Each open item names the design choice that depends on it.

**Inputs:** [article README](../../articles/cert-hygiene/README.md), [demo-feasibility.md](../../articles/cert-hygiene/demo-feasibility.md) (scenario numbering and the article validation contract), and [bibliography.md](../../articles/cert-hygiene/bibliography.md).

## Decisions made

| Question | Decision | Consequence |
| --- | --- | --- |
| Substrate | Reuse the repo's existing VM + k3s + Linkerd install path; lift its generic pieces into shared `lib/` | One cluster story in the repo. No kind. |
| Audience | Evidence first | The first deliverable is timestamped raw transcripts for the article. Scripts should be clean enough to publish; reader-facing walkthroughs come later. |
| First slice | Baseline + scenario #5 (issuer expiry) | Deviates from the order in `demo-feasibility.md`. #5 is the article's central evidence and its riskiest unknown (do minutes-long credentials work?), and it forces the full probe harness that later scenarios reuse. |
| Linkerd version | Latest edge release, pinned to an exact `edge-YY.M.N` | The version is recorded in every evidence run. |
| Harness | Bash scripts plus in-cluster probe pods | Matches the repo's script conventions. |
| Clock | Never altered | All expiry is driven by short-lived certificates, per the feasibility doc's timing rule. |

## 1. Layout, shared library, substrate

### 1.1 Shared pieces lifted into `lib/`

These run inside the lab VM.

| New file | Contents | Lifted from |
| --- | --- | --- |
| `lib/certs.sh` | `ensure_step`; `make_trust_anchor DIR LIFETIME`; `make_issuer DIR LIFETIME ANCHOR_DIR` | `demos/spiffe-cross-boundary/cluster/gen-certs.sh` |
| `lib/k3s.sh` | `install_k3s`; `reset_k3s` (uninstall, then reinstall) | `demos/spiffe-cross-boundary/cluster/install-k3s.sh` |
| `lib/linkerd.sh` | `ensure_linkerd_cli VERSION`; `install_gateway_crds`; `wait_rollouts NS`; `linkerd_install ANCHOR ISSUER_CRT ISSUER_KEY [--set k=v ...]` | `demos/spiffe-cross-boundary/cluster/install-linkerd.sh` |

The three SPIFFE scripts keep their paths and become thin callers of `lib/`, with no change in behavior or output. The SPIFFE README and MANUAL were validated by hand on three substrates, so none of their documented paths move.

### 1.2 New demo: `demos/cert-hygiene/`

```
demos/cert-hygiene/
  Justfile                      lab-up, lab-down, reset, run <scenario>, status
  config.example.env            LINKERD_EDGE_VERSION, LAB_VM, lifetimes, probe intervals
  scripts/                      host side (macOS)
    lab-up.sh                   orb create + package install + k3s install
    lab-down.sh                 orb delete
  lab/                          in-VM
    reset.sh                    reset_k3s, generate certs, install Linkerd
    baseline.yaml               server + probe workloads (§ 2)
    collect.sh                  evidence snapshot functions (§ 3)
  scenarios/
    05-issuer-expiry.sh         phases: baseline, fault, observe, recover, verify
  runs/<scenario>/<UTC>/        raw evidence; committed
```

### 1.3 Substrate for this slice

- **One OrbStack machine**, `cert-hygiene-lab`. The name is chosen so it can't collide with the SPIFFE demo's `linkerd-cluster`. `lab-up` creates it with `orb create` at the host's native architecture (no `-a amd64`; see `README-ORBSTACK.md`).
- **Per-scenario reset** runs `reset_k3s` inside the same machine: a fresh cluster without rebuilding the VM.
- **Deferred:** the libvirt (Linux) and Lima backends. They live in `demos/spiffe-cross-boundary/scripts/`, tied to that demo's config, and lifting them is its own refactor.
- **Unverified:** OrbStack mounts the macOS home directory at the same path inside the machine. If it does, in-VM scripts run straight from the working tree and `runs/` writes land in the repo with no copying. If it doesn't, `lab-up` copies the repo in (as in `README-ORBSTACK.md`) and a `pull-runs` verb copies evidence back.

### 1.4 Refactor safety

The refactor touches scripts whose documented output has been validated. Checks:

1. `bash -n` and `shellcheck` on every touched script.
2. Before the refactor, run the SPIFFE cluster-side steps (`gen-certs.sh`, `install-k3s.sh`, `install-linkerd.sh`) on the lab VM and save their output and `linkerd check`. Repeat after the refactor and diff the two.

## 2. Baseline workloads and probes

All workloads run in a meshed namespace, `lab`. Images are multi-arch, pinned by digest, and the digests are recorded in every run.

| Workload | Role |
| --- | --- |
| `server` | Serves HTTP on one port and a TCP line-echo on a second port, annotated opaque (`config.linkerd.io/opaque-ports`). |
| `probe-http` | Makes an HTTP request to `server` every `PROBE_INTERVAL`. This is what an application sees. |
| `probe-tcp-new` | Opens a **new** TCP connection to the opaque port on every attempt, sends one line, expects the echo, then closes. |
| `probe-tcp-stream` | Opens **one** TCP connection to the opaque port and holds it, sending a line every `PROBE_INTERVAL`. It logs the connection's start, every exchange, and the close or error. |

**Why three probes.** The validation contract requires established-session and newly negotiated connections to be reported separately. The proxy pools outbound HTTP connections, so one HTTP request doesn't imply a new proxy-to-proxy mTLS handshake. The HTTP probe can't separate the two cases on its own.

**Unverified:** on an opaque port, each application TCP connection gets its own proxy-to-proxy TLS connection. If that holds, `probe-tcp-new` forces a handshake per attempt and `probe-tcp-stream` holds one session. The first baseline run tests it: the proxy's TCP/TLS connection metrics for `probe-tcp-new` should rise by one per attempt. If they don't, the probe design is revised before any fault run.

**Probe output format.** Each line is `<UTC ISO-8601> <probe> <ok|fail> <detail>` on stdout. The collector reads it back with `kubectl logs`, so probe state survives until the run is collected.

**Leaf certificate observation.** Each probe pod's proxy exposes identity metrics on its admin port. **Unverified names:** `identity_cert_expiration_timestamp_seconds` and `identity_cert_refresh_count`. The collector samples them for every pod on each observation tick. That yields each workload leaf's `notAfter`, and whether it refreshed, over time.

## 3. Evidence capture

Every scenario run writes `demos/cert-hygiene/runs/<scenario>/<UTC-start>/`:

| Path | Contents |
| --- | --- |
| `versions.txt` | Linkerd CLI, control plane, and proxy versions; k3s/Kubernetes version; OrbStack version; image digests; every config value used |
| `certs/` | Trust anchor and issuer PEMs (certificates only, never keys), plus `step certificate inspect` output: serial, issuer, SANs, `notBefore`, `notAfter` |
| `timeline.log` | Harness phase markers with UTC timestamps: `reset`, `baseline`, `fault`, `observe-N`, `recover`, `verify` |
| `checks/<tick>-check.txt`, `checks/<tick>-check-proxy.txt` | Raw `linkerd check` and `linkerd check --proxy` output, each with its exit code |
| `probes/<probe>.log` | Probe output (§ 2) |
| `metrics/<tick>.txt` | Proxy identity metrics for every meshed pod |
| `logs/` | `linkerd-identity` logs; proxy logs of each lab pod; the k3s server journal slice for the run window (API-server side) |
| `events.txt` | `kubectl get events -A`, sorted by time |

Rules:

- Evidence is written once and never edited. When the article quotes a transcript, it cites the run directory.
- Each run is committed and pushed as soon as it is collected, so no evidence exists only in one working tree.
- Private keys stay inside the VM and under `.gitignore`d paths. They are never copied into `runs/`.

## 4. Scenario #5: issuer expiry, with the trust anchor and its key intact

### 4.1 Feasibility gate (first lab run)

Before the full scenario, a short run answers four questions:

1. Does `linkerd install` accept an issuer whose `notAfter` is `ISSUER_LIFETIME` (default 15m) away?
2. Does the leaf-lifetime knob accept `LEAF_LIFETIME` (default 5m)? **Unverified key:** `identity.issuer.issuanceLifetime`.
3. Are issued leaves clamped to the issuer's `notAfter`? Read their `notAfter` from the identity metrics.
4. Does the opaque-port assumption in § 2 hold?

If the answers force hour-scale lifetimes, the scenario still runs as designed, just slower. Per the repo's long-run rule it is then launched detached with `nohup` inside the VM, with a separate watcher for completion.

### 4.2 Timeline

Config values: `ANCHOR_LIFETIME` is long enough that it can't expire during a run (default 720h), and `ISSUER_LIFETIME` and `LEAF_LIFETIME` are as in § 4.1. `T_iss` is the issuer's `notAfter`.

| Phase | Action | Captured |
| --- | --- | --- |
| reset | `reset_k3s`; generate the anchor and short-lived issuer; `linkerd_install` with the leaf-lifetime setting; deploy the § 2 workloads | `versions.txt`, `certs/` |
| baseline | Wait until all probes report `ok`; snapshot | checks, metrics, probe logs |
| observe (pre-expiry) | Snapshot every `OBSERVE_INTERVAL` (default 30s) until `T_iss` | checks, metrics |
| fault | None applied. The fault is the issuer reaching `T_iss`. Snapshots at `T_iss − 1m` and `T_iss + 1m` | checks, identity logs |
| observe (post-expiry) | At `T_iss + 1m`, start a **new** meshed pod (`probe-new`) and **restart** a copy of an existing workload (`server-restarted`). Leave `server` and the three probes untouched. Keep snapshotting until every pre-expiry leaf is past its `notAfter`, plus `LEAF_LIFETIME` | checks, metrics, identity and proxy logs, pod readiness, probe logs |
| recover | Sign a replacement issuer from the **same** anchor, then apply it by the procedure in [Replacing expired certificates](https://linkerd.io/docs/tasks/replacing_expired_certificates/). Record whether proxies recover without restarts. Restart only what stays broken, and record each restart | checks, identity logs, probe logs |
| verify | All probes `ok`; `linkerd check` and `linkerd check --proxy` pass | checks |

### 4.3 What this answers from the validation contract

- **Issuer expiry, immediate effect:** comparing snapshots at `T_iss ± 1m`.
- **Existing leaves approaching expiry:** the metrics time series for untouched pods.
- **New and restarted proxies after issuer expiry:** `probe-new` and `server-restarted`.
- **Exact errors from failed renewal:** raw identity, proxy, and probe logs.
- **Whether established connections survive:** `probe-tcp-stream` against `probe-tcp-new`.
- **Exact `linkerd check` output:** every tick.

Trust-anchor expiry (#6) reuses this harness with a short `ANCHOR_LIFETIME`. It is outside this slice.

### 4.4 Negative control

A `00-baseline-control` run uses the same workloads, duration, and snapshot cadence, with long-lived credentials. Every probe must stay `ok` for the full window. This shows that failures in #5 come from the credential lifecycle, not from the harness, the probes, or k3s.

## 5. Harness verification

- `bash -n` and `shellcheck` on all new and touched scripts.
- The negative control (§ 4.4) passes before any #5 run is treated as evidence.
- A #5 run counts toward the article only if its `versions.txt`, `certs/`, and `timeline.log` are complete and every tick's checks were captured. The collector fails loudly on a missing artifact and never writes a placeholder.

## 6. Out of scope for this slice

- Every scenario other than #5 and the baseline control. The next slice is the webhook triad (#1–#3), which reuses § 1–§ 3 unchanged.
- Linkerd Viz. It adds webhook and APIService certificates that belong to the webhook slice, not here.
- libvirt and Lima backends (§ 1.3).
- Reader-facing walkthroughs.

## 7. Open questions

| Question | Blocks | Resolved by |
| --- | --- | --- |
| Exact current edge release and its Gateway API CRD version | `config.example.env` pin | Research |
| Leaf-lifetime Helm key, its default, and any minimum | § 4.1 item 2 | Research, then lab |
| Identity controller behavior with an issuer that expires while it runs (keeps signing, refuses, reloads?) | § 4.2 expectations only; the harness records whatever happens | Research, then lab |
| Proxy identity metric names | § 2 leaf observation | Research, then lab |
| Opaque-port connection-per-connection behavior | § 2 probe design | Lab (§ 4.1 item 4) |
| OrbStack home mount inside machines | § 1.3 copy/no-copy | First `lab-up` |
