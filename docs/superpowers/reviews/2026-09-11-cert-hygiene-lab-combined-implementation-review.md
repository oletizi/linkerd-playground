# Cert-Hygiene Lab — Combined Evidence and Slice 2 Implementation Review

**Status:** Implementation-facing review. Resolve the blocking items below before treating slice 2 results as article evidence.

**Reviewed:** [as-built evidence review](../../articles/cert-hygiene/LAB-EVIDENCE-REVIEW-2026-09-11.md), [slice 2 design](../specs/2026-09-11-cert-hygiene-lab-slice-2-design.md), existing raw run artifacts, harness code, and source notes.

**Purpose:** Give the implementing agent one defensible starting point. This is not a new design and it does not change the approved scenario order. It distinguishes observations already supported by the lab from source-derived expectations and specifies the evidence conditions slice 2 must meet before article claims move to “reproduced.”

## Bottom line

The first issuer-expiry run is a solid, scoped foundation: it demonstrates an issuer-expiry failure in the tested lab configuration. It does **not** establish the article’s broader root, webhook, Viz, identity-outage, connection-survival, or workload-proxy-log claims.

Slice 2 has the right scenario set and several important safeguards: throwaway discovery runs, a clean-tree control, planned credential transitions, baseline admission probes, and the two-client recovery matrix. It should proceed only after the implementation plan incorporates the blockers in this review. Otherwise a passing run could be unable to distinguish TLS failures from ordinary rollout disruption, or be unable to supply the promised per-webhook evidence.

## What the lab currently supports

The following statements are supported only in the observed `edge-26.9.1` / k3s lab with a 15-minute issuer and five-minute leaves. Keep that qualification in reader-facing material.

- Shortly after issuer expiry, a fresh opaque-TCP attempt failed, while one pre-existing opaque-TCP stream remained alive through the 574-second observation window.
- The recorded workload leaf expiries converged on the issuer `notAfter`.
- A newly created pod and a rollout replacement did not become Ready after issuer expiry; the existing rollout pod remained Ready.
- Replacing the issuer updated the identity controller in that run without an identity-pod restart; the final restart of all lab deployments restored the lab.
- `linkerd check` reported the expired issuer and became healthy after issuer replacement even though pre-existing workload leaves were still recorded as expired.

These are **not** supported as general claims yet:

- a universal “new connections fail first” rule (the HTTP probe kept working; only the fresh opaque-TCP path was observed);
- how long established connections survive;
- the exact error emitted by a *workload* proxy during failed renewal (the first run lacks the required workload-proxy logs);
- trust-anchor expiry/recovery behavior;
- API-server errors for expired webhook certificates;
- identity-service outage behavior; or
- Viz/tap behavior.

For the detailed artifact-level assessment, see the [as-built evidence review](../../articles/cert-hygiene/LAB-EVIDENCE-REVIEW-2026-09-11.md).

## Required implementation corrections

### 1. Isolate webhook expiry by webhook

**Blocking for W’s promised evidence.** The design expires the proxy injector, policy validator, and ServiceProfile validator at the same `T_mark`. That can show that admission is degraded, but it is weaker evidence for the required “exact API-server error from each expired webhook certificate.”

Implement distinct expiry phases or profiles for each webhook. For each phase, record:

- the matching API request and exact response;
- the resulting object state (injected/not injected, accepted/rejected);
- the selected webhook configuration, `failurePolicy`, and CA-bundle hash;
- serving-certificate identity and expiry; and
- the matching `linkerd check` transcript and recovery outcome.

The proxy injector, policy validator, and ServiceProfile validator should each have a healthy baseline that proves the particular probe actually invokes and exercises that webhook. Viz/tap remains optional and requires user confirmation.

### 2. Treat supplied-webhook recovery as branching observation, not W6’s prediction

**Blocking for a valid W recovery conclusion.** The static credentials deliberately differ from Linkerd-managed credentials. The project’s source notes say that any Linkerd re-render can rotate webhook certificates. Therefore the plain `linkerd upgrade` outcome cannot be assumed to “re-apply the supplied expired certificates.”

Before the evidence run, declare the permissible observed branches, for example:

1. plain upgrade produces fresh generated credentials and matching webhook CA bundles;
2. plain upgrade re-renders supplied credentials; or
3. plain upgrade leaves the serving path unhealthy, requiring explicit fresh supplied credentials.

For every branch, capture the complete rendered manifest, the Secret certificate DER fingerprint/serial/`notAfter`, webhook `caBundle` hash, relevant Deployment generation and pod UID, and a post-propagation admission probe. Do not count an upgrade command’s exit status as recovery by itself.

### 3. Do not make k3s journal output a W validity condition

**Blocking for fair interpretation, not for collecting logs.** Kubernetes documents `failurePolicy` semantics; it does not guarantee a durable API-server log record for every ignored or rejected webhook call. Continue capturing the k3s journal, but treat it as supplementary evidence. The exact client/API response and observed object are the primary record. Absence of a matching journal line is a result, not automatic falsification.

### 4. Gate every restart stage before judging TLS behavior

**Blocking for R, O, and S-hard attribution.** A one-replica client or server restart can create ordinary availability failures. Before collecting the probe samples that classify a matrix cell, require and save proof that each restarted workload:

- is Ready and present in Endpoints/EndpointSlices as applicable;
- has the intended trust-bundle hash and certificate state;
- has emitted/received the expected leaf after its restart; and
- has passed a non-TLS availability/readiness check.

Take repeated fresh-connection samples after this gate, rather than treating a rollout-adjacent failure as mTLS evidence. Add a long-profile restart-choreography control, or explicitly label the non-TLS restart disruption as unseparated observation.

### 5. Make S-hard wait for the actual leaf transition it claims to test

**Blocking for S4.** `RECOVER_WINDOW_S` alone is not an adequate boundary. The stage-1 claim depends on an unrestarted proxy attempting renewal, rejecting or failing to accept the new issuer chain, retaining its old leaf, and then failing after that particular leaf expires.

For each unrestarted endpoint, record the last old leaf, its `notAfter`, the renewal attempt/result, and the first failed forced-new connection. Do not proceed to mixed-trust restart stages until this per-endpoint condition has been observed or a declared timeout has made the scenario invalid.

### 6. Make anchor-expiry recovery’s control-plane restart test explicit

**Blocking for A5’s causal claim.** The claim that recovery needs a control-plane restart is an inference to test, not an already established observation. “Once the control plane is stable” is circular if identity must restart to read new roots.

After applying the new root and issuer, record a bounded no-manual-restart observation window, including control-plane pod UIDs, identity logs, events, and CSR results. If recovery is not achieved, perform an explicit control-plane/identity restart as the next named stage. Report whether the upgrade alone restarted each component and whether the explicit restart was necessary in this lab.

### 7. Strengthen timing and credential identity validity checks

For K, calculate remaining validity from the certificate’s `notAfter` and the actual `linkerd check` invocation time. The plus-ten-minute test is valid only if it still has more than 60 days remaining at the recorded check time; otherwise repeat it.

For all scenarios, record SHA-256 fingerprints of the relevant certificate DER/PEM in addition to serial and `notAfter`. Retain service DNS names/SANs for webhook serving certificates. This makes planned-transition validation resistant to ambiguous reissues and makes `linkerd check` name-validation findings auditable.

## Scenario-specific acceptance conditions

| Scenario | Do not call it reproduced until… |
| --- | --- |
| **R — issuer expiry rerun** | Workload `linkerd-proxy` logs, per-pod continuous probe history, and recovery-stage gates exist; any established-connection claim names its protocol and measured duration. |
| **W — webhooks** | Each webhook is isolated; healthy baselines prove the probes; exact responses/object states, checks, and recovery branch artifacts exist for both `Ignore` and `Fail` where applicable. |
| **O — identity outage** | The credential/config invariant holds, outage duration exceeds the relevant leaf window, and no-restart recovery is evaluated before restart stages. |
| **K — check threshold** | Both actual remaining-validity measurements and both command transcripts put the checks on opposite sides of the 60-day boundary. |
| **A — anchor expiry** | Per-proxy final-leaf timing, identity CSR evidence, checks, and the named no-restart/explicit-control-plane-restart recovery stages exist. |
| **S — staged/hard rotation** | Staged results separate TLS-attributable failures from rollout disruption; hard rotation records actual mixed-anchor endpoint states and the prerequisite old-leaf renewal/expiry behavior. |
| **V — Viz/tap** | The user has approved it, and APIService status, CLI output, certificate state, and `linkerd viz check` are captured. |

## Evidence and publishing guardrails

- Discovery artifacts are valuable implementation records but never evidence runs.
- A scenario failure is not evidence of its hypothesis until the run satisfies its validity rules; preserve invalid artifacts and explain the failure rather than silently rerunning over them.
- A successful `linkerd check` after issuer replacement does not prove pre-existing workload leaves were renewed; the first run demonstrated that distinction.
- Only move reader-facing rows from “expected from code” to “reproduced” after a scenario write-up links exact run artifacts to the claim.
- Phrase findings as “in this lab” unless independently established by primary documentation and clearly marked as source-derived.

## Recommended implementation order

Keep the approved order: **R → W → O → K → A → S**, with **V only after user confirmation**. Within that order:

1. Land and test the generalized collectors, credential fingerprinting, restart-stage gates, and second client in discovery work.
2. Commit the harness and verify a clean tree.
3. Run the long-profile control, including the restart choreography needed for later matrix interpretation.
4. Execute evidence runs without harness changes; if a fix is necessary, commit it, rerun the control, and rerun affected scenarios.
5. Write each scenario’s evidence note before updating article findings or best-practice guidance.

## Strengths worth retaining

The design’s separation of discovery from evidence, planned credential-transition validation, baseline admission probes, per-tick control-plane pod identity, and two-client state matrix directly address significant slice-1 shortcomings. Retain these protections; they are what make the expanded lab suitable for defensible article evidence rather than merely an illustrative demo.
