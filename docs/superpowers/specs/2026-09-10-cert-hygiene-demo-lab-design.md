# Cert-Hygiene Demo Lab — Design

**Status:** Draft for review. Section 1 was presented in chat and still needs approval. Sections 2–8 appear here for the first time.

Linkerd behavior described here comes from reading source at tag `edge-26.9.1`; the details and permalinks are in [linkerd-source-notes.md](../../articles/cert-hygiene/linkerd-source-notes.md). Behavior read from source is labelled **Source** and is treated as a *hypothesis the lab run tests*, not as article evidence. Items only the lab can settle are labelled **Unverified**.

**Inputs:** [article README](../../articles/cert-hygiene/README.md), [demo-feasibility.md](../../articles/cert-hygiene/demo-feasibility.md) (scenario numbering and the article validation contract), [bibliography.md](../../articles/cert-hygiene/bibliography.md), [linkerd-source-notes.md](../../articles/cert-hygiene/linkerd-source-notes.md).

## Decisions made

| Question | Decision | Consequence |
| --- | --- | --- |
| Substrate | Reuse the repo's existing VM + k3s + Linkerd install path; lift its generic pieces into shared `lib/` | One cluster story in the repo. No kind. |
| Audience | Evidence first | The first deliverable is timestamped raw transcripts for the article. Scripts should be clean enough to publish; reader-facing walkthroughs come later. |
| First slice | Baseline + scenario #5 (issuer expiry) | Deviates from the order in `demo-feasibility.md`. #5 is the article's central evidence, and it forces the full probe harness that later scenarios reuse. |
| Linkerd version | `edge-26.9.1`, the latest edge (released 2026-09-04) | The version is recorded in every evidence run. |
| Gateway API CRDs | `v1.5.1`, applied with `kubectl apply --server-side` | The CLI's own error text names this version, and it is the upper bound in the docs' supported range. |
| Harness | Bash scripts plus in-cluster probe pods | Matches the repo's script conventions. |
| Clock | Never altered | All expiry is driven by short-lived certificates, per the feasibility doc's timing rule. |

## 1. Layout, shared library, substrate

### 1.1 Shared pieces lifted into `lib/`

These run inside the lab VM.

| New file | Contents | Lifted from |
| --- | --- | --- |
| `lib/certs.sh` | `ensure_step`; `make_trust_anchor DIR LIFETIME`; `make_issuer DIR LIFETIME ANCHOR_DIR` | `demos/spiffe-cross-boundary/cluster/gen-certs.sh` |
| `lib/k3s.sh` | `install_k3s`; `reset_k3s` (uninstall, then reinstall) | `demos/spiffe-cross-boundary/cluster/install-k3s.sh` |
| `lib/linkerd.sh` | `ensure_linkerd_cli VERSION`; `install_gateway_crds VERSION`; `wait_rollouts NS`; `linkerd_install ANCHOR ISSUER_CRT ISSUER_KEY [flag ...]` | `demos/spiffe-cross-boundary/cluster/install-linkerd.sh` |

The three SPIFFE scripts keep their paths and become thin callers of `lib/`, with no change in behavior or output. They keep their own Linkerd pin and Gateway API `v1.2.1`, passed as arguments. The SPIFFE README and MANUAL were validated by hand on three substrates, so none of their documented paths move.

### 1.2 New demo: `demos/cert-hygiene/`

```
demos/cert-hygiene/
  Justfile                      lab-up, lab-down, reset, run <scenario>, status
  config.example.env            LINKERD_EDGE_VERSION, LAB_VM, lifetimes, intervals
  scripts/                      host side (macOS)
    lab-up.sh                   orb create + package install + k3s install
    lab-down.sh                 orb delete
  lab/                          in-VM
    reset.sh                    reset_k3s, generate certs, install Linkerd
    baseline.yaml               server + probe workloads (§ 2)
    collect.sh                  evidence snapshot functions (§ 3)
  scenarios/
    00-baseline-control.sh      negative control (§ 4.4)
    05-issuer-expiry.sh         phases: baseline, fault, observe, recover, verify
  runs/<scenario>/<UTC>/        raw evidence; committed
```

### 1.3 Substrate for this slice

- **One OrbStack machine**, `cert-hygiene-lab`. The name is chosen so it can't collide with the SPIFFE demo's `linkerd-cluster`. `lab-up` creates it with `orb create` at the host's native architecture (no `-a amd64`; see `README-ORBSTACK.md`).
- **No `linkerd-cni`.** The default proxy-init is used. Linkerd #13631 reports network-validator crashloops on OrbStack's k3s, and the CNI plugin is what brings in the network validator.
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
| `probe-http` | Makes an HTTP request to `server` every `PROBE_INTERVAL` (default 2s). This is what an application sees. |
| `probe-tcp-new` | Opens a **new** TCP connection to the opaque port on every attempt, sends one line, expects the echo, then closes. |
| `probe-tcp-stream` | Opens **one** TCP connection to the opaque port and holds it, sending a line every `PROBE_INTERVAL`. It logs the connection's start, every exchange, and the close or error. |

**Why three probes.** The validation contract requires established-session and newly negotiated connections to be reported separately. The proxy pools outbound HTTP connections, so one HTTP request doesn't imply a new proxy-to-proxy mTLS handshake. The HTTP probe can't separate the two cases on its own.

**Unverified:** on an opaque port, each application TCP connection gets its own proxy-to-proxy TLS connection. If that holds, `probe-tcp-new` forces a handshake per attempt and `probe-tcp-stream` holds one session. The first baseline run tests it: the proxy's TCP/TLS connection metrics for `probe-tcp-new` should rise by one per attempt. If they don't, the probe design is revised before any fault run.

**Probe output format.** Each line is `<UTC ISO-8601> <probe> <ok|fail> <detail>` on stdout. The collector reads it back with `kubectl logs`, so probe state survives until the run is collected.

**Certificate observation.**

- **Workload leaves.** Each meshed pod's proxy exposes identity metrics on `:4191/metrics`. The metric stems `expiration_timestamp`, `refresh_timestamp`, and `refreshes` were read from proxy source. **Unverified:** their exported names (expected prefix `identity_cert_`); the first baseline run confirms them. These give each workload leaf's `notAfter` and refresh history over time.
- **Issuer.** The identity controller exposes `issuer_cert_ttl_seconds` on `:9990`. It goes negative after expiry, so it serves as a countdown in the timeline.
- **Trust anchor.** No metric exists (**Source:** it is a `TODO` in the identity controller), so the anchor's `notAfter` comes from `certs/`.

## 3. Evidence capture

Every scenario run writes `demos/cert-hygiene/runs/<scenario>/<UTC-start>/`:

| Path | Contents |
| --- | --- |
| `versions.txt` | Linkerd CLI, control plane, and proxy versions; k3s/Kubernetes version; OrbStack version; image digests; every config value used; the effective identity controller args (`-identity-issuance-lifetime`, `-identity-clock-skew-allowance`) |
| `certs/` | Trust anchor and issuer PEMs (certificates only, never keys), plus `step certificate inspect` output: serial, issuer, SANs, `notBefore`, `notAfter` |
| `timeline.log` | Harness phase markers with UTC timestamps: `reset`, `baseline`, `fault`, `observe-N`, `recover`, `verify` |
| `checks/<tick>-check.txt`, `checks/<tick>-check-proxy.txt` | Raw `linkerd check` and `linkerd check --proxy` output, each with its exit code |
| `probes/<probe>.log` | Probe output (§ 2) |
| `metrics/<tick>.txt` | Proxy identity metrics for every meshed pod; the identity controller's `issuer_cert_ttl_seconds` |
| `logs/` | `linkerd-identity` logs; proxy logs of each lab pod; the k3s server journal slice for the run window (API-server side) |
| `events.txt` | `kubectl get events -A`, sorted by time. This includes the identity controller's `IssuerValidationFailed`, `IssuerUpdated`, and `IssuerUpdateSkipped` events. |
| `pods/<tick>.txt` | `kubectl get pods -A -o wide`: readiness and restart counts |

Rules:

- Evidence is written once and never edited. When the article quotes a transcript, it cites the run directory.
- Each run is committed and pushed as soon as it is collected, so no evidence exists only in one working tree.
- Private keys stay inside the VM and under `.gitignore`d paths. They are never copied into `runs/`.
- **Short-lived certificates trigger `linkerd check` warnings from the start.** Every short-lived cert shows `‼ ... valid for at least 60 days` immediately (**Source:** the threshold is fixed at 60 days). "Checks pass" therefore means *no fatal (`×`) result*, judged from the recorded exit code and output, and never from the absence of warnings.

## 4. Scenario #5: issuer expiry, with the trust anchor and its key intact

### 4.1 What source reading already answers

These were questions for a feasibility run; source reading settles them in advance:

- **The CLI accepts a minutes-long issuer.** **Source:** `linkerd install` rejects only issuers that are already expired or not yet valid. It enforces no minimum remaining validity.
- **The leaf lifetime is set by `--identity-issuance-lifetime`** (Helm `identity.issuer.issuanceLifetime`, default 24h). It has no minimum. **Source:** an unparseable value silently becomes 24h, so the harness never trusts the flag. After baseline it reads a leaf's expiry metric and **fails loudly** if the leaf outlives `LEAF_LIFETIME` + clock skew (20s).
- **Leaves are clamped to the issuer's `notAfter`.** **Source:** every workload leaf therefore expires at the same instant as the issuer.

The lab still has two items to settle: the opaque-port probe assumption (§ 2) and the metric names (§ 2).

### 4.2 Hypotheses the run tests

All of these come from source reading (see the notes). Each one names the evidence that would confirm or falsify it.

| # | Hypothesis | Falsified by |
| --- | --- | --- |
| H1 | As `T_iss` approaches, proxies refresh ever more often (70% of remaining lifetime, never sooner than 10s), because each new leaf is clamped to `T_iss`. | Refresh timestamps in `metrics/` |
| H2 | At `T_iss` every workload leaf expires at once. Failure is **simultaneous**, not gradual. | Leaf `notAfter` values in `metrics/`; probe failure times across pods |
| H3 | After `T_iss` the identity controller stays running and ready but refuses every CSR, emitting an `IssuerValidationFailed` event each time. | `pods/`, `events.txt`, identity logs |
| H4 | Proxies log `Failed to obtain identity` and retry every 10s. | Proxy logs |
| H5 | New connections (`probe-tcp-new`, `probe-http`) fail once leaves expire. | Probe logs |
| H6 | An established TLS session (`probe-tcp-stream`) survives leaf expiry, because TLS does not revalidate a peer mid-session. | `probe-tcp-stream` log |
| H7 | A pod created, or restarted, after `T_iss` never becomes Ready, because the proxy waits for an identity before serving. | `pods/` for `probe-new` and `server-restarted` |
| H8 | After a valid issuer is written to the `linkerd-identity-issuer` Secret, the identity controller reloads it with no restart (`IssuerUpdated`), once the kubelet has propagated the Secret, and proxies re-certify on their next 10s retry, also with no restart. | `events.txt`, pod restart counts, probe recovery times |

The harness records what happens either way. A falsified hypothesis is a finding for the article, not a harness failure.

### 4.3 Timeline

Config values: `ANCHOR_LIFETIME` is long enough that it can't expire during a run (default 720h); `ISSUER_LIFETIME` defaults to 15m; `LEAF_LIFETIME` defaults to 5m; `POST_EXPIRY_WINDOW` defaults to 10m. `T_iss` is the issuer's `notAfter`.

| Phase | Action | Captured |
| --- | --- | --- |
| reset | `reset_k3s`; generate the anchor and short-lived issuer; `linkerd_install … --identity-issuance-lifetime=$LEAF_LIFETIME`; deploy the § 2 workloads | `versions.txt`, `certs/` |
| baseline | Wait until all probes report `ok`; verify the effective leaf lifetime (§ 4.1); snapshot | checks, metrics, probe logs |
| observe (pre-expiry) | Snapshot every `OBSERVE_INTERVAL` (default 30s) until `T_iss` | checks, metrics, pods |
| fault | None applied. The fault is the issuer reaching `T_iss`. Snapshots at `T_iss − 1m`, `T_iss − 10s`, and `T_iss + 10s` | checks, identity logs, events |
| observe (post-expiry) | At `T_iss + 1m`, create a **new** meshed pod (`probe-new`) and **restart** a copy of an existing workload (`server-restarted`). Leave `server` and the three probes untouched. Snapshot every `OBSERVE_INTERVAL` until `T_iss + POST_EXPIRY_WINDOW` | checks, metrics, pods, identity and proxy logs, events, probe logs |
| recover | Sign a replacement issuer from the **same** anchor and apply it by the procedure in [Replacing expired certificates](https://linkerd.io/docs/tasks/replacing_expired_certificates/), recording the exact commands. Poll for `IssuerUpdated`: no fixed sleeps, because kubelet Secret propagation takes a variable time. Record whether proxies recover without restarts. Restart only what stays broken, and record each restart | checks, events, identity logs, probe logs, pods |
| verify | All probes `ok`; `probe-new` and `server-restarted` Ready; no fatal result in `linkerd check` or `linkerd check --proxy` | checks, pods |

**Note on recovery.** If the procedure uses `linkerd upgrade`, it re-renders the webhook certificates too (**Source:** they are regenerated on every render). That is harmless here, and `versions.txt` records it so it isn't mistaken for a change the scenario made.

### 4.4 Negative control

A `00-baseline-control` run uses the same workloads, duration, and snapshot cadence, with long-lived credentials. Every probe must stay `ok` for the full window, and `linkerd check` must show no warnings. This shows that failures in #5 come from the credential lifecycle, not from the harness, the probes, or k3s.

### 4.5 What this answers from the validation contract

| Validation question | Answered by |
| --- | --- |
| Issuer expiry, immediate effect | Snapshots around `T_iss`; H2, H3 |
| Existing leaves approaching expiry | Metrics time series for untouched pods; H1 |
| New and restarted proxies after issuer expiry | `probe-new` and `server-restarted`; H7 |
| Exact errors from failed renewal | Raw identity, proxy, and probe logs; H3, H4 |
| Whether established connections survive | `probe-tcp-stream` against `probe-tcp-new`; H5, H6 |
| Exact `linkerd check` output | Every tick |

Trust-anchor expiry (#6) reuses this harness with a short `ANCHOR_LIFETIME`. It is outside this slice. **Source:** the failure there is *indirect*. Proxies ignore the anchor's own dates, so traffic keeps flowing until leaves expire, while the identity controller refuses to sign immediately.

## 5. Harness verification

- `bash -n` and `shellcheck` on all new and touched scripts.
- The negative control (§ 4.4) passes before any #5 run is treated as evidence.
- A #5 run counts toward the article only if its `versions.txt`, `certs/`, and `timeline.log` are complete, every tick's checks were captured, and the effective-leaf-lifetime check (§ 4.1) passed. The collector fails loudly on a missing artifact and never writes a placeholder.

## 6. Out of scope for this slice

- Every scenario other than #5 and the baseline control. The next slice is the webhook group (#1–#3), which reuses § 1–§ 3 unchanged. **Source:** Linkerd's generated webhook certs are fixed at 365 days, so that slice must supply its own via `crtPEM`/`keyPEM`/`caBundle`, and must set `caBundle`, or the chart pairs the cert with an unrelated CA.
- Linkerd Viz. It adds webhook and APIService certificates that belong to the webhook slice, not here.
- libvirt and Lima backends (§ 1.3).
- Reader-facing walkthroughs.

## 7. Open questions

| Question | Blocks | Resolved by |
| --- | --- | --- |
| Opaque-port connection-per-connection behavior | § 2 probe design | First baseline run |
| Exported proxy identity metric names | § 2 leaf observation | First baseline run |
| OrbStack home mount inside machines | § 1.3 copy/no-copy | First `lab-up` |
| Exact recovery commands in the current "Replacing expired certificates" doc | § 4.3 recover phase | Read the doc when implementing the phase |

## 8. Impact on the article brief

Source reading contradicts or sharpens several rows of the brief's triage table. These are **not yet evidence**. Each becomes a claim only after the lab confirms it (§ 4.2) or a later slice does.

| Brief says | Source says | Settled by |
| --- | --- | --- |
| Issuer expiry: "failure spreads gradually" | Leaves are clamped to the issuer's `notAfter`, so they all expire together at `T_iss` | #5 (H2) |
| Policy-validator: "a Fail policy turns an expired cert into a hard admission rejection" | Every Linkerd webhook defaults to `failurePolicy: Ignore`, so an expired validator cert lets unvalidated resources through **silently**. No rejection happens unless the operator changed `webhookFailurePolicy`. | Webhook slice |
| Trust anchor expired: "peers can't validate each other" | Proxies don't check the anchor's own dates. Visible breakage waits until leaves expire, while identity refuses to sign immediately. | #6 |
| "Exact `linkerd check` output for each failure" | `linkerd check` never inspects workload leaf certs or the tap-injector cert, and warns at a fixed 60 days | #5, webhook slice |
