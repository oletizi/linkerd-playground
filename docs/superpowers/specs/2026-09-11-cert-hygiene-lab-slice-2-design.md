# Cert-Hygiene Lab, Slice 2 — Design

**Status:** Revised after a third-party review ([review](../reviews/2026-09-11-cert-hygiene-lab-slice-2-design-review.md); dispositions in § 12). Awaiting approval.

**Builds on:** [slice 1 design](2026-09-10-cert-hygiene-demo-lab-design.md). Its substrate, versions, evidence rules, and validity model all carry over unchanged unless this document says otherwise. This is an internal design document; it uses the lab's shorthand, which the reader-facing article pages avoid.

**Why:** [findings.md](../../articles/cert-hygiene/findings.md) splits its triage table into "reproduced in the lab" and "expected from Linkerd's code, not yet tested". This slice tests the second table and answers the open questions the first issuer run left.

**Approved order:**
1. **R** — issuer-expiry re-run
2. **W** — webhook certificates
3. **O** — identity-service outage
4. **K** — `linkerd check` thresholds
5. **A** — trust-anchor expiry
6. **S** — trust-anchor rotation, staged and hard swap
7. **V** — tap/viz. Optional; confirm with the user before starting.

**Two scenarios that look alike but answer different questions.** A asks "what do I do after trust is already broken?" S asks "how do I rotate trust without breaking it?" Linkerd documents them as separate procedures. Its manual rotation guide applies while the existing anchor is still valid, and it sends readers with an already-expired anchor to the expired-certificate replacement procedure instead.

**Three failures compared side by side.** R, O and A isolate three failures that look similar but work differently:

| Scenario | Is the signer valid? | Can workloads reach the identity service? |
| --- | --- | --- |
| R — issuer expired | No: the issuer is invalid | Yes |
| O — identity outage | Yes | No, temporarily |
| A — anchor expired | The issuer is still within its dates, but its signing authority is gone | Yes |

The findings will present them side by side (§ 11).

## Decisions

| Question | Decision |
| --- | --- |
| Substrate, versions, lifetimes | Unchanged from slice 1: OrbStack VM, k3s, Linkerd `edge-26.9.1`, clocks never altered, keys never in the repo. |
| Negative control | Still required at the same harness tree for every timed scenario. The control proves that the harness, probes and k3s cause no failures of their own. |
| **Discovery versus evidence runs** | Implementation details that need the lab are settled first, in throwaway `runs/_discovery/<stamp>/` runs: which resources the validators reject, whether `linkerd install` accepts supplied webhook certificates, and the metric names. Discovery runs never count as evidence. Then: (1) commit the harness; (2) confirm a clean tree; (3) run the control; (4) run R, W, O, K, A and S against that same tree; (5) make no harness changes between evidence runs. A fix found mid-way means: commit, re-run the control, and re-run only the affected scenarios. |
| Hypotheses | Stated per scenario below. Scripts record evidence and judge validity only; hypotheses are judged in per-scenario write-ups under `docs/articles/cert-hygiene/notes/`, as in slice 1. |
| Reader-facing docs | A row moves from the "not yet tested" table to "reproduced" in `findings.md`, or is corrected, only after its write-up exists. The README status and the `sources.md` "our lab" entry are updated in the same commit. |

## 1. Harness generalisation

### 1.1 Credential profiles and webhook-credential models

`lab/reset.sh <short|long> <name>` becomes `lab/reset.sh <profile> <name>`. Each profile is a file, `lab/profiles/<profile>.env`, holding:

- `ANCHOR_LIFETIME`, `ISSUER_LIFETIME`, `LEAF_LIFETIME`
- `WEBHOOK_CERT_LIFETIME`: empty means Linkerd generates its own webhook certificates, as today
- `EXTRA_INSTALL_FLAGS`, e.g. `--set webhookFailurePolicy=Fail`

Linkerd supports three ways of managing webhook credentials, and the lab uses two of them:

- **Linkerd-managed** (the default): Linkerd generates each webhook's serving certificate, valid for 365 days. Linkerd's rotating-webhooks guide (delete the Secrets, run `linkerd upgrade`) is written for this model. Every profile without `WEBHOOK_CERT_LIFETIME` uses it.
- **Externally managed:** an external system such as cert-manager owns the Secrets, and Linkerd is configured with `externalSecret=true` plus the CA bundle. **Not tested in this slice** (§ 9).
- **Lab-supplied static credentials:** the `webhook-short*` profiles, which exist to force a minutes-long expiry. When `WEBHOOK_CERT_LIFETIME` is set, `reset.sh`:
  1. Creates a lab webhook CA inside the VM.
  2. Signs serving certificates for `linkerd-proxy-injector.linkerd.svc`, `linkerd-policy-validator.linkerd.svc` and `linkerd-sp-validator.linkerd.svc`.
  3. Passes each to Linkerd's renderer through `--set-file <component>.crtPEM=…,<component>.keyPEM=…,<component>.caBundle=…`. The components are `proxyInjector`, `policyValidator` and `profileValidator`. `caBundle` must be set, or the chart pairs the certificate with an unrelated CA (source notes § 5). `linkerd install --set-file` is confirmed available.

  This isn't how operators normally run Linkerd. That's why W's recovery tests both the documented procedure for Linkerd-managed credentials and the recovery appropriate to supplied ones (§ 3).

| Profile | Anchor | Issuer | Leaf | Webhook certs | Extra | Used by |
| --- | --- | --- | --- | --- | --- | --- |
| `long` | 87600h | 8760h | 5m | Linkerd-managed | — | control, O, S |
| `issuer-short` | 720h | 15m | 5m | Linkerd-managed | — | R |
| `webhook-short` | 87600h | 8760h | 5m | lab-supplied, 15m | — | W (Ignore) |
| `webhook-short-fail` | 87600h | 8760h | 5m | lab-supplied, 15m | `--set webhookFailurePolicy=Fail` | W (Fail) |
| `anchor-short` | 20m | 120m | 5m | Linkerd-managed | — | A |
| `check-threshold` | 87600h | per K step (§ 5) | 5m | Linkerd-managed | — | K |

`step` signs an issuer that outlives its anchor (confirmed in the lab VM), which A needs. The existing `short` and `long` modes become the `issuer-short` and `long` profiles, so the slice-1 scenarios keep working.

### 1.2 Scenario hooks

`run_scenario` keeps `scenario_mark_epoch` and `scenario_recover`, and gains three optional hooks:

- `scenario_fault`: an action at T_mark. The default is none, since for the expiry scenarios the expiry itself is the fault. O stops identity here.
- `scenario_post_actions`: runs at T_mark + 1m. The default is today's behaviour (apply `probe-new`, roll `restart-target`). W replaces it with its admission probes (§ 3).
- `scenario_tick_extra NAME`: extra per-tick capture. W uses it to repeat the admission probes on every tick.

### 1.3 Planned credential transitions (validity)

Slice 1 had one special-case rule: the trust anchor must not change. Slice 2 changes different credentials in different scenarios, so that rule becomes one general mechanism.

- **What the collector records:** on every tick, a credential state in `credentials/<tick>.txt`:
  - the trust-roots ConfigMap's SHA-256
  - the issuer certificate's serial and `notAfter`
  - each webhook serving certificate's serial and `notAfter`

  Each pod's trust-bundle hash, which `trust/<tick>.txt` already records, gives each endpoint's trust state.
- **What each scenario declares:** its planned credential sequence, as an ordered list of named states. Examples:
  - R: `I1 → I2`
  - W: `W1 → W2`
  - O: one state
  - A: `A/I1 → B/I2`
  - S-staged: `A/I1 → A+B/I1 → A+B/I2 → B/I2`
  - S-hard: `A/I1 → B/I2`
- **What validity requires:** the observed states, with consecutive repeats collapsed, walk the declared sequence in order. No undeclared credential state appears, and no state is skipped.

The slice-1 trust-anchor invariant becomes the special case "the anchor component never changes". The rest of `evaluate_validity` becomes one rule table in `lib-evidence.sh`, keyed by scenario name and unit-tested like the rest:

| Rule | Applies to |
| --- | --- |
| Common rules (clean tree, complete artifacts, per-tick files, leaf-lifetime check, proxy logs) | every scenario |
| Credential states walk the declared plan | every scenario |
| Recovery apply succeeded (`recover/linkerd-upgrade.txt` ends `[exit 0]`) | R, A |
| Webhook baseline proved the admission probes work (§ 3) | W |
| A valid control at the same harness tree | every timed scenario (all except K) |

### 1.4 Collector additions

- **Webhook state:** each Linkerd webhook configuration's `failurePolicy` and `caBundle` SHA-256, plus each webhook serving Secret's certificate metadata (serial, `notAfter`), in `webhooks/<tick>.txt`. The Secrets are `linkerd-proxy-injector-k8s-tls`, `linkerd-policy-validator-k8s-tls` and `linkerd-sp-validator-k8s-tls`, with the certificate under the `tls.crt` key. Only that field is read, never the key field.
- **Credential state:** `credentials/<tick>.txt` (§ 1.3).
- **Connection metrics:** proxy series matching `^(tcp_open_total|tcp_close_total|tcp_open_connections|outbound_tcp_route_open_total|outbound_tcp_route_close_total)`, alongside the identity series. All five names are present in slice 1's discovery data (`demos/cert-hygiene/runs/_discovery/20260911T004528Z`).
- **Control-plane pod identity:** each tick also records the `linkerd` namespace's pods with their UIDs and start times. This shows, for example, that O's recovery ran in a new identity process while the credentials stayed the same.
- **Pod listing per log snapshot:** `logs/<label>/pods.txt`, closing the parked "vacuous proxy-log rule" item.
- **APIService status**, for V only.
- **Write-up instructions:** the evidence-reading commands for write-ups move to the per-pod probe layout (`probes/<label>/<pod>.log`), closing the parked plan-Task-10 item.

### 1.5 A second forced-new-connection client

Slice 1 has one opaque-TCP client that opens a new connection per attempt (`probe-tcp-new` → `server`). Recovery stages are cumulative, so with a single client→server pair the "server fresh, client stale" case can never be observed: by the time `server` is restarted, the client already has been.

Slice 2 adds a second, identical client, `probe-tcp-new-b` → `server`. Restarting client A, then `server`, then everything fills all four combinations of client state and server state in one run (R, O, S-hard). `probe-tcp-new-b` is included in the control and every scenario, like the other probes.

## 2. Scenario R — issuer expiry, re-run

This is slice 1's scenario #5, with the fixed harness (workload proxy logs, per-pod probe history, gate records) plus:

- **Longer post-expiry window:** `POST_EXPIRY_WINDOW_S=1800` instead of 600, to see how long open connections and HTTP keep working.
- **Connection metrics on every tick** (§ 1.4).
- **Recovery stages that map endpoint state.** After the issuer is replaced:
  1. Wait `RECOVER_WINDOW_S` with no restarts.
  2. Restart client A (`probe-tcp-new`) only.
  3. Restart `server`.
  4. Restart every remaining lab Deployment.

  The gate inputs are recorded at every tick. The stages produce this matrix of certificate state ("fresh" means holding a certificate from the replacement issuer):

  | Stage | Pair A: client / server | Pair B: client / server |
  | --- | --- | --- |
  | 1. no restart | stale / stale | stale / stale |
  | 2. client A restarted | **fresh / stale** | stale / stale |
  | 3. `server` restarted | fresh / fresh | **stale / fresh** |
  | 4. all restarted | fresh / fresh | fresh / fresh |

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| R1 | `probe-http` keeps working after T_mark because it reuses a proxy-to-proxy connection opened before T_mark: its outbound `tcp_open_total` to `server` does not rise after T_mark. | Source-derived | Connection metrics |
| R2 | Pre-existing proxies fail to re-certify after the issuer is replaced because their TLS handshake to the identity service fails: their logs show handshake errors, not validation errors. | Inference (slice-1 notes) | Workload `linkerd-proxy` logs |
| R3 | A new proxy-to-proxy mTLS connection can't succeed while either endpoint still holds a certificate that is invalid after recovery. The matrix above shows which endpoint's state is necessary: only the fresh/fresh cells succeed. | Inference (mTLS validates both peers) | Gate records and probe logs per stage |
| R4 | The established stream survives the whole 30-minute window. | Source-derived | Stream probe log |

## 3. Scenario W — webhook certificates

Two runs: `webhook-short` (default `Ignore`) and `webhook-short-fail` (`Fail`). Both use lab-supplied static webhook credentials (§ 1.1). Anchor and issuer are long-lived. The three serving certificates for proxy-injector, policy-validator and sp-validator expire at T_mark. The mesh traffic probes keep running throughout.

**Admission probes.** These run at baseline, before expiry, on every tick after T_mark, and after recovery. Every attempt uses a fresh object with a unique name, so the API server must call admission each time:

- **(a) Pod:** create `inject-probe-<tick>` in the injected `lab` namespace, and record whether it has a `linkerd-proxy` container.
- **(b) Invalid policy:** apply `policy-invalid-<tick>`, a policy resource that the healthy policy-validator rejects.
- **(c) Invalid ServiceProfile:** apply `serviceprofile-invalid-<tick>`, which the healthy sp-validator rejects.
- **(d) Valid resources:** apply valid versions of (b) and (c).

A discovery run picks the invalid resources for (b) and (c). The baseline must show (b) and (c) rejected and (a) injected, or the run is invalid.

For each attempt, the run writes `admission/<phase>/<object>.request.yaml`, `<object>.response.txt` (the exact API response), and `<object>.observed.yaml` (the resulting object, if any). `<phase>` is `baseline`, `pre-expiry`, `post-NNN` or `recovered`. Every object that gets created is deleted once it has been observed, so the namespace doesn't fill up.

**Recovery, as a deliberate experiment.** This measures what the documented procedure does when credentials were supplied, and then what actually recovers them:

1. Delete the three `…-k8s-tls` Secrets (Linkerd's rotating-webhooks guide).
2. Run a plain `linkerd upgrade | kubectl apply -f -`.
3. Capture exactly what it rendered and applied.
4. Inspect the resulting serving certificates' serials and expiry.
5. If they are still the expired, supplied ones, pass freshly generated credentials explicitly with `--set-file`.
6. Record the recovery, and repeat the admission probes.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| W1 | With `Ignore`, after expiry: (a) yields a pod with no `linkerd-proxy` and no error, while (b) and (c) are accepted without error. | Source + Kubernetes docs | Admission probe records |
| W2 | With `Fail`, after expiry, (a), (b), (c) and (d) are all rejected, because the API server can't call the corresponding webhook. The exact error text returned is a finding, not a prediction. | Kubernetes docs | Admission probe records |
| W3 | Mesh traffic is unaffected in both runs. | Source (a separate trust chain) | Traffic probes |
| W4 | `linkerd check` goes fatal on each "… webhook has valid cert" row after expiry. | Source | Check transcripts |
| W5 | The API server's log records a webhook-call failure for each admission request that was rejected or ignored. The run records exactly how the TLS error is represented. | Kubernetes docs | k3s journal |
| W6 | For supplied credentials, the documented delete-and-upgrade procedure re-applies the supplied (expired) certificates rather than generating new ones. | Inference (the values are stored and re-rendered) | Recovery steps 3–4 |

## 4. Scenario O — identity-service outage

Uses the `long` profile. This is the cleanest causal test in the slice: the credentials stay exactly the same, and only the identity service's availability changes.

- **Invariant:** during O, the issuer Secret's contents, the trust anchor's contents, and the identity configuration stay byte-for-byte unchanged across fault and recovery. The single-state credential plan (§ 1.3) enforces the first two. The identity Deployment's pod template hash is recorded at every tick for the third.
- **Fault (`scenario_fault`):** `kubectl -n linkerd scale deploy/linkerd-identity --replicas=0` at T_mark.
- **Outage:** lasts `OUTAGE_S=900`, longer than a 5-minute leaf plus the 20 s skew. `probe-new` and `restart-target` are applied and rolled during the outage.
- **Recovery:** scale identity back to 1. The run records the replica change and the new identity pod's UID. Then `RECOVER_WINDOW_S` with no restarts, then R's restart stages and matrix.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| O1 | Proxies keep working until their current leaf expires (at most leaf lifetime + skew after the outage starts). Then new connections fail. | Source | Leaf metrics, probe logs |
| O2 | After identity returns, proxies whose leaf expired during the outage re-certify on their own, with no restart. | **Open.** This is the question slice 1 left, in a setting without an issuer change. | Leaf metrics, workload proxy logs, gate records |
| O3 | Pods created during the outage never become Ready until identity returns. | Source | Pod snapshots |

## 5. Scenario K — `linkerd check` thresholds

This scenario has no expiry and no timeline. Its purpose is to test tightly around the boundary.

**The boundary.** According to source, the warning fires when an issuer or anchor expires within 60 days of the moment the check runs. That's 1440h in UTC. Since the check measures remaining time when it runs, "exactly 60 days" isn't a point we can hit, so K brackets the boundary instead:

1. Reset with the `check-threshold` profile, using an issuer valid for 1440h − 10m.
2. Run `linkerd check` and `linkerd check --proxy` straight away, and record the seconds between the certificate's creation and the check.
3. Apply an issuer valid for 1440h + 10m with the issuer-only `linkerd upgrade`, and repeat the checks and the timing.

The 15-minute case already recorded in R completes the comparison.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| K1 | The 1440h − 10m issuer gets the same `‼ issuer cert is valid for at least 60 days` headline as the 15-minute one. The 1440h + 10m issuer gets `√`. So the threshold lies within 20 minutes of 60 days. | Source | Check transcripts and the recorded timings |

**Validity:** versions, certs, both check transcripts, and both timings captured; the credential plan `I(60d−10m) → I(60d+10m)` walked; clean tree. No control is needed, because no probe outcome is judged.

## 6. Scenario A — trust-anchor expiry

Uses the `anchor-short` profile: a 20-minute anchor, and a 120-minute issuer that outlives it. T_mark is the anchor's `notAfter`, and the expiry itself is the fault. The post-expiry actions are the defaults.

**Timing is measured per proxy.** Proxies keep renewing their leaves right up to T_mark, so each proxy's last pre-expiry leaf expires at a different moment. Leaves are capped at the issuer's expiry, not the anchor's, so A should keep those expiries staggered: the opposite of R, where capping collapsed every leaf onto one instant.

The run therefore records, for each proxy:

- the last successful leaf issuance before T_mark
- that leaf's `notAfter`
- the first new-connection failure on each client→server pair

Survival is measured against each proxy's own final leaf, not simply against T_mark.

**Recovery, Linkerd's documented root-and-issuer replacement:**

1. Create a new anchor and issuer.
2. Apply them with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… --identity-trust-anchors-file=… --force | kubectl apply -f -`.
3. Once the control plane is stable, run `kubectl rollout restart` on the meshed workloads.
4. Verify with `linkerd check`.

Each step is recorded, including whether control-plane pods restart. The credential plan is `A/I1 → B/I2`.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| A1 | Identity refuses every CSR from T_mark on. | Inference (source notes § 4) | Identity log, events |
| A2 | Each existing proxy pair keeps working until its own final pre-expiry leaf expires. Failures are staggered across proxies, not simultaneous. | Source (proxies ignore anchor dates; capping uses the issuer) | Per-proxy leaf metrics, probe logs |
| A3 | New connections fail once the relevant leaves expire. New pods never become Ready. | Inference | Probe logs, pod snapshots |
| A4 | `linkerd check` goes fatal on "trust anchors are within their validity period". | Source | Check transcripts |
| A5 | Recovery needs the control plane restarted as well as the workloads, because identity reads the anchors only at startup. | Source (notes § 3) | Pod snapshots, identity log |

## 7. Scenario S — trust-anchor rotation

Uses the `long` profile. Two runs, both starting from a valid anchor, which is what separates S from A.

**S-staged** follows the 11 steps of Linkerd's [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/) exactly:

1. Create a new anchor.
2. Bundle it with the old one (`step certificate bundle`).
3. `linkerd upgrade --identity-trust-anchors-file=bundle.crt`.
4. Restart the meshed workloads.
5. Run `linkerd check --proxy`.
6. Create a new issuer signed by the new anchor.
7. Apply the new issuer (issuer-only upgrade).
8. Restart the meshed workloads.
9. Run `linkerd check --proxy`.
10. `linkerd upgrade --identity-trust-anchors-file=ca-new.crt`.
11. Restart the meshed workloads, and run `linkerd check --proxy`.

A snapshot tick is taken after each step. Every restart step runs `rollout restart` on **all** lab Deployments, exactly as the guide says. Holding any workload back would leave it trusting only the old anchor when step 7 introduces certificates chained to the new one, and would cause the very failure the procedure exists to avoid. The credential plan is `A/I1 → A+B/I1 → A+B/I2 → B/I2`.

**S-hard** replaces the anchor and issuer in one step with `--force` and no bundle. Then:

1. Restart nothing for `RECOVER_WINDOW_S`.
2. Restart client A only.
3. Restart `server`.
4. Restart everything else.

The credential plan is `A/I1 → B/I2`. Each pod's trust-bundle hash is recorded on every tick, so the mixed-anchor states below are shown directly, not inferred from the restart history:

| Stage | Pair A: client / server trust | Pair B: client / server trust | Predicted |
| --- | --- | --- | --- |
| before the swap | old / old | old / old | works |
| 1. swap, no restarts | old / old | old / old | **fails once current leaves expire** (see S4) |
| 2. client A restarted | **new / old** | old / old | pair A fails (mixed trust) |
| 3. `server` restarted | new / new | **old / new** | pair A works; pair B fails (mixed trust) |
| 4. all restarted | new / new | new / new | works |

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| S1 | In S-staged, no new-connection failure is attributable to TLS identity or trust-anchor incompatibility at any step. Attribution uses proxy logs: a failure counts only if it carries a certificate or trust error. | Linkerd docs + source | Proxy logs, probe logs across all ticks |
| S1-obs | *(Observation, not a hypothesis.)* Every application-visible failure during S-staged is recorded, with its timing relative to pod terminations. This tests the documented "without downtime" claim operationally. | Linkerd docs | Probe logs, pod snapshots |
| S2 | In S-staged, between steps 3 and 4, `linkerd check --proxy` warns "Some pods do not have the current trust bundle and must be restarted". | Linkerd docs | Check transcripts |
| S3 | In S-hard, a new connection between endpoints holding different anchors fails: pair A at stage 2, and pair B at stage 3. | Source + slice-1 findings | Probe logs, gate records, per-pod trust hashes |
| S4 | In S-hard stage 1, proxies that haven't been restarted can't take a renewed certificate chained to the new anchor. They keep their current leaf and fail as it expires. | Inference (source notes § 4: a proxy validates its own new certificate against the anchors it holds) | Leaf metrics, proxy logs |

## 8. Scenario V — tap/viz (optional)

Confirm with the user before starting.

- Install Viz with `--set-file tap.crtPEM=…,tap.keyPEM=…,tap.caBundle=…`, using a 15-minute certificate. `linkerd viz install --set-file` is confirmed available, and the VM has about 5 GB free.
- After expiry, record `linkerd viz tap` output, the `v1alpha1.tap.linkerd.io` APIService status, and `linkerd viz check`.

| # | Hypothesis | Basis |
| --- | --- | --- |
| V1 | The tap APIService goes `Available=False`, `linkerd viz tap` fails, and `linkerd viz check` goes fatal on "tap API server has valid cert". | Inference (source notes § 6) |

## 9. Out of scope

- Externally managed webhook credentials (`externalSecret=true`, with cert-manager owning the Secrets). Testing them needs cert-manager in the lab.
- Reproducing linkerd2 #13196 (tap after a request-header CA rotation): invasive, and it reproduces a historical report.
- Default 24-hour workload certificates: that needs runs lasting more than a day.
- Clock skew: it needs a clock change, which the lab's rules forbid.

## 10. Implementation discovery (before the evidence runs)

These are settled in throwaway discovery runs (see Decisions), never in evidence runs:

- which policy and ServiceProfile resources the healthy validators reject (W's baseline depends on them)
- whether `linkerd install` accepts lab-supplied webhook certificates
- that `probe-tcp-new-b` meets the probe line contract

Already resolved:

- **Metric names:** found in slice 1's discovery data (§ 1.4).
- **Webhook replacement procedure:** from Linkerd's guide (§ 3).

What a plain `linkerd upgrade` does with supplied credentials is **not** a discovery item: W measures it on purpose (§ 3, W6).

## 11. The findings, once the runs are written up

- Every triage row these scenarios settle moves into the "reproduced" table, or is corrected.
- A new side-by-side comparison of R, O and A covers: the fault, whether the signer stayed valid, whether identity was reachable, how failure spread (simultaneous in R; staggered in A; bounded by each leaf's remaining life in O), what recovery took, and what `linkerd check` showed.
- The rotation guidance in "Best practices" is rewritten from S's evidence.

## 12. Review dispositions

Third-party review of the previous revision: [2026-09-11-cert-hygiene-lab-slice-2-design-review.md](../reviews/2026-09-11-cert-hygiene-lab-slice-2-design-review.md).

| # | Review item | Disposition |
| --- | --- | --- |
| 1 | W: distinguish webhook-credential models; make recovery a deliberate experiment | **Accepted** (§ 1.1, § 3, W6). Moved out of the open questions. The externally managed model is **out of scope**, because it needs cert-manager (§ 9). |
| 2 | W2 and W5 shouldn't predict exact error text | **Accepted** (§ 3). |
| 3 | Unique admission objects per tick; evidence layout; cleanup | **Accepted** (§ 3). |
| 4 | R3 needs directional interpretation (client-only / server-only / both) | **Accepted, extended.** The recovery stages are cumulative, so one client→server pair can never show the "server fresh, client stale" case. Adding a second client, `probe-tcp-new-b` (§ 1.5), fills all four cells in one run. The matrix is in § 2, and O and S-hard use it too. |
| 5 | O: state the credential invariant; record the identity replica change and pod UID | **Accepted** (§ 4, § 1.4). |
| 6 | K should test the boundary, not just either side of it | **Accepted, reworked.** "Exactly 60 days" isn't a testable point, because the check measures remaining time when it runs. K brackets 1440h ± 10m and records the time between creating each certificate and checking it (§ 5). |
| 7 | A: measure survival per proxy, not from T_mark | **Accepted** (§ 6, A2). Also framed as the opposite of R's capping. |
| 8 | Say why A and S aren't redundant | **Accepted** (introduction, § 7). |
| 9 | S1 is too absolute | **Accepted.** Split into S1, a trust/TLS invariant attributed through proxy logs, and S1-obs, which records every application-visible failure (§ 7). |
| 10 | S-hard must actually create the mixed-anchor state, with per-endpoint trust recorded | **Accepted, extended.** Stages and the matrix are in § 7, with per-pod trust hashes on every tick. The "swap, no restarts" row now carries a concrete prediction, not "may still work": source reading implies unrestarted proxies can't take renewals chained to the new anchor (S4, labelled an inference). The second client lets stage 3 show "old client / new server" too. |
| 11 | Generalise "planned anchor sequence" into planned credential transitions | **Accepted** (§ 1.3). |
| 12 | Separate discovery runs from evidence runs | **Accepted** (Decisions, § 10). |
| — | Compare R, O and A side by side in the findings | **Accepted** (introduction, § 11). |
