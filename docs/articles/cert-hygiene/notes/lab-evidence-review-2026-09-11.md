# Lab evidence review — certificate hygiene article

## Review outcome

The work so far provides a strong, reproducible **issuer-expiry** case study for one specific environment: Linkerd `edge-26.9.1`, Kubernetes `v1.36.4+k3s1`, one k3s node, a 15-minute issuer, and five-minute workload certificates. It supports a carefully qualified article section about that scenario.

It does **not** yet support the article’s full certificate-hygiene story. The trust-anchor, webhook, Viz/tap, and identity-service-outage scenarios are still source-derived or planned. The issuer run also predates two evidence-collection improvements, so it does not meet the checklist requirement for workload-proxy logs or for a continuous recovery-period probe record.

The most important editorial rule is therefore: keep the issuer-expiry findings version- and scenario-qualified, and do not promote the untested webhook/root predictions into results.

## What was reviewed

- Article materials: [README](../README.md), [findings](../findings.md), [sources](../sources.md), [issuer-expiry evidence note](lab-evidence-issuer-expiry.md), [source notes](linkerd-source-notes.md), and [demo feasibility](demo-feasibility.md).
- Lab harness: [`demos/cert-hygiene/`](../../../../demos/cert-hygiene/), including scenario `05-issuer-expiry.sh`, evidence collectors, probes, and evidence-validity tests.
- Primary experimental run: `demos/cert-hygiene/runs/05-issuer-expiry/20260911T021157Z`.
- Baseline control: `demos/cert-hygiene/runs/00-baseline-control/20260911T014417Z`.

No scenario was rerun for this review, and no existing document or lab file was changed.

## Evidence quality

### Strong points

- The experiment uses a disposable, single-node lab and records exact Linkerd, Kubernetes, image, and lifetime configuration in `versions.txt`.
- The primary run and its matched control are recorded as `evidence_valid=yes`; the evidence note also records the same harness-tree hash and a clean repository state.
- The fault is isolated: the trust configuration is recorded as unchanged across baseline, pre-recovery, and post-recovery snapshots (`trust-invariant.txt`).
- The harness captures raw `linkerd check`/`linkerd check --proxy` output, certificate metadata, timeline markers, Kubernetes events, pod descriptions, identity metrics, and staged recovery actions.
- The article materials are commendably explicit about confidence: they distinguish lab observations, source-derived statements, inferences, and unanswered questions.
- The positive control matters: the long-lived baseline has no certificate-lifetime warning or probe failure under its stated criteria.

### Material limitations

- This is one issuer-expiry run, on one edge release and one topology. It is evidence of observed behavior in that environment, not a release-independent guarantee.
- The original run was made before the collector walked native-sidecar init containers. It therefore contains no workload `linkerd-proxy` logs. The later harness addresses this, but has not yet produced a replacement run.
- The original probe histories stop at T+574; the original probe pods were later replaced in stage 2. The period from T+574 through the stage-2 restart at T+1211 has no continuous application-probe record.
- The original recovery gate did not record each gate input. The evidence note responsibly calls later recovery-gate reasoning an inference from harness code; it should not be presented as a direct observation.
- The only repeated long-lived-session observation is one opaque TCP stream, alive through T+574. It does not establish a general survival duration, HTTP behavior, or trust-anchor-expiry behavior.

## Article-validation checklist

| Required observation | Status | What the run supports | Remaining gap |
| --- | --- | --- | --- |
| What happens immediately when the identity issuer expires | **Supported, scoped** | At T+10, `linkerd check` reported the issuer expired; all recorded lab leaf-expiry metrics equaled the issuer’s `notAfter`; a new opaque TCP attempt failed by T+2 in the archived probe log. | One version/topology only; do not say every Linkerd deployment behaves identically. |
| Behavior as existing workload certificates approach expiration | **Supported, scoped** | The `control_identity_cert_*` gauges show shortened refresh intervals as the issuer deadline approached, then leaves clamped to the issuer deadline. | No default 24-hour-lifetime run; no direct workload-proxy log for the final failed refresh. |
| Newly started/restarted proxies after issuer expiry | **Supported** | A new workload and a rollout replacement remained unready with the native-sidecar startup probe returning 503; the old rollout pod remained Ready. | The experiment does not separate every possible reason a proxy can be unready from issuer expiry outside this controlled setup. |
| Exact proxy, log, and application errors from failed identity renewal | **Partial** | Application traffic recorded `Connection reset by peer`; the identity controller recorded CA-validation failures and `IssuerValidationFailed` events for requests that reached it. | The run has no workload-proxy logs, and the documented CSR refusals are for the identity pod’s own proxy. A rerun with the corrected collector is required before attributing a precise workload-proxy error or handshake side. |
| Observable behavior immediately after trust-anchor expiry | **Not tested** | Source notes provide a clearly marked code-based prediction only. | Run the short-lived-root scenario with the same probes and raw checks. |
| Established-connection survival and duration | **Partial** | One pre-expiry opaque TCP stream remained active for 574 seconds after issuer expiry. | No observation beyond T+574; no controlled HTTP/2 or gRPC stream; no root-expiry run. Avoid a universal duration claim. |
| API-server errors from each expired webhook certificate | **Not tested** | The documents list code/documentation predictions and the intended per-webhook experiments. | Exercise proxy injector, policy validator, ServiceProfile validator, and Viz/tap separately; record the matching API operation, `failurePolicy`, API-server error, `linkerd check`, and recovery. |
| Exact `linkerd check` output for each failure | **Partial** | Raw before/during/after output exists for issuer expiry, including the important result that checks passed after issuer replacement while four lab leaves remained expired. | There is no corresponding output yet for root expiry, webhook certificates, tap, or identity-service unavailability. |

## Do the current lab results support the article claims?

### Claims the results support

The following can be used as lab findings when the article names the tested version/configuration or uses language such as “in our lab”:

- With a 15-minute issuer and five-minute leaves, the recorded lab proxies’ leaf expiry timestamps converged on the issuer’s expiry time.
- Shortly after issuer expiry, a fresh opaque TCP request failed with `Connection reset by peer`, while the recorded pre-existing opaque TCP session continued through the 574-second observation window.
- A new pod and a rollout replacement could not become Ready after issuer expiry; their Linkerd proxy startup probe returned HTTP 503, while the old rollout pod remained Ready.
- Replacing the issuer caused the identity controller to load the replacement without restarting that controller in this run.
- In this run, the pre-existing lab workloads did not receive a new leaf during the 605-second observed post-reload window. A full lab-deployment restart restored the lab; the run does not identify the minimal set of necessary restarts.
- `linkerd check` detected the expired issuer, then became healthy after issuer replacement even though the recorded pre-existing lab proxies still had expired leaves.

### Claims that need narrowing before publication

1. **“New connections break first” is too broad without a protocol qualifier.** The lab’s opaque TCP probe opens a fresh connection on every attempt and failed. The HTTP probe continued to succeed, even though each loop invokes `curl` again. The materials correctly leave the reason open. Write about a fresh **opaque TCP/mTLS path in this lab**, not all new application requests or all new connections.

2. **“Established connections keep working” needs its observed bound.** The evidence supports one opaque TCP stream continuing for 574 seconds. It does not show how long it would have continued, whether all existing connections do, or what happens after root expiry.

3. **“If a proxy still has an expired certificate after issuer replacement, it probably has not been restarted” reverses the demonstrated direction.** The run shows that restarting every lab deployment worked and that no re-certification was seen before the final restart. It does not prove restart is the cause of every such case, nor establish the smallest required restart set.

4. **Exact error attribution remains incomplete.** The article should not say that a workload proxy emitted a specific `Failed to obtain identity` message, or claim which handshake peer rejected the traffic, until the corrected-harness rerun captures those logs.

5. **Do not call source-derived webhook/root behavior “what happens.”** The current reader pages already label these sections as untested; preserve that distinction in the eventual article or defer those claims until their scenarios run.

6. **The 60-day warning observation is valid but narrow.** It shows that a 15-minute issuer was already in the warning state at baseline and remained there until expiry. It does not by itself prove how every other duration or future Linkerd release will render the warning.

## Findings by article section

| Article area | Review result | Publishing posture |
| --- | --- | --- |
| Introduction / thesis | The issuer-expiry case establishes a vivid “partly broken mesh” narrative. | Use the observed split: new opaque TCP/rollout failures versus an existing TCP stream. Do not imply a total immediate outage. |
| Certificate landscape | The source notes are detailed and appropriately annotated. | Cite Linkerd documentation for the hierarchy; use the lab only for the issuer-expiry timing observation. |
| Triage | The reproduced issuer rows are well supported. | Keep a distinct “tested” versus “not yet tested” table until root/webhook tests exist. |
| Diagnosis | Raw issuer `linkerd check`, metrics, controller logs, events, and pod-state evidence are strong. | Include exact excerpts from the archived run, with version/lifetime context. Avoid claiming workload-proxy log text. |
| Issuer recovery | The documented issuer-only path was exercised with unchanged trust roots. | State that full lab restart restored the test; do not claim a minimal or universal restart recipe based only on this run. |
| Root recovery | Not tested. | Cite official recovery guidance; do not use the lab as support. |
| Webhooks / Viz | Not tested. | Keep as code/documentation-backed guidance only; no real API-server error transcript exists yet. |
| Monitoring | The issuer TTL and workload-leaf expiry metrics were observed. | Strong basis for recommending both; qualify metric names and availability by tested version. |

## Recommended next evidence, in priority order

1. **Rerun issuer expiry with the corrected collector.** Preserve workload proxy logs, per-pod probe histories, and recorded recovery-gate inputs. Extend the post-expiry window beyond 574 seconds without restarting the stream pod. This closes the largest evidence gap in the article’s main case.
2. **Run short-lived trust-anchor expiry.** Use the same control, probes, certificate metadata, and recovery record. It is required before publishing any causal/timing claim about root expiry.
3. **Run one webhook at a time.** Start with the proxy injector, then policy validator and ServiceProfile validator; add Viz/tap when installed. For each, record the exact API request, API-server response, webhook `failurePolicy`, `linkerd check`/`linkerd viz check`, and restoration result.
4. **Add an identity-service-unavailable scenario.** This separates “issuer cannot sign” from “proxy cannot reach identity,” which otherwise produce superficially similar symptoms.
5. **Add a protocol matrix for the issuer scenario.** At minimum: fresh opaque TCP, pre-existing opaque TCP, fresh HTTP request, and a deliberately long-lived HTTP/2 or gRPC stream. Record whether Linkerd’s proxy transport reuse changes the application-visible result.
6. **Repeat the core issuer scenario at least once.** A second clean run at the corrected harness is more valuable than expanding prose around the first run.

## Bottom line

The existing work is solid enough to anchor a carefully scoped issuer-expiry chapter. It is not yet a complete validation of the article outline. The documents already preserve most of the important uncertainty; the remaining risk is editorial overgeneralization, especially around “new connections,” durable connection survival, workload-proxy error text, and the untested root/webhook paths.
