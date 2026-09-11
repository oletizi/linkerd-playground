# Cert-Hygiene Lab, Slice 2 — Design

**Status:** Revised after two reviews: the [design review](../reviews/2026-09-11-cert-hygiene-lab-slice-2-design-review.md), and the [combined implementation review](../reviews/2026-09-11-cert-hygiene-lab-combined-implementation-review.md) with its companion [as-built evidence review](../../articles/cert-hygiene/notes/lab-evidence-review-2026-09-11.md). Dispositions are in § 12; acceptance conditions in § 13. Awaiting approval.

**Builds on:** [slice 1 design](2026-09-10-cert-hygiene-demo-lab-design.md). Its substrate, versions, evidence rules, and validity model all carry over unchanged unless this document says otherwise. This is an internal design document; it uses the lab's shorthand, which the reader-facing article pages avoid.

**Why:** [findings.md](../../articles/cert-hygiene/findings.md) splits its triage table into "reproduced in the lab" and "expected from Linkerd's code, not yet tested". This slice tests the second table and answers the open questions the first issuer run left.

**Approved order:**
1. **R** — issuer-expiry re-run, done twice
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
| Negative control | Still required at the same harness tree for every timed scenario. The control proves that the harness, probes and k3s cause no failures of their own. It now also runs the restart choreography (§ 1.7), so ordinary rollout disruption is measured with nothing expired. |
| **Discovery versus evidence runs** | Implementation details that need the lab are settled first, in throwaway `runs/_discovery/<stamp>/` runs: which resources the validators reject, whether `linkerd install` accepts supplied webhook certificates, the restart gates, and the second client. Discovery runs never count as evidence. Then: (1) commit the harness; (2) confirm a clean tree; (3) run the control; (4) run R twice, then W, O, K, A and S, against that same tree; (5) make no harness changes between evidence runs. A fix found mid-way means: commit, re-run the control, and re-run only the affected scenarios. |
| Hypotheses | Stated per scenario below. Scripts record evidence and judge validity only; hypotheses are judged in per-scenario write-ups under `docs/articles/cert-hygiene/notes/`, as in slice 1. A scenario is called reproduced only when it meets its acceptance conditions (§ 13). |
| Reader-facing docs | A row moves from the "not yet tested" table to "reproduced" in `findings.md`, or is corrected, only after its write-up links exact run artifacts to the claim. The README status and the `sources.md` "our lab" entry are updated in the same commit. The guardrails in § 14 apply throughout. |

## 1. Harness generalisation

### 1.1 Credential profiles and webhook-credential models

`lab/reset.sh <short|long> <name>` becomes `lab/reset.sh <profile> <name>`. Each profile is a file, `lab/profiles/<profile>.env`, holding:

- `ANCHOR_LIFETIME`, `ISSUER_LIFETIME`, `LEAF_LIFETIME`
- `WEBHOOK_CERT_LIFETIMES`: per-component lifetimes, e.g. `proxyInjector=15m policyValidator=25m profileValidator=35m`. Empty means Linkerd generates its own webhook certificates, as today.
- `EXTRA_INSTALL_FLAGS`, e.g. `--set webhookFailurePolicy=Fail`

Linkerd supports three ways of managing webhook credentials, and the lab uses two of them:

- **Linkerd-managed** (the default): Linkerd generates each webhook's serving certificate, valid for 365 days. Linkerd's rotating-webhooks guide (delete the Secrets, run `linkerd upgrade`) is written for this model. Every profile without `WEBHOOK_CERT_LIFETIMES` uses it.
- **Externally managed:** an external system such as cert-manager owns the Secrets, and Linkerd is configured with `externalSecret=true` plus the CA bundle. **Not tested in this slice** (§ 9).
- **Lab-supplied static credentials:** the `webhook-short*` profiles, which exist to force a minutes-long expiry. When `WEBHOOK_CERT_LIFETIMES` is set, `reset.sh`:
  1. Creates a lab webhook CA inside the VM.
  2. Signs one serving certificate per webhook, each with its own lifetime and the service's DNS names as SANs: `linkerd-proxy-injector.linkerd.svc`, `linkerd-policy-validator.linkerd.svc` and `linkerd-sp-validator.linkerd.svc`.
  3. Passes each to Linkerd's renderer through `--set-file <component>.crtPEM=…,<component>.keyPEM=…,<component>.caBundle=…`. The components are `proxyInjector`, `policyValidator` and `profileValidator`. `caBundle` must be set, or the chart pairs the certificate with an unrelated CA (source notes § 5). `linkerd install --set-file` is confirmed available.

  This isn't how operators normally run Linkerd. That's why W's recovery observes both the documented procedure for Linkerd-managed credentials and the recovery appropriate to supplied ones (§ 3).

| Profile | Anchor | Issuer | Leaf | Webhook certs | Extra | Used by |
| --- | --- | --- | --- | --- | --- | --- |
| `long` | 87600h | 8760h | 5m | Linkerd-managed | — | control, O, S |
| `issuer-short` | 720h | 15m | 5m | Linkerd-managed | — | R |
| `webhook-short` | 87600h | 8760h | 5m | lab-supplied: injector 15m, policy 25m, ServiceProfile 35m | — | W (Ignore) |
| `webhook-short-fail` | 87600h | 8760h | 5m | as above | `--set webhookFailurePolicy=Fail` | W (Fail) |
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
  - the issuer certificate's DER SHA-256 fingerprint, serial and `notAfter`
  - each webhook serving certificate's DER SHA-256 fingerprint, serial, `notAfter` and SANs

  Fingerprints make the planned-transition check robust against ambiguous reissues, and the SANs make `linkerd check` name-validation findings auditable. Each pod's trust-bundle hash, which `trust/<tick>.txt` already records, gives each endpoint's trust state.
- **What each scenario declares:** its planned credential sequence, as an ordered list of named states. Examples:
  - R: `I1 → I2`
  - W: `W1 → W2`
  - O: one state
  - K: `I(60d−10m) → I(60d+10m)`
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
| Webhook baseline proved each admission probe exercises its webhook (§ 3) | W |
| Both K measurements fall on opposite sides of 60 days at the moment each check ran (§ 5) | K |
| S-hard stage 1 reached its per-endpoint condition before its timeout (§ 7) | S-hard |
| A valid control at the same harness tree | every timed scenario (all except K) |

A restart-stage gate that times out does **not** make a run invalid. The stage's matrix cell is recorded as "unclassified", with the gate's reason, and that is reported as a finding (§ 1.6).

### 1.4 Collector additions

- **Webhook state:** each Linkerd webhook configuration's `failurePolicy` and `caBundle` SHA-256, plus each webhook serving Secret's certificate identity (DER SHA-256, serial, `notAfter`, SANs), in `webhooks/<tick>.txt`. The Secrets are `linkerd-proxy-injector-k8s-tls`, `linkerd-policy-validator-k8s-tls` and `linkerd-sp-validator-k8s-tls`, with the certificate under the `tls.crt` key. Only that field is read, never the key field.
- **Credential state:** `credentials/<tick>.txt` (§ 1.3).
- **Connection metrics:** proxy series matching `^(tcp_open_total|tcp_close_total|tcp_open_connections|outbound_tcp_route_open_total|outbound_tcp_route_close_total)`, alongside the identity series. All five names are present in slice 1's discovery data (`demos/cert-hygiene/runs/_discovery/20260911T004528Z`).
- **Control-plane pod identity:** each tick also records the `linkerd` namespace's pods with their UIDs and start times, plus each control-plane Deployment's generation. This shows, for example, that O's recovery ran in a new identity process while the credentials stayed the same.
- **Gate records:** every restart-stage gate writes its checks and samples to `gates/<stage>.txt` (§ 1.6).
- **Pod listing per log snapshot:** `logs/<label>/pods.txt`, closing the parked "vacuous proxy-log rule" item.
- **APIService status**, for V only.
- **The k3s journal** is still captured for every run, as supplementary evidence. It is never a validity condition, and a missing log line is a result, not a falsification.
- **Write-up instructions:** the evidence-reading commands for write-ups move to the per-pod probe layout (`probes/<label>/<pod>.log`), closing the parked plan-Task-10 item.

### 1.5 A second forced-new-connection client

Slice 1 has one opaque-TCP client that opens a new connection per attempt (`probe-tcp-new` → `server`). Recovery stages are cumulative, so with a single client→server pair the "server fresh, client stale" case can never be observed: by the time `server` is restarted, the client already has been.

Slice 2 adds a second, identical client, `probe-tcp-new-b` → `server`. Restarting client A, then `server`, then everything fills all four combinations of client state and server state in one run (R, O, S-hard). `probe-tcp-new-b` is included in the control and every scenario, like the other probes.

### 1.6 Restart-stage gates

A restart of a one-replica workload can cause an ordinary availability failure that has nothing to do with TLS. So no probe sample taken during a restart counts toward a matrix cell. After each restart stage (in R, O, A, S and the control), the gate checks every workload restarted in that stage:

1. **Ready:** the new pod is Ready, and the old pod is gone.
2. **Serving:** the new pod is listed as a ready endpoint in its Service's EndpointSlice, where the workload has a Service.
3. **Trust state:** the pod carries the trust-bundle hash the scenario's credential plan expects at this stage.
4. **Certificate state:** its proxy has obtained a leaf since the restart (refresh timestamp after the restart, expiry in the future). If the scenario predicts that it can't obtain one, the gate records that instead, and the cell is classified from that recorded state.
5. **Non-TLS readiness:** the pod's application containers are Ready. This is a readiness check that doesn't depend on mesh TLS.

Once the gate passes, the stage takes repeated fresh-connection samples on every client→server pair (default: 10 attempts per pair over 20 seconds), and those samples classify the cell. If the gate doesn't pass within `GATE_TIMEOUT_S`, the cell is recorded as unclassified, with the unmet condition.

### 1.7 Restart-choreography control

The control (`00-baseline-control`) runs the same restart stages as R's recovery, with the same gates and samples, but with long-lived credentials: restart client A, then `server`, then everything else. With nothing expired, every gated sample should succeed.

Any failure seen *during* a restart in the control shows how much disruption comes from rollouts alone. Scenario write-ups use that baseline to separate TLS-attributable failures from ordinary restart disruption.

## 2. Scenario R — issuer expiry, re-run (twice)

This is slice 1's scenario #5, with the fixed harness (workload proxy logs, per-pod probe history, gate records). It runs twice at the same harness tree: a second clean run is worth more than more prose about one run. Changes:

- **Longer post-expiry window:** `POST_EXPIRY_WINDOW_S=1800` instead of 600, to see how long open connections and HTTP keep working. The stream pod is not restarted until stage 3.
- **Connection metrics on every tick** (§ 1.4).
- **Recovery stages that map endpoint state,** each followed by its gate and samples (§ 1.6). After the issuer is replaced:
  1. Wait `RECOVER_WINDOW_S` with no restarts. Sample at the end of the window.
  2. Restart client A (`probe-tcp-new`) only.
  3. Restart `server`.
  4. Restart every remaining lab Deployment.

  The stages produce this matrix of certificate state ("fresh" means holding a certificate from the replacement issuer):

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
| R3 | A new proxy-to-proxy mTLS connection can't succeed while either endpoint still holds a certificate that is invalid after recovery. The gated samples in the matrix show which endpoint's state is necessary: only the fresh/fresh cells succeed. | Inference (mTLS validates both peers) | Gate records and samples per stage |
| R4 | The established stream survives the whole 30-minute window. Any claim names the protocol (opaque TCP) and the measured duration. | Source-derived | Stream probe log |

## 3. Scenario W — webhook certificates

Two runs: `webhook-short` (default `Ignore`) and `webhook-short-fail` (`Fail`). Both use lab-supplied static webhook credentials (§ 1.1). Anchor and issuer are long-lived, and the mesh traffic probes keep running throughout.

**One webhook expires at a time.** The three serving certificates expire 10 minutes apart: proxy-injector first (T1), then policy-validator (T2), then sp-validator (T3). T_mark is T1, and the run marks each expiry as its own phase.

Each admission probe reaches exactly one webhook, by the webhook configurations' rules: pods go to the proxy-injector, `policy.linkerd.io` resources to the policy-validator, ServiceProfiles to the sp-validator. So each phase shows exactly one newly expired webhook, with the other two recorded in a known state.

**Admission probes.** These run at baseline, before T1, on every tick after T1, and after recovery. Every attempt uses a fresh object with a unique name, so the API server must call admission each time:

- **(a) Pod:** create `inject-probe-<tick>` in the injected `lab` namespace, and record whether it has a `linkerd-proxy` container. Reaches the proxy-injector.
- **(b) Invalid policy:** apply `policy-invalid-<tick>`, a policy resource that the healthy policy-validator rejects.
- **(c) Invalid ServiceProfile:** apply `serviceprofile-invalid-<tick>`, which the healthy sp-validator rejects.
- **(d) Valid resources:** apply valid versions of (b) and (c).

A discovery run picks the invalid resources for (b) and (c). The healthy baseline proves that each probe exercises its webhook: (a) is injected, while (b) and (c) are rejected with the validator's own message. If not, the run is invalid.

For each attempt, the run writes `admission/<phase>/<object>.request.yaml`, `<object>.response.txt` (the exact API response), and `<object>.observed.yaml` (the resulting object, if any). `<phase>` is `baseline`, `pre-expiry`, `post-NNN` or `recovered`. Every object that gets created is deleted once it has been observed, so the namespace doesn't fill up.

For each expiry phase the run also records:

- the webhook configuration and its `failurePolicy`
- the `caBundle` hash
- the serving certificate's identity and expiry
- the matching `linkerd check` transcript

**Recovery, observed as it branches.** Recovery starts after T3 plus the post-expiry window:

1. Delete the three `…-k8s-tls` Secrets (Linkerd's rotating-webhooks guide).
2. Run a plain `linkerd upgrade | kubectl apply -f -`.
3. Record which of these branches occurred. They are declared in advance, and none of them is predicted:
   - **(i)** plain upgrade produces freshly generated credentials, with matching webhook CA bundles;
   - **(ii)** plain upgrade re-renders the supplied, expired credentials;
   - **(iii)** plain upgrade leaves the serving path unhealthy in some other way.
4. For branches (ii) and (iii), pass freshly generated credentials explicitly with `--set-file`, and record that too.

For every branch, the run captures:

- the complete rendered manifest
- each Secret certificate's DER fingerprint, serial and `notAfter`
- each webhook's `caBundle` hash
- the relevant Deployments' generations and pod UIDs
- an admission probe taken after the change has propagated

An upgrade command's exit status is never counted as recovery by itself.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| W1 | With `Ignore`, after each webhook's expiry, its probe gets through without error: (a) yields a pod with no `linkerd-proxy`, while (b) and (c) are accepted. | Source + Kubernetes docs | Admission probe records, per phase |
| W2 | With `Fail`, after each webhook's expiry, its probes (including the valid (d) for the validators) are rejected, because the API server can't call that webhook. The exact error text returned is a finding, not a prediction. | Kubernetes docs | Admission probe records, per phase |
| W3 | Mesh traffic is unaffected in both runs. | Source (a separate trust chain) | Traffic probes |
| W4 | `linkerd check` goes fatal on each "… webhook has valid cert" row after that webhook's expiry. | Source | Check transcripts, per phase |
| W6 | *(Observation, not a hypothesis.)* Which recovery branch (i), (ii) or (iii) plain `linkerd upgrade` produces for supplied credentials. Our source notes say every render regenerates webhook certificates, but supplied values may take precedence. | Source notes § 5 (inconclusive for supplied values) | Recovery artifacts |

Supplementary: whether the k3s journal records the failed webhook calls, and how it represents the TLS error. This is recorded, never required (§ 1.4).

## 4. Scenario O — identity-service outage

Uses the `long` profile. This is the cleanest causal test in the slice: the credentials stay exactly the same, and only the identity service's availability changes.

- **Invariant:** during O, the issuer Secret's contents, the trust anchor's contents, and the identity configuration stay byte-for-byte unchanged across fault and recovery. The single-state credential plan (§ 1.3) enforces the first two. The identity Deployment's pod template hash is recorded at every tick for the third.
- **Fault (`scenario_fault`):** `kubectl -n linkerd scale deploy/linkerd-identity --replicas=0` at T_mark.
- **Outage:** lasts `OUTAGE_S=900`, longer than a 5-minute leaf plus the 20 s skew. `probe-new` and `restart-target` are applied and rolled during the outage.
- **Recovery:** scale identity back to 1. The run records the replica change and the new identity pod's UID. Then comes a `RECOVER_WINDOW_S` with no restarts, whose samples are evaluated first. Only then come R's gated restart stages and matrix.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| O1 | Proxies keep working until their current leaf expires (at most leaf lifetime + skew after the outage starts). Then new connections fail. | Source | Leaf metrics, probe logs |
| O2 | After identity returns, proxies whose leaf expired during the outage re-certify on their own, with no restart. | **Open.** This is the question slice 1 left, in a setting without an issuer change. | Leaf metrics, workload proxy logs, the no-restart window's samples |
| O3 | Pods created during the outage never become Ready until identity returns. | Source | Pod snapshots |

## 5. Scenario K — `linkerd check` thresholds

This scenario has no expiry and no timeline. Its purpose is to test tightly around the boundary.

**The boundary.** According to source, the warning fires when an issuer or anchor expires within 60 days of the moment the check runs. That's 1440h in UTC. Since the check measures remaining time when it runs, "exactly 60 days" isn't a point we can hit, so K brackets the boundary instead:

1. Reset with the `check-threshold` profile, using an issuer valid for 1440h − 10m.
2. Run `linkerd check` and `linkerd check --proxy` straight away. Record each check's start time and compute the remaining validity from the certificate's `notAfter`.
3. Apply an issuer valid for 1440h + 10m with the issuer-only `linkerd upgrade`, and repeat the checks and the calculation.

The 15-minute case already recorded in R completes the comparison.

**Validity:** the +10m measurement counts only if the certificate still had more than 60 days left when its check ran; if not, that step is repeated. Likewise, the −10m measurement needs less than 60 days left. Versions, certs, both check transcripts and both calculations must be captured, the credential plan walked, and the tree clean. No control is needed, because no probe outcome is judged.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| K1 | With less than 60 days remaining when the check runs, the issuer gets the same `‼ issuer cert is valid for at least 60 days` headline as the 15-minute one. With more than 60 days remaining, it gets `√`. The threshold therefore lies between the two recorded remaining-validity values. | Source | Check transcripts and the recorded calculations |

## 6. Scenario A — trust-anchor expiry

Uses the `anchor-short` profile: a 20-minute anchor, and a 120-minute issuer that outlives it. T_mark is the anchor's `notAfter`, and the expiry itself is the fault. The post-expiry actions are the defaults.

**Timing is measured per proxy.** Proxies keep renewing their leaves right up to T_mark, so each proxy's last pre-expiry leaf expires at a different moment. Leaves are capped at the issuer's expiry, not the anchor's, so A should keep those expiries staggered: the opposite of R, where capping collapsed every leaf onto one instant.

The run therefore records, for each proxy:

- the last successful leaf issuance before T_mark
- that leaf's `notAfter`
- the first new-connection failure on each client→server pair

Survival is measured against each proxy's own final leaf, not simply against T_mark.

**Recovery, Linkerd's documented root-and-issuer replacement, observed in named stages:**

1. **Apply.** Create a new anchor and issuer, then apply them with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… --identity-trust-anchors-file=… --force | kubectl apply -f -`. Record which control-plane components the upgrade itself restarted (pod UIDs before and after).
2. **No manual restarts** for `RECOVER_WINDOW_S`. Record control-plane pod UIDs, identity logs, events, and CSR results: is identity issuing leaves chained to the new anchor?
3. **Identity/control-plane restart, only if needed.** If identity isn't issuing valid leaves by the end of stage 2, explicitly restart the identity controller, then any other control-plane components still on the old roots. This is a named stage, recorded like the others.
4. **Workload restarts,** as the guide directs: `kubectl rollout restart` on the meshed workloads, with gates (§ 1.6).
5. **Verify** with `linkerd check`.

The credential plan is `A/I1 → B/I2`.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| A1 | Identity refuses every CSR from T_mark on. | Inference (source notes § 4) | Identity log, events |
| A2 | Each existing proxy pair keeps working until its own final pre-expiry leaf expires. Failures are staggered across proxies, not simultaneous. | Source (proxies ignore anchor dates; capping uses the issuer) | Per-proxy leaf metrics, probe logs |
| A3 | New connections fail once the relevant leaves expire. New pods never become Ready. | Inference | Probe logs, pod snapshots |
| A4 | `linkerd check` goes fatal on "trust anchors are within their validity period". | Source | Check transcripts |
| A5 | *(An inference to test, not an assumption.)* Recovery needs identity restarted, because identity reads the anchors only at startup. The test: does identity issue new-anchor leaves after stage 1 alone (unless the upgrade already restarted it), or only after stage 3? | Source (notes § 3) | Stage 2 and stage 3 records |

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

A snapshot tick is taken after each step, and a gate follows each restart step (§ 1.6). Every restart step runs `rollout restart` on **all** lab Deployments, exactly as the guide says. Holding any workload back would leave it trusting only the old anchor when step 7 introduces certificates chained to the new one, and would cause the very failure the procedure exists to avoid. The credential plan is `A/I1 → A+B/I1 → A+B/I2 → B/I2`.

**S-hard** replaces the anchor and issuer in one step with `--force` and no bundle. Then:

1. **No restarts,** until the per-endpoint condition below is met, or `S_HARD_STAGE1_TIMEOUT_S` passes. A timeout makes the run invalid. The condition: for each unrestarted endpoint, the run has recorded its last old leaf and that leaf's `notAfter`, its renewal attempt after the swap and the result, and its first failed forced-new connection after that leaf expired.
2. Restart client A only, then gate and sample.
3. Restart `server`, then gate and sample.
4. Restart everything else, then gate and sample.

The credential plan is `A/I1 → B/I2`. Each pod's trust-bundle hash is recorded on every tick, so the mixed-anchor states below are shown directly, not inferred from the restart history:

| Stage | Pair A: client / server trust | Pair B: client / server trust | Predicted |
| --- | --- | --- | --- |
| before the swap | old / old | old / old | works |
| 1. swap, no restarts | old / old | old / old | **fails once each endpoint's current leaf expires** (S4) |
| 2. client A restarted | **new / old** | old / old | pair A fails (mixed trust) |
| 3. `server` restarted | new / new | **old / new** | pair A works; pair B fails (mixed trust) |
| 4. all restarted | new / new | new / new | works |

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| S1 | In S-staged, no new-connection failure is attributable to TLS identity or trust-anchor incompatibility at any step. A failure counts only if proxy logs show a certificate or trust error. Samples taken before a gate passes don't count. | Linkerd docs + source | Proxy logs, gated samples across all steps |
| S1-obs | *(Observation, not a hypothesis.)* Every application-visible failure during S-staged is recorded, with its timing relative to pod terminations, and compared with the restart-choreography control. This tests the documented "without downtime" claim operationally. | Linkerd docs | Probe logs, pod snapshots, the control |
| S2 | In S-staged, between steps 3 and 4, `linkerd check --proxy` warns "Some pods do not have the current trust bundle and must be restarted". | Linkerd docs | Check transcripts |
| S3 | In S-hard, a new connection between endpoints holding different anchors fails: pair A at stage 2, and pair B at stage 3. | Source + slice-1 findings | Gated samples, per-pod trust hashes |
| S4 | In S-hard stage 1, proxies that haven't been restarted can't take a renewed certificate chained to the new anchor. They keep their current leaf and fail as it expires. | Inference (source notes § 4: a proxy validates its own new certificate against the anchors it holds) | The per-endpoint stage-1 records |

## 8. Scenario V — tap/viz (optional)

Confirm with the user before starting.

- Install Viz with `--set-file tap.crtPEM=…,tap.keyPEM=…,tap.caBundle=…`, using a 15-minute certificate. `linkerd viz install --set-file` is confirmed available, and the VM has about 5 GB free.
- After expiry, record `linkerd viz tap` output, the `v1alpha1.tap.linkerd.io` APIService status, the certificate state, and `linkerd viz check`.

| # | Hypothesis | Basis |
| --- | --- | --- |
| V1 | The tap APIService goes `Available=False`, `linkerd viz tap` fails, and `linkerd viz check` goes fatal on "tap API server has valid cert". | Inference (source notes § 6) |

## 9. Out of scope

- Externally managed webhook credentials (`externalSecret=true`, with cert-manager owning the Secrets). Testing them needs cert-manager in the lab.
- A deliberately long-lived HTTP/2 or gRPC application stream: the evidence review's protocol matrix. It needs a streaming server image in the lab. R's connection metrics already test whether HTTP reuses a pre-expiry connection. This can be added later if the article needs it.
- Reproducing linkerd2 #13196 (tap after a request-header CA rotation): invasive, and it reproduces a historical report.
- Default 24-hour workload certificates: that needs runs lasting more than a day.
- Clock skew: it needs a clock change, which the lab's rules forbid.

## 10. Implementation discovery (before the evidence runs)

These are settled in throwaway discovery runs (see Decisions), never in evidence runs:

- which policy and ServiceProfile resources the healthy validators reject (W's baseline depends on them)
- whether `linkerd install` accepts lab-supplied webhook certificates with per-component lifetimes
- that `probe-tcp-new-b` meets the probe line contract
- that the restart-stage gates (§ 1.6) pass for healthy restarts, and how long a healthy one-replica restart takes. `GATE_TIMEOUT_S` is set from that.

Already resolved:

- **Metric names:** found in slice 1's discovery data (§ 1.4).
- **Webhook replacement procedure:** from Linkerd's guide (§ 3).

What a plain `linkerd upgrade` does with supplied credentials is **not** a discovery item: W observes it on purpose (§ 3, W6).

## 11. The findings, once the runs are written up

- Every triage row these scenarios settle moves into the "reproduced" table, or is corrected, only when it meets § 13's acceptance conditions.
- A new side-by-side comparison of R, O and A covers: the fault, whether the signer stayed valid, whether identity was reachable, how failure spread (simultaneous in R; staggered in A; bounded by each leaf's remaining life in O), what recovery took, and what `linkerd check` showed.
- The rotation guidance in "Best practices" is rewritten from S's evidence.

## 12. Review dispositions

### 12.1 Design review

Third-party review of an earlier revision: [2026-09-11-cert-hygiene-lab-slice-2-design-review.md](../reviews/2026-09-11-cert-hygiene-lab-slice-2-design-review.md).

| # | Review item | Disposition |
| --- | --- | --- |
| 1 | W: distinguish webhook-credential models; make recovery a deliberate experiment | **Accepted** (§ 1.1, § 3). Refined further by the combined review's C2. The externally managed model is **out of scope**, because it needs cert-manager (§ 9). |
| 2 | W2 and W5 shouldn't predict exact error text | **Accepted** (§ 3). W5 later became supplementary evidence (C3). |
| 3 | Unique admission objects per tick; evidence layout; cleanup | **Accepted** (§ 3). |
| 4 | R3 needs directional interpretation (client-only / server-only / both) | **Accepted, extended.** The recovery stages are cumulative, so one client→server pair can never show the "server fresh, client stale" case. Adding a second client, `probe-tcp-new-b` (§ 1.5), fills all four cells in one run. The matrix is in § 2, and O and S-hard use it too. |
| 5 | O: state the credential invariant; record the identity replica change and pod UID | **Accepted** (§ 4, § 1.4). |
| 6 | K should test the boundary, not just either side of it | **Accepted, reworked.** "Exactly 60 days" isn't a testable point, because the check measures remaining time when it runs. K brackets 1440h ± 10m (§ 5). |
| 7 | A: measure survival per proxy, not from T_mark | **Accepted** (§ 6, A2). |
| 8 | Say why A and S aren't redundant | **Accepted** (introduction, § 7). |
| 9 | S1 is too absolute | **Accepted.** Split into S1, a trust/TLS invariant attributed through proxy logs, and S1-obs (§ 7). |
| 10 | S-hard must actually create the mixed-anchor state, with per-endpoint trust recorded | **Accepted, extended.** Stages and the matrix are in § 7, with per-pod trust hashes on every tick. The "swap, no restarts" row carries a concrete prediction (S4, labelled an inference). |
| 11 | Generalise "planned anchor sequence" into planned credential transitions | **Accepted** (§ 1.3). |
| 12 | Separate discovery runs from evidence runs | **Accepted** (Decisions, § 10). |
| — | Compare R, O and A side by side in the findings | **Accepted** (introduction, § 11). |

### 12.2 Combined implementation review, and the as-built evidence review

Reviews: [combined implementation review](../reviews/2026-09-11-cert-hygiene-lab-combined-implementation-review.md) (C1–C7) and [as-built evidence review](../../articles/cert-hygiene/notes/lab-evidence-review-2026-09-11.md) (E-numbered).

| # | Review item | Disposition |
| --- | --- | --- |
| C1 | Isolate webhook expiry by webhook | **Accepted, with a cheaper method.** Attribution was already exact, because each admission probe reaches exactly one webhook by the configurations' rules. Still, each run now staggers the three expiries 10 minutes apart, so each webhook has its own phase, with healthy baselines and per-phase records (§ 1.1, § 3). No separate runs per webhook. |
| C2 | Treat supplied-webhook recovery as a branching observation, not a prediction | **Accepted** (§ 3): three declared branches, full artifacts, and a post-propagation admission probe. Exit status is never counted as recovery. W6 is now an observation. |
| C3 | The k3s journal must not be a W validity condition | **Accepted.** It never was a validity condition, but W5 was a hypothesis. Now it is supplementary evidence only (§ 1.4, § 3). |
| C4 | Gate every restart stage before judging TLS behaviour; add a restart-choreography control | **Accepted** (§ 1.6, § 1.7). A timed-out gate yields an unclassified cell, not an invalid run. |
| C5 | S-hard must wait for the actual leaf transition | **Accepted** (§ 7). Stage 1 ends on a per-endpoint condition; a timeout invalidates the run. |
| C6 | Make A's control-plane-restart test explicit | **Accepted** (§ 6): named stages 1–5, and A5 reframed as a tested inference. |
| C7 | K's remaining validity at check time; DER fingerprints and SANs | **Accepted** (§ 5, § 1.3, § 1.4). |
| C-acc | Scenario acceptance conditions | **Adopted** as § 13. |
| C-guard | Evidence and publishing guardrails | **Adopted** as § 14. |
| E-rec1 | Re-run issuer expiry with the corrected collector | Already R. |
| E-rec5 | Protocol matrix, including a long-lived HTTP/2 or gRPC stream | **Partly accepted.** R covers fresh opaque TCP, pre-existing opaque TCP, and fresh HTTP requests, plus connection metrics that test reuse. The long-lived HTTP/2/gRPC stream is **deferred** (§ 9). |
| E-rec6 | Repeat the core issuer scenario | **Accepted:** R runs twice. |
| E-narrow | Narrow the reader-facing claims (new connections, survival bound, restart direction, 60-day scope) | **Done** in `findings.md`, in the commit that adopts this revision. |

## 13. Acceptance conditions

A scenario is written up as **reproduced** only when all of these hold:

| Scenario | Don't call it reproduced until… |
| --- | --- |
| **R** | Workload `linkerd-proxy` logs, per-pod continuous probe history, and gated recovery stages exist, in both runs. Any established-connection claim names its protocol and measured duration. |
| **W** | Each webhook's expiry phase is recorded, with a healthy baseline proving its probe; exact responses, object states, checks and recovery-branch artifacts exist for both `Ignore` and `Fail`. |
| **O** | The credential and configuration invariant holds; the outage outlasts the leaf window; the no-restart recovery window is evaluated before any restart stage. |
| **K** | Both measured remaining-validity values, and both command transcripts, put the checks on opposite sides of the 60-day boundary. |
| **A** | Per-proxy final-leaf timing, identity CSR evidence, checks, and the named recovery stages (including whether an identity/control-plane restart was needed) exist. |
| **S** | Staged results separate TLS-attributable failures from rollout disruption (against the restart-choreography control). Hard rotation records the actual mixed-anchor endpoint states and the stage-1 old-leaf renewal and expiry behaviour. |
| **V** | The user has approved it, and APIService status, CLI output, certificate state and `linkerd viz check` are captured. |

## 14. Evidence and publishing guardrails

- Discovery artifacts are implementation records, never evidence runs.
- A scenario's failure is not evidence for its hypothesis until the run meets its validity rules. Invalid artifacts are preserved and explained, never silently overwritten by a re-run.
- A passing `linkerd check` after an issuer replacement doesn't prove that pre-existing workload certificates were renewed. Slice 1 demonstrated that distinction.
- Reader-facing rows move from "expected from code" to "reproduced" only after a write-up links exact run artifacts to the claim.
- Findings are phrased as "in our lab", naming the version and lifetimes, unless primary documentation independently establishes them. Source-derived statements stay labelled as such.
