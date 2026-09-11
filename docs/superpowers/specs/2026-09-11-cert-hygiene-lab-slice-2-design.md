# Cert-Hygiene Lab, Slice 2 — Design

**Status:** Draft for review.

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

## Decisions

| Question | Decision |
| --- | --- |
| Substrate, versions, lifetimes | Unchanged from slice 1: OrbStack VM, k3s, Linkerd `edge-26.9.1`, clocks never altered, keys never in the repo. |
| Negative control | Still required at the same harness tree for every timed scenario. The control proves that the harness, probes and k3s cause no failures of their own. |
| Build order | **Build everything, then run.** All harness changes and scenario scripts land first, then one control run, then every scenario against that same harness tree. A harness fix found during the runs means: commit, re-run the control, and re-run only the affected scenarios. |
| Hypotheses | Stated per scenario below. Scripts record evidence and judge validity only; hypotheses are judged in per-scenario write-ups under `docs/articles/cert-hygiene/notes/`, as in slice 1. |
| Reader-facing docs | A row moves from the "not yet tested" table to "reproduced" in `findings.md`, or is corrected, only after its write-up exists. The README status and the `sources.md` "our lab" entry are updated in the same commit. |

## 1. Harness generalisation

### 1.1 Credential profiles

`lab/reset.sh <short|long> <name>` becomes `lab/reset.sh <profile> <name>`. Each profile is a file, `lab/profiles/<profile>.env`, holding:

- `ANCHOR_LIFETIME`, `ISSUER_LIFETIME`, `LEAF_LIFETIME`
- `WEBHOOK_CERT_LIFETIME`: empty means Linkerd generates its own webhook certificates, as today
- `EXTRA_INSTALL_FLAGS`, e.g. `--set webhookFailurePolicy=Fail`

When `WEBHOOK_CERT_LIFETIME` is set, `reset.sh`:

1. Creates a lab webhook CA inside the VM.
2. Signs serving certificates for `linkerd-proxy-injector.linkerd.svc`, `linkerd-policy-validator.linkerd.svc` and `linkerd-sp-validator.linkerd.svc`.
3. Passes each through `--set-file <component>.crtPEM=…,<component>.keyPEM=…,<component>.caBundle=…`. The components are `proxyInjector`, `policyValidator` and `profileValidator`. `caBundle` must be set, or the chart pairs the certificate with an unrelated CA (source notes § 5).

`linkerd install --set-file` is confirmed available.

| Profile | Anchor | Issuer | Leaf | Webhook certs | Extra | Used by |
| --- | --- | --- | --- | --- | --- | --- |
| `long` | 87600h | 8760h | 5m | generated | — | control, O, S |
| `issuer-short` | 720h | 15m | 5m | generated | — | R |
| `webhook-short` | 87600h | 8760h | 5m | 15m | — | W (Ignore) |
| `webhook-short-fail` | 87600h | 8760h | 5m | 15m | `--set webhookFailurePolicy=Fail` | W (Fail) |
| `anchor-short` | 20m | 120m | 5m | generated | — | A |
| `check-59d` | 87600h | 1416h | 5m | generated | — | K |

`step` signs an issuer that outlives its anchor (confirmed in the lab VM), which A needs. The existing `short` and `long` modes become the `issuer-short` and `long` profiles, so the slice-1 scenarios keep working.

### 1.2 Scenario hooks

`run_scenario` keeps `scenario_mark_epoch` and `scenario_recover`, and gains three optional hooks:

- `scenario_fault`: an action at T_mark. The default is none, since for the expiry scenarios the expiry itself is the fault. O stops identity here.
- `scenario_post_actions`: runs at T_mark + 1m. The default is today's behaviour (apply `probe-new`, roll `restart-target`). W replaces it with its admission probes (§ 3).
- `scenario_tick_extra NAME`: extra per-tick capture. W uses it to repeat the admission probes on every tick.

### 1.3 Validity rules per scenario

Today `evaluate_validity` special-cases `00-baseline-control` and `05-issuer-expiry` by name. That becomes one rule table in `lib-evidence.sh`, keyed by scenario name and unit-tested like the rest:

| Rule | Applies to |
| --- | --- |
| Common rules (clean tree, complete artifacts, per-tick files, leaf-lifetime check, proxy logs) | every scenario |
| Trust anchor unchanged across baseline, pre-recover and verify | control, R, W, O, K |
| **Planned anchor sequence:** each recorded anchor change matches the scenario's declared sequence, and no other change occurs | A, S |
| Recovery apply succeeded (`recover/linkerd-upgrade.txt` ends `[exit 0]`) | R, A |
| Webhook baseline proved the admission probes work (§ 3) | W |
| A valid control at the same harness tree | every timed scenario (all except K) |

### 1.4 Collector additions

- **Webhook state:** each Linkerd webhook configuration's `failurePolicy` and `caBundle` SHA-256, plus each webhook serving Secret's certificate metadata (serial, `notAfter`), in `webhooks/<tick>.txt`. The Secrets are `linkerd-proxy-injector-k8s-tls`, `linkerd-policy-validator-k8s-tls` and `linkerd-sp-validator-k8s-tls`, with the certificate under the `tls.crt` key. Only that field is read, never the key field.
- **Connection metrics:** proxy series matching `^(tcp_open_total|tcp_close_total|tcp_open_connections|outbound_tcp_route_open_total|outbound_tcp_route_close_total)`, alongside the identity series. All five names are present in slice 1's discovery data (`demos/cert-hygiene/runs/_discovery/20260911T004528Z`).
- **Pod listing per log snapshot:** `logs/<label>/pods.txt`, closing the parked "vacuous proxy-log rule" item.
- **APIService status**, for V only.
- **Write-up instructions:** the evidence-reading commands for write-ups move to the per-pod probe layout (`probes/<label>/<pod>.log`), closing the parked plan-Task-10 item.

## 2. Scenario R — issuer expiry, re-run

This is slice 1's scenario #5, with the fixed harness (workload proxy logs, per-pod probe history, gate records) plus:

- **Longer post-expiry window:** `POST_EXPIRY_WINDOW_S=1800` instead of 600, to see how long open connections and HTTP keep working.
- **Connection metrics on every tick** (§ 1.4).
- **Recovery stages that separate necessity from sufficiency.** After the issuer is replaced:
  1. Wait `RECOVER_WINDOW_S` with no restarts.
  2. Restart the client probes only (`probe-http`, `probe-tcp-new`).
  3. Restart `server` only.
  4. Restart every remaining lab Deployment.

  The gate is recorded at every tick.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| R1 | `probe-http` keeps working after T_mark because it reuses a proxy-to-proxy connection opened before T_mark: its outbound `tcp_open_total` to `server` does not rise after T_mark. | Source-derived | Connection metrics |
| R2 | Pre-existing proxies fail to re-certify after the issuer is replaced because their TLS handshake to the identity service fails: their logs show handshake errors, not validation errors. | Inference (slice-1 notes) | Workload `linkerd-proxy` logs |
| R3 | For `probe-tcp-new` → `server`, restarting one side is not enough; both endpoints need a fresh certificate. | Inference (mTLS validates both peers) | Gate records at stages 2 and 3 |
| R4 | The established stream survives the whole 30-minute window. | Source-derived | Stream probe log |

## 3. Scenario W — webhook certificates

Two runs: `webhook-short` (default `Ignore`) and `webhook-short-fail` (`Fail`). Anchor and issuer are long-lived. The three serving certificates for proxy-injector, policy-validator and sp-validator expire at T_mark. The mesh traffic probes keep running throughout.

**Admission probes.** These run at baseline, then on every tick after T_mark, then at verify. Each records the exact API response.

- **(a) Pod:** create a pod in the injected `lab` namespace, and record whether it has a `linkerd-proxy` container.
- **(b) Invalid policy:** apply a policy resource that the healthy policy-validator rejects.
- **(c) Invalid ServiceProfile:** apply a ServiceProfile that the healthy sp-validator rejects.
- **(d) Valid resources:** apply valid versions of (b) and (c).

A discovery step picks the invalid resources for (b) and (c). The baseline must show (b) and (c) rejected, and (a) injected, or the run is invalid.

**Recovery.** Replace the webhook certificates, then repeat the admission probes. Linkerd's [rotating webhooks certificates](https://linkerd.io/2-edge/tasks/rotating_webhooks_certificates/) guide says to delete the three `…-k8s-tls` Secrets and run `linkerd upgrade | kubectl apply -f -`, which "will recreate the secrets without restarting Linkerd". Restarting the webhook pods is "usually not necessary".

**The catch:** this run supplied its certificates as Helm values, so a plain `linkerd upgrade` may re-render the same expired values instead of generating new ones. The recover phase therefore records what a plain `linkerd upgrade` does. If it re-applies the expired certificates, recovery passes fresh ones with `--set-file`, and the write-up reports that difference, which matters to operators who supply their own webhook certificates.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| W1 | With `Ignore`, after expiry (a) yields a pod with no `linkerd-proxy` and no error, while (b) and (c) are accepted without error. | Source + Kubernetes docs | Admission probe records |
| W2 | With `Fail`, after expiry, (a), (b), (c) and (d) are all rejected with an x509 error from the API server. | Kubernetes docs | Admission probe records |
| W3 | Mesh traffic is unaffected in both runs. | Source (a separate trust chain) | Traffic probes |
| W4 | `linkerd check` goes fatal on each "… webhook has valid cert" row after expiry. | Source | Check transcripts |
| W5 | The API server logs each failed webhook call with the TLS error, in both modes. | Kubernetes docs | k3s journal |

## 4. Scenario O — identity-service outage

Uses the `long` profile.

- **Fault (`scenario_fault`):** `kubectl -n linkerd scale deploy/linkerd-identity --replicas=0` at T_mark.
- **Outage:** lasts `OUTAGE_S=900`, longer than a 5-minute leaf plus the 20 s skew. `probe-new` and `restart-target` are applied and rolled during the outage.
- **Recovery:** scale identity back to 1. Then `RECOVER_WINDOW_S` with no restarts, then R's restart stages.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| O1 | Proxies keep working until their current leaf expires (at most leaf lifetime + skew after the outage starts). Then new connections fail. | Source | Leaf metrics, probe logs |
| O2 | After identity returns, proxies whose leaf expired during the outage re-certify on their own, with no restart. | **Open.** This is the question slice 1 left, in a setting without an issuer change. | Leaf metrics, workload proxy logs, gate records |
| O3 | Pods created during the outage never become Ready until identity returns. | Source | Pod snapshots |

## 5. Scenario K — `linkerd check` thresholds

This scenario has no expiry and no timeline.

1. Reset with `check-59d` (a 59-day issuer under a long anchor), and capture `linkerd check` and `linkerd check --proxy`.
2. Apply a 61-day issuer with the issuer-only `linkerd upgrade`, and capture both again.
3. Compare with the 15-minute case already recorded in R.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| K1 | The 59-day issuer gets the same `‼ issuer cert is valid for at least 60 days` headline as the 15-minute one. The 61-day issuer gets `√`. | Source | Check transcripts |

**Validity:** versions, certs and both check transcripts captured; clean tree. No control is needed, because no probe outcome is judged.

## 6. Scenario A — trust-anchor expiry

Uses the `anchor-short` profile: a 20-minute anchor, and a 120-minute issuer that outlives it. T_mark is the anchor's `notAfter`, and the expiry itself is the fault. The post-expiry actions are the defaults.

**Recovery, Linkerd's documented root-and-issuer replacement:**

1. Create a new anchor and issuer.
2. Apply them with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… --identity-trust-anchors-file=… --force | kubectl apply -f -`.
3. Once the control plane is stable, run `kubectl rollout restart` on the meshed workloads.
4. Verify with `linkerd check`.

Each step is recorded, including whether control-plane pods restart. After recovery, the planned-anchor-sequence rule (§ 1.3) replaces the trust invariant.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| A1 | Identity refuses every CSR from T_mark on. | Inference (source notes § 4) | Identity log, events |
| A2 | Existing traffic keeps working after T_mark until each proxy's current leaf expires. Leaves are not clamped to the anchor, only to the issuer. | Source (proxies ignore anchor dates; clamping uses the issuer) | Leaf metrics, probe logs |
| A3 | New connections fail once the leaves expire. New pods never become Ready. | Inference | Probe logs, pod snapshots |
| A4 | `linkerd check` goes fatal on "trust anchors are within their validity period". | Source | Check transcripts |
| A5 | Recovery needs the control plane restarted as well as the workloads, because identity reads the anchors only at startup. | Source (notes § 3) | Pod snapshots, identity log |

## 7. Scenario S — trust-anchor rotation

Uses the `long` profile. Two runs.

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

A snapshot tick is taken after each step. Every restart step runs `rollout restart` on **all** lab Deployments, exactly as the guide says. Holding any workload back would leave it trusting only the old anchor when step 7 introduces certificates chained to the new one, and would cause the very failure the procedure exists to avoid.

Rolling restarts still exercise connections between new and old pods while they overlap. The fail-closed stream probe is replaced at each restart by design, so S1 is judged on `probe-http` and `probe-tcp-new` only.

**S-hard:** replace anchor and issuer in one step with `--force`, with no bundle. Restart nothing for `RECOVER_WINDOW_S`, then restart the client probes only, then everything.

| # | Hypothesis | Basis | Falsified by |
| --- | --- | --- | --- |
| S1 | In S-staged, no new connection fails at any step. | Linkerd docs ("without downtime") | Probe logs across all ticks |
| S2 | In S-staged, between steps 3 and 4, `linkerd check --proxy` warns "Some pods do not have the current trust bundle and must be restarted". | Linkerd docs | Check transcripts |
| S3 | In S-hard, connections between pods holding different anchors fail until both sides are restarted. | Source + slice-1 findings | Probe logs, gate records |

## 8. Scenario V — tap/viz (optional)

Confirm with the user before starting.

- Install Viz with `--set-file tap.crtPEM=…,tap.keyPEM=…,tap.caBundle=…`, using a 15-minute certificate. `linkerd viz install --set-file` is confirmed available, and the VM has about 5 GB free.
- After expiry, record `linkerd viz tap` output, the `v1alpha1.tap.linkerd.io` APIService status, and `linkerd viz check`.

| # | Hypothesis | Basis |
| --- | --- | --- |
| V1 | The tap APIService goes `Available=False`, `linkerd viz tap` fails, and `linkerd viz check` goes fatal on "tap API server has valid cert". | Inference (source notes § 6) |

## 9. Out of scope

- Reproducing linkerd2 #13196 (tap after a request-header CA rotation): invasive, and it reproduces a historical report.
- Default 24-hour workload certificates: that needs runs lasting more than a day.
- Clock skew: it needs a clock change, which the lab's rules forbid.

## 10. Open questions, resolved during implementation

| Question | Resolved by |
| --- | --- |
| Which policy and ServiceProfile resources the healthy validators reject | A discovery step before W's baseline |
| The exact webhook-certificate replacement commands | **Resolved:** delete the `…-k8s-tls` Secrets and run `linkerd upgrade` (see § 3, including the catch for supplied certificates) |
| Exported names of the proxy connection metrics | **Resolved:** found in slice 1's discovery data (§ 1.4) |
| Whether `linkerd install` validates supplied webhook certificates | The first `webhook-short` reset |
| Whether a plain `linkerd upgrade` regenerates supplied webhook certificates or re-applies them | W's recover phase (§ 3) |
