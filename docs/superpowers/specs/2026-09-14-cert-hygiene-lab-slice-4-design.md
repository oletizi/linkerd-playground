# Cert-Hygiene Lab, Slice 4 — Design

**Status:** proposed, 2026-09-14. Extends the [slice 2 design](2026-09-11-cert-hygiene-lab-slice-2-design.md), which remains the binding authority for everything it covers: the rule table (§ 1.3), the gates (§ 1.6), the acceptance conditions (§ 13) and the guardrails (§ 14) all apply unchanged.

## 1. Why this slice

Every scenario the lab has run so far is a certificate that expired. Ten scenarios, twenty evidence runs, one cause.

The article's central device is a triage table: a reader arrives with a symptom and the table tells them which cause to check. That table is now entirely populated by reproduced expiry failures — which means the lab has never produced a failure the table would have to *distinguish* expiry from. A triage table built only from one cause has never been tested at the thing it exists to do.

This slice runs the two negative controls the feasibility matrix rates High confidence, from [`notes/demo-feasibility.md`](../../articles/cert-hygiene/notes/demo-feasibility.md) rows 3 and 15:

- **N — the webhook is unavailable and its certificate is perfectly healthy.** A failure that looks like the certificate and is not.
- **G — the certificate is time-valid but its signature algorithm is refused.** A certificate failure that is not expiry.

Neither needs an expiry wait, so both are minutes rather than hours.

## 2. What makes these worth running

The existing evidence produced one finding twice: a signal that looks authoritative can be wrong about what is happening. `linkerd check` went green while traffic was broken; its exit code stayed 0 with an issuer fifteen minutes from death; an expired tap certificate kept serving live events for 29½ minutes.

Both scenarios here ask the same question of the same signals, with the cause changed underneath them. The interesting outcome is not whether the API call fails — it will — but **what the diagnostic surface says while it does**. If `linkerd check` reports a healthy certificate for a certificate the API server refuses, that is the same finding a third time, in the place a reader is most likely to be misled by it.

## 3. Scenario N — the webhook is unavailable

Take a healthy installation with valid, long-lived webhook credentials. Scale the deployment behind one webhook to zero replicas. Probe the admission path it guards. Restore the replicas.

Run it under both failure policies, as the webhook expiry scenario does, because the policies are what set the blast radius.

**Credential plan:** all credentials long-lived and untouched. Nothing expires in this scenario, which is the point: every certificate must still be valid at the end of the run.

| # | Hypothesis | Basis |
| --- | --- | --- |
| N1 | With `failurePolicy=Fail`, an API request matching the webhook's rules is rejected with a connection-level error naming the service, and no X.509 or time-validity error appears anywhere in it. | Inference from Kubernetes admission control |
| N2 | With `failurePolicy=Ignore`, the same request is admitted, and — for the proxy injector — the pod is admitted without a proxy, exactly as an expired certificate produced. | Observed for expiry in the W runs |
| N3 | The webhook's serving certificate is valid for the whole run: `notAfter` in the future at every tick, and the same fingerprint as the configured `caBundle`. | The scenario never touches it |
| N4 | `linkerd check` reports the problem, but as a pod or readiness failure rather than a certificate failure, and no certificate row goes fatal. | Inference; **the hypothesis worth being wrong about** |
| N5 | Mesh traffic between already-running workloads is unaffected throughout. | Observed in every W run |

N2 is the one that makes the triage table earn its place: if an unavailable injector and an expired injector both yield a pod without a proxy, then the *symptom* does not identify the cause, and the table has to tell them apart by something else. What that something else is, is the finding.

**Validity rules:** `n-baseline` (the admission probe works and the webhook serves before the fault), `n-restored` (replicas return and the probe works again), `control-at-tree`.

## 4. Scenario G — the certificate is refused for its algorithm

Install with a webhook serving certificate that is time-valid and chains to its configured bundle, but is signed with an algorithm the API server's Go runtime refuses. Probe the admission path. Restore a normally-signed certificate.

**Feasibility is not established.** The lab signs with `step`, which will not emit a deprecated signature algorithm, and the relevant Go behaviour has changed across versions — SHA-1 verification was first gated and later removed outright. Whether this cluster's API server refuses such a certificate, and with what message, is unknown. **This scenario therefore opens with a stop gate** (see the plan's Task 3): produce a candidate certificate outside the harness, confirm the API server refuses it for its algorithm rather than anything else, and record the exact error. If no candidate is refused for its algorithm, G is not runnable as designed and the controller decides what to do with the slice.

Candidates to try, in order: a SHA-1-signed leaf, an undersized RSA key, an MD5-signed leaf. `openssl` rather than `step` will almost certainly be needed, which is itself a fact worth recording — a credential the lab's normal tooling refuses to produce.

| # | Hypothesis | Basis |
| --- | --- | --- |
| G1 | The API server rejects calls to the webhook with an error naming the signature algorithm or key, and containing no time-validity language. | Kubernetes [#110530](https://github.com/kubernetes/kubernetes/issues/110530) |
| G2 | The certificate is time-valid for the whole run — `notAfter` far in the future at every tick — so nothing in the failure is attributable to expiry. | The scenario sets a long lifetime |
| G3 | `linkerd check`'s row for that webhook's certificate **passes**, because it checks dates and chaining rather than whether the platform will accept the signature. | Inference; **the hypothesis worth being wrong about** |
| G4 | Mesh traffic between already-running workloads is unaffected throughout. | Observed in every W run |

G3 is the one to watch. If it holds, the lab has a certificate that `linkerd check` calls valid and the API server refuses — the strongest possible form of "the check is not measuring what you think."

**Validity rules:** `g-baseline` (the admission probe works with a normally-signed certificate before the swap), `g-timevalid` (the refused certificate's `notAfter` is in the future at every recorded tick — without this the run cannot distinguish itself from an expiry run), `control-at-tree`.

## 5. Acceptance conditions (extending § 13)

| Scenario | Condition |
| --- | --- |
| N | Both policies recorded, each with a healthy baseline proving its probe; the webhook's certificate shown valid at every tick; the exact API error preserved for `Fail`; the admitted object preserved for `Ignore`; replicas shown restored and the probe working again. |
| G | The refused certificate's `notAfter` recorded at every tick and in the future at all of them; the exact API-server error preserved verbatim; `linkerd check`'s certificate row for that webhook recorded before and during; a normally-signed certificate shown working in the same run, before the swap. |

A G run whose certificate cannot be shown time-valid throughout is not evidence: it cannot be distinguished from the expiry scenario it exists to contrast with.

## 6. Harness debt, paid in this slice

Adding scenarios changes the harness tree and so costs a control re-run regardless. The three items deferred from slice 3's final review are therefore done here, where they are free:

- `control-at-tree` reads the control run from committed manifests rather than from a directory on disk, which is what made a published-and-deleted control invalidate a good run.
- The reconnect-exit block duplicated verbatim between `w-reconnect` and `v-reconnect` becomes one helper.
- `_v_backing` carries its derived namespace rather than deriving it and then hardcoding `linkerd-viz`.
- Unit tests for the collectors added in slice 3: `snap_apiservices`' sentinel, `_v_tap_events`' counting, `make_tap_cert` / `tap_install_args`, and `load_profile`'s required key.

## 7. Out of scope

Feasibility rows 1 and 4 (chain mismatch, for the webhook and the issuer) are the natural next pair and are deliberately not in this slice — they are a second, separable argument about a third cause. Rows 10 and 12 remain research-only: no deterministic reproduction is known, and producing one would risk inventing a cause. Rows 13 and 14 add cert-manager, a different tool surface, and belong in their own slice.
