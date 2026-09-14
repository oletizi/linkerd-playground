# Task 2: Scenario N — the webhook is unavailable

Part of the [slice 4 plan](README.md). Read its Global Constraints first, then the [design](../../specs/2026-09-14-cert-hygiene-lab-slice-4-design.md) § 3, which defines N1–N5 and N's validity rules.

**Goal:** a scenario that takes a healthy installation, removes the pods behind one webhook, probes the admission path it guards, and restores them — recording throughout that the webhook's certificate was valid the whole time.

**Files:**
- Create: `demos/cert-hygiene/scenarios/40-webhook-unavailable.sh`, `demos/cert-hygiene/lab/profiles/webhook-available.env` (long-lived credentials, both policies)
- Modify: `demos/cert-hygiene/lab/lib-evidence-rules.sh` (the `n-baseline` and `n-restored` rules, the rule list, required files), `lab/collect-state.sh` if replica state needs a collector
- Test: `demos/cert-hygiene/lab/tests/test-rules.sh`

**Reuse rather than copy.** The webhook scenarios already have everything this needs: `scenario-webhook.sh`'s admission probes, `lib-webhook.sh`'s credential helpers, `w_backing_line` for finding the Deployment behind a webhook Service, and the `Ignore`/`Fail` profile pair. N is the same probe set with a different fault. If you find yourself copying a block out of `scenario-webhook.sh`, share it instead and say so in your report.

**The fault:** scale the Deployment behind the proxy injector's Service to zero replicas, wait for the pods to go, probe, then scale back and wait for readiness. Use `w_backing_line`'s derivation rather than hardcoding a name. The proxy injector is the component to use, because its failure under `Ignore` produces a pod with no proxy — the same observable an expired injector certificate produced, which is the contrast N exists to draw.

**What must be recorded per tick**, since the write-up judges N1–N5 and the scenario judges nothing:

- The admission probe set, in the phase it was taken (before the fault, during, after restore), with each attempt's exact response preserved.
- For `Ignore`, the admitted object, so "was it injected" is answerable from the artifact.
- The webhook's serving certificate state: `notAfter` and the X.509 fingerprint against the configured `caBundle`'s. **Every tick, including during the fault** — N3 is the hypothesis that makes this a control, and it cannot be judged from a single sample.
- Replica counts and pod state for the backing Deployment.
- `linkerd check` and `linkerd viz check` transcripts, whole, with their exit status. N4 asks what the check says while this is happening, and the exit code is part of the answer — slice 3 established that it is not always what a reader expects.
- The mesh traffic probes, as every scenario records them.

**Validity rules** (these judge admissibility only, never N1–N5):

- `n-baseline`: before the fault, the admission probe succeeded and the webhook served correctly. Without it a failure during the fault proves nothing.
- `n-restored`: after the replicas return, the probe works again. This is what distinguishes "the fault caused it" from "the cluster was broken".

Add both to the rule table with tests that can fail, and add N's required files to `scenario_required_files`.

**Steps:**

1. Read `scenarios/02-webhook-expiry-ignore.sh`, `lab/scenario-webhook.sh` and `lab/lib-evidence-rules.sh` first.
2. Build the scenario for both policies, as the W pair does.
3. `bash -n`, `shellcheck`, `just demo cert-hygiene test` clean.
4. One discovery run: `bash scripts/run.sh 40-webhook-unavailable-ignore --discovery`. Read it and report what the probes, the certificate state and the checks actually recorded — as observations, never as verdicts on N1–N5.
5. Commit and push, recording the discovery run as the other discovery runs are recorded.

**Report, do not judge.** If the discovery run shows something that looks like a finding — particularly anything about what `linkerd check` does or does not say — write it down as what was observed and leave the judgement to Task 8.
