# Cert-Hygiene Demo Lab — Design

**Status:** Approved after a third-party review ([review](../reviews/2026-09-10-cert-hygiene-demo-lab-design-review.md); dispositions in § 9). Implementation plan: [`docs/superpowers/plans/2026-09-10-cert-hygiene-demo-lab/`](../plans/2026-09-10-cert-hygiene-demo-lab/README.md).

Linkerd behavior described here comes from reading source at tag `edge-26.9.1`; the details and permalinks are in [linkerd-source-notes.md](../../articles/cert-hygiene/notes/linkerd-source-notes.md). Behavior read from source is labelled **Source** and is treated as a *hypothesis the lab run tests*, not as article evidence. Items only the lab can settle are labelled **Unverified**.

The chain of evidence is **source → hypothesis → lab observation → article claim**. Scripts never grade hypotheses (§ 5).

**Inputs:** [article README](../../articles/cert-hygiene/README.md), [demo-feasibility.md](../../articles/cert-hygiene/notes/demo-feasibility.md) (scenario numbering and the article validation contract), [sources.md](../../articles/cert-hygiene/sources.md), [linkerd-source-notes.md](../../articles/cert-hygiene/notes/linkerd-source-notes.md).

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
    baseline.yaml               server, probes, restart target (§ 2)
    probe-new.yaml              workload first created after T_iss (§ 4.3)
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

## 2. Workloads and probes

All workloads run in a meshed namespace, `lab`. Images are multi-arch, pinned by digest, and the digests are recorded in every run.

| Workload | Created | Role |
| --- | --- | --- |
| `server` | reset | Serves HTTP on one port and a TCP line-echo on a second port, annotated opaque (`config.linkerd.io/opaque-ports`). It is never restarted during a run, because the established stream depends on it. |
| `probe-http` | reset | One HTTP request to `server` every `PROBE_INTERVAL` (default 2s). **What an ordinary application sees** (below). |
| `probe-tcp-new` | reset | Opens a **new** TCP connection to the opaque port on every attempt, sends one line, expects the echo, then closes. **A forced new connection.** |
| `probe-tcp-stream` | reset | Opens **one** TCP connection to the opaque port and holds it, sending a line every `PROBE_INTERVAL`. **A controlled established connection** (below). |
| `restart-target` | reset | An idle meshed Deployment, one replica. Before the fault, its proxy is confirmed to hold an identity. It is rolled (`kubectl rollout restart`) after `T_iss`. This is a genuine restart of an existing workload, and it doesn't touch `server`. |
| `probe-new` | `T_iss + 1m` | A Deployment whose template is first applied after `T_iss`: a workload that never had an identity. |

**Probe semantics.**

- **`probe-http`** records exactly one application request result per attempt. Client retries are disabled (a single `curl` per attempt, no `--retry`), and no Linkerd retry policy is configured (no retry annotations or route retry settings, recorded in `versions.txt`). Connection reuse between proxies is left on deliberately: this probe represents ordinary HTTP behavior, not a handshake detector.
- **`probe-tcp-stream` fails closed.** When its connection closes or errors, it logs the event and then idles; it **never reconnects**. Its connection ID is `<pod-uid-prefix>-<connect-epoch>`, so a container or pod restart shows up as a new ID and can't pass for the original connection.

**Unverified:** on an opaque port, each application TCP connection gets its own proxy-to-proxy TLS connection. If that holds, `probe-tcp-new` forces a handshake per attempt and `probe-tcp-stream` holds one session. The first baseline run tests it: the proxy's TCP/TLS connection metrics for `probe-tcp-new` should rise by one per attempt. If they don't, the probe design is revised before any fault run.

**Probe output format.** One line per attempt on stdout:

```
<UTC ISO-8601> <probe> seq=<n> [conn=<id>] <ok|fail> <detail>
```

`seq` increments per attempt. `conn` is present only for `probe-tcp-stream`. The collector reads the lines back with `kubectl logs`.

**Certificate observation.**

- **Workload leaves.** Each meshed pod's proxy exposes identity metrics on `:4191/metrics`. The metric stems `expiration_timestamp`, `refresh_timestamp`, and `refreshes` were read from proxy source. Source reading suggested an `identity_cert_` prefix; discovery (§ 7) confirmed the exported names carry `control_identity_cert_` instead, so leaf expiry is `control_identity_cert_expiration_timestamp_seconds`. These give each workload leaf's `notAfter` and refresh history over time.
- **Issuer, as loaded.** The identity controller exposes `issuer_cert_ttl_seconds` on `:9990`. It is computed from the issuer the process currently holds, so it goes negative after expiry and jumps when a replacement is loaded.
- **Trust anchor.** No metric exists (**Source:** it is a `TODO` in the identity controller), so the anchor's `notAfter` comes from `certs/`.

## 3. Evidence capture

Every scenario run writes `demos/cert-hygiene/runs/<scenario>/<UTC-start>/`:

| Path | Contents |
| --- | --- |
| `versions.txt` | `demo_repo_commit`, `demo_repo_dirty`; Linkerd CLI, control plane, and per-pod proxy versions; k3s/Kubernetes version; OrbStack version; image digests; every config value used; the effective identity controller args (`-identity-issuance-lifetime`, `-identity-clock-skew-allowance`); whether any retry policy exists in `lab` |
| `harness.diff` | `git diff HEAD` of the repo, excluding `runs/`. Written only when `demo_repo_dirty=true`. |
| `certs/` | `trust-anchor.pem`, `issuer-initial.pem`, `issuer-replacement.pem`, each with a `.txt` from `step certificate inspect` (serial, issuer, SANs, `notBefore`, `notAfter`, fingerprint). Certificates only, never keys. |
| `timeline.log` | Harness phase markers with UTC timestamps: `reset`, `baseline`, `fault`, `observe-N`, `recover`, `verify` |
| `checks/<tick>-check.txt`, `checks/<tick>-check-proxy.txt` | Raw `linkerd check` and `linkerd check --proxy` output, each with its exit code |
| `probes/<label>/<pod>.log`, `probes/<label>/<pod>-previous.log`, `probes/<label>/pods.txt` | Probe output (§ 2) from every pod of each probe, Terminating pods included, current and previous container, at each labelled point (`final`; for #5 also `pre-stage1` and `pre-stage2`, before each restart stage; `aborted`) |
| `metrics/<tick>.txt` | Proxy identity metrics for every meshed pod; the identity controller's `issuer_cert_ttl_seconds` |
| `secrets/<tick>-identity-issuer.txt` | Metadata of the `linkerd-identity-issuer` Secret: `uid`, `resourceVersion`, and the serial, fingerprint, and `notAfter` of its **certificate field only**. The collector extracts fields with jsonpath and never reads the key field. |
| `trust/<tick>.txt` | SHA-256 of `linkerd-identity-trust-roots/ca-bundle.crt`, plus each meshed pod's `linkerd.io/trust-root-sha256` annotation |
| `logs/` | `linkerd-identity` logs; proxy logs of each lab pod; the k3s server journal slice for the run window (API-server side). Every container of each lab pod is captured, init containers included, because the `linkerd-proxy` runs as a native-sidecar init container: `logs/<label>/<pod>-<container>.txt` and `-previous.txt` |
| `events/<label>.txt` | `kubectl get events -A`, sorted by time, snapshotted at several labelled points because Kubernetes drops events after an hour. This includes the identity controller's `IssuerValidationFailed`, `IssuerUpdated`, and `IssuerUpdateSkipped` events. |
| `pods/<tick>.txt` | `kubectl get pods -A -o wide`: readiness and restart counts |
| `pods/<tick>-<pod>.yaml`, `pods/<tick>-<pod>-describe.txt` | For `probe-new` and every `restart-target` pod: full status, container states, readiness conditions, and events. This is what links "not Ready" to "proxy has no identity". |
| `recover/<tick>-gate.txt` | #5 only: every input the recovery gate read at that recover tick (each gated probe's latest line and both rollout statuses, with exit codes) and its verdict |

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

All of these come from source reading (see the notes). Each one names the evidence that would confirm or falsify it. The run records what happens either way. A falsified hypothesis is a finding for the article, not a failed run.

| # | Hypothesis | Falsified by |
| --- | --- | --- |
| H1 | As `T_iss` approaches, proxies refresh ever more often (70% of remaining lifetime, never sooner than 10s), because each new leaf is clamped to `T_iss`. | Refresh timestamps in `metrics/` |
| H2 | Every workload leaf is clamped to the same `T_iss`, so all workload identities expire at the same instant rather than aging out independently. **This is a statement about credentials, not traffic.** Observed traffic failure may not be simultaneous; H5 and H6 test that separately. | Leaf `notAfter` values in `metrics/` |
| H3 | After `T_iss` the identity controller stays running and ready but refuses every CSR, emitting an `IssuerValidationFailed` event each time. **Competing prediction (source):** the identity pod's own proxy requires TLS on the identity port 8080 (`requireTLSOnInboundPorts "8080"` in the identity chart), and its own leaf also expired at `T_iss`. Other proxies' CSRs may then fail at the TLS handshake and never reach the controller, leaving `IssuerValidationFailed` to come only from the identity pod's own proxy. | `pods/`, `events/`, identity and identity-proxy logs, workload proxy logs (handshake error versus validation error) |
| H4 | Proxies log `Failed to obtain identity` and retry every 10s. | Proxy logs |
| H5 | Newly negotiated mTLS connections (`probe-tcp-new`) begin failing at `T_iss`. | `probe-tcp-new` log |
| — | **No prediction for `probe-http`.** Pooled proxy-to-proxy connections opened before `T_iss` are established sessions, so whether HTTP fails at `T_iss` or later depends on pool reuse and idle timeouts. The result is recorded as observed. | — |
| H6 | The established session (`probe-tcp-stream`, one `conn` ID throughout) survives leaf expiry, because TLS doesn't revalidate a peer's certificate mid-session. | `probe-tcp-stream` log |
| H7a | `probe-new`, a workload first created after `T_iss`, never becomes Ready, because its proxy waits for an identity before serving. | `pods/` YAML and describe for `probe-new`; its proxy log |
| H7b | Rolling `restart-target` after `T_iss` produces a replacement pod that never becomes Ready. With one replica and the default rolling-update strategy, the rollout stalls and the old pod keeps running. That reproduces the brief's "a deployment fails to roll out while existing workloads keep running". | `pods/` YAML and describe for both `restart-target` pods; `kubectl rollout status` output |
| H8 | Once a replacement issuer is written, recovery proceeds through this chain, and no pod restarts are needed: Secret updated (`resourceVersion` changes) → identity loads it (`issuer_cert_ttl_seconds` jumps; `IssuerUpdated` event, after kubelet propagation) → proxies re-certify on their next 10s retry (leaf metrics) → probes recover. | `secrets/`, `metrics/`, `events.txt`, pod restart counts, probe logs |

### 4.3 Timeline

Config values: `ANCHOR_LIFETIME` is long enough that it can't expire during a run (default 720h); `ISSUER_LIFETIME` defaults to 15m; `LEAF_LIFETIME` defaults to 5m; `POST_EXPIRY_WINDOW` defaults to 10m. `T_iss` is the issuer's `notAfter`.

| Phase | Action | Captured |
| --- | --- | --- |
| reset | `reset_k3s`; generate the anchor and short-lived issuer; `linkerd_install … --identity-issuance-lifetime=$LEAF_LIFETIME`; deploy the § 2 workloads created at reset | `versions.txt`, `certs/trust-anchor.*`, `certs/issuer-initial.*` |
| baseline | Wait until all probes report `ok` and `restart-target` holds an identity; verify the effective leaf lifetime (§ 4.1); snapshot | checks, metrics, secrets, trust, probe logs |
| observe (pre-expiry) | Snapshot every `OBSERVE_INTERVAL` (default 30s) until `T_iss` | checks, metrics, pods |
| fault | None applied. The fault is the issuer reaching `T_iss`. Snapshots at `T_iss − 1m`, `T_iss − 10s`, and `T_iss + 10s` | checks, identity logs, events |
| observe (post-expiry) | At `T_iss + 1m`, apply `probe-new` and roll `restart-target`. Leave `server` and the three probes untouched. Snapshot every `OBSERVE_INTERVAL` until `T_iss + POST_EXPIRY_WINDOW` | checks, metrics, pods (with YAML and describe), identity and proxy logs, events, probe logs |
| recover | Sign a replacement issuer from the **same** anchor and apply it by the procedure in [Replacing expired certificates](https://linkerd.io/docs/tasks/replacing_expired_certificates/), recording the exact commands. Poll for `IssuerUpdated`: no fixed sleeps, because kubelet Secret propagation takes a variable time. Record whether proxies recover without restarts. Restart only what stays broken, and record each restart | `certs/issuer-replacement.*`, secrets, metrics, events, identity logs, probe logs, pods |
| verify | All probes `ok`; `probe-new` and the new `restart-target` pod Ready; no fatal result in `linkerd check` or `linkerd check --proxy` | checks, pods, trust |

**Recovery invariant: the trust anchor must not change.** Recovery tests *issuer replacement*, not trust-root rotation. The replacement issuer is signed by the existing anchor, and nothing in the recover phase may write the trust-roots ConfigMap or re-inject pods with a different bundle. The harness checks this with the `trust/` snapshots taken at baseline, before recover, and at verify. If any hash differs, the run is marked invalid as evidence (§ 5). That can happen if the documented procedure touches the anchor, for example via `linkerd upgrade` flags.

**Note on recovery via `linkerd upgrade`.** If the documented procedure uses `linkerd upgrade`, it also re-renders the webhook certificates (**Source:** they are regenerated on every render). That is harmless to this scenario, and `versions.txt` records it so it isn't mistaken for a change the scenario made.

### 4.4 Negative control

A `00-baseline-control` run uses the same workloads, duration, snapshot cadence, and post-expiry actions (apply `probe-new`, roll `restart-target`), with long-lived credentials. Criteria:

- Every probe stays `ok` for the full window, `probe-tcp-stream` keeps one `conn` ID, and `probe-new` and the rolled `restart-target` become Ready.
- Checks contain no fatal result and **no certificate-lifetime warning**.
- Any other warning (environmental ones from k3s, OrbStack, or a newer edge being available) must appear identically in the #5 run, or be explained relative to it.

This shows that failures in #5 come from the credential lifecycle, not from the harness, the probes, or k3s.

### 4.5 What this answers from the validation contract

| Validation question | Answered by |
| --- | --- |
| Issuer expiry, immediate effect | Snapshots around `T_iss`; H2, H3, H5 |
| Existing leaves approaching expiry | Metrics time series for untouched pods; H1 |
| New and restarted proxies after issuer expiry | `probe-new` and `restart-target`; H7a, H7b |
| Exact errors from failed renewal | Raw identity, proxy, and probe logs; H3, H4 |
| Whether established connections survive | `probe-tcp-stream` against `probe-tcp-new`; H5, H6 |
| Exact `linkerd check` output | Every tick |

Trust-anchor expiry (#6) reuses this harness with a short `ANCHOR_LIFETIME`. It is outside this slice. **Source:** the failure there is *indirect*. Proxies ignore the anchor's own dates, so traffic keeps flowing until leaves expire, while the identity controller refuses to sign immediately.

## 5. Harness validity is separate from hypothesis outcome

Two separate questions apply to every run:

1. **Is this run valid evidence?** The harness answers this mechanically and writes the answer, `evidence_valid=yes|no` with the reasons, to `validity.txt` (`versions.txt` is written once, at the start). A run is valid only if all of the following hold:
   - `demo_repo_dirty=false`
   - `versions.txt`, `certs/`, and `timeline.log` are complete
   - every tick's checks were captured
   - in every `logs/<label>/`, each lab pod with an application-container log also has its `<pod>-linkerd-proxy.txt`
   - the effective-leaf-lifetime check (§ 4.1) passed
   - the trust-anchor invariant (§ 4.3) held
   - for the control, its § 4.4 criteria that a script can judge were met (`control-criteria.txt`)
   - for #5, the recovery apply succeeded: `recover/linkerd-upgrade.txt` ends `[exit 0]`
   - for #5, a valid control ran at the same **harness tree**: `lib/` plus `demos/cert-hygiene/` excluding `runs/`, hashed. A tree rather than a commit, because committing a run's evidence moves HEAD without changing the harness.

   The collector fails loudly on a missing artifact and never writes a placeholder. A dirty-tree run is allowed for development, records `harness.diff`, and is never valid evidence. An aborted run is evaluated too, so its `validity.txt` says why it does not count. A rule added to this list applies to runs recorded after it; earlier runs keep the verdict their harness tree computed.
2. **What happened to H1–H8?** Scripts **never** evaluate this. They record raw observations only. The hypothesis outcomes are judged by reading the evidence and are written up in `docs/articles/cert-hygiene/`, citing the run directory.

Also:

- `bash -n` and `shellcheck` on all new and touched scripts.

## 6. Out of scope for this slice

- Every scenario other than #5 and the baseline control. The next slice is the webhook group (#1–#3), which reuses § 1–§ 3 unchanged. **Source:** Linkerd's generated webhook certs are fixed at 365 days, so that slice must supply its own via `crtPEM`/`keyPEM`/`caBundle`, and must set `caBundle`, or the chart pairs the cert with an unrelated CA.
- Linkerd Viz. It adds webhook and APIService certificates that belong to the webhook slice, not here.
- libvirt and Lima backends (§ 1.3).
- Reader-facing walkthroughs.

## 7. Open questions

| Question | Blocks | Resolved by |
| --- | --- | --- |
| Opaque-port connection-per-connection behavior | § 2 probe design | Resolved: each new application TCP connection to the opaque port produces its own outbound proxy-to-proxy TLS connection (`tcp_open_total` delta == attempt count, 15 == 15), see demos/cert-hygiene/runs/_discovery/20260911T004528Z/FINDINGS.md |
| Exported proxy identity metric names | § 2 leaf observation | Resolved: leaf expiry is `control_identity_cert_expiration_timestamp_seconds`, refresh count `control_identity_cert_refreshes_total`, refresh time `control_identity_cert_refresh_timestamp_seconds`, see demos/cert-hygiene/runs/_discovery/20260911T004528Z/FINDINGS.md |
| OrbStack home mount inside machines | § 1.3 copy/no-copy | Resolved: mounted at the same path (Task 1 lab-up check) |
| Exact recovery commands in the current "Replacing expired certificates" doc, and whether they touch the anchor | § 4.3 recover phase and its invariant | Resolved: for the issuer-only case the doc points to the [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/). It applies the new issuer with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… \| kubectl apply -f -`, passes no trust-anchor flag and no `--force`, and then says to restart the proxies of all injected workloads. The #5 run's `trust/` snapshots confirm the anchor was untouched (`trust-invariant.txt`: `ok: trust configuration identical across 3 snapshots`), see demos/cert-hygiene/runs/05-issuer-expiry/20260911T021157Z |

## 8. Impact on the article brief

Source reading contradicts or sharpens several rows of the brief's triage table. These are **not yet evidence**. Each becomes a claim only after the lab confirms it (§ 4.2) or a later slice does.

| Brief says | Source says | Settled by |
| --- | --- | --- |
| Issuer expiry: "failure spreads gradually" | **Certificate expiry is simultaneous; observed traffic failure may not be.** Leaves are clamped to the issuer's `notAfter`, so every identity expires at `T_iss`, but established and pooled connections may outlive that boundary. | #5 — see docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry.md |
| Policy-validator: "a Fail policy turns an expired cert into a hard admission rejection" | Every Linkerd webhook defaults to `failurePolicy: Ignore`, so an expired validator cert lets unvalidated resources through **silently**. No rejection happens unless the operator changed `webhookFailurePolicy`. | Webhook slice |
| Trust anchor expired: "peers can't validate each other" | Proxies don't check the anchor's own dates. Visible breakage waits until leaves expire, while identity refuses to sign immediately. | #6 |
| "Exact `linkerd check` output for each failure" | `linkerd check` never inspects workload leaf certs or the tap-injector cert, and warns at a fixed 60 days | #5 — see docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry.md; webhook slice |

## 9. Review dispositions

Third-party review of the previous revision: [2026-09-10-cert-hygiene-demo-lab-design-review.md](../reviews/2026-09-10-cert-hygiene-demo-lab-design-review.md).

| # | Review item | Disposition |
| --- | --- | --- |
| 1 | H2 conflates credential expiry with traffic failure | **Accepted** (§ 4.2 H2, § 8). **Extended:** the old H5 made the same mistake for `probe-http`, whose pooled connections are established sessions. HTTP now carries no prediction. |
| 2 | Recovery must preserve the trust anchor; capture the replacement issuer | **Accepted.** The invariant is stated *and made checkable* with `trust/` hashes that can invalidate the run (§ 4.3, § 5). `certs/issuer-replacement.*` added (§ 3). |
| 3 | Record the Secret transition, including the mounted cert as the identity container sees it | **Accepted, with a different method for the mounted-cert link.** The Linkerd controller images are very likely built without a shell (unverified), so `kubectl exec` into them isn't a dependable way to read the mounted file. The in-process `issuer_cert_ttl_seconds` gauge is stronger evidence that the identity process loaded the new issuer. The chain is Secret `resourceVersion` → gauge jump + `IssuerUpdated` → leaf metrics → probes (§ 4.2 H8, § 3 `secrets/`). |
| 4 | Sequence numbers and connection IDs; stream must fail closed | **Accepted** (§ 2). The connection ID embeds the pod UID and connect time, so even a container restart can't pass for the original connection. |
| 5 | HTTP probe must not retry | **Accepted** (§ 2), including confirming that no *Linkerd* retry policy applies. The proxy, not only `curl`, could otherwise retry. |
| 6 | Negative control's "no warnings" is brittle | **Accepted** (§ 4.4). |
| 7 | Pod YAML and describe for post-expiry pods | **Accepted** (§ 3). |
| 8 | `server-restarted` was ambiguous | **Accepted as a wording fix.** The intent was the reviewer's preferred option: a dormant Deployment created at baseline and rolled after expiry. It is now named `restart-target`. The review also surfaced H7b: with one replica the rollout should stall with the old pod still running. |
| — | Keep harness validity separate from hypothesis outcome | **Accepted** as § 5. |
| — | Git state in `versions.txt`; refuse or diff dirty runs | **Accepted, as diff-and-mark-invalid rather than refuse.** Dirty-tree runs are allowed for development iteration, record `harness.diff`, and are never valid evidence (§ 5). |
