# Task 4: Scenario G — the certificate is refused for its algorithm

Part of the [slice 4 plan](README.md). Read its Global Constraints first, then the [design](../../specs/2026-09-14-cert-hygiene-lab-slice-4-design.md) § 4, which defines G1–G4 and G's validity rules.

**This task runs only if Task 3's gate passed.** Task 3's findings tell you which certificate is refused and what the error looks like; build for that one, not for the candidate list.

**Goal:** a scenario that installs a time-valid, correctly-chained webhook serving certificate the API server refuses for its algorithm, probes the admission path, and restores a normally-signed certificate — recording at every tick that the refused certificate had not expired.

**Files:**
- Create: `demos/cert-hygiene/scenarios/41-webhook-algorithm.sh`, `demos/cert-hygiene/lab/profiles/webhook-algorithm.env`
- Modify: `demos/cert-hygiene/lab/lib-webhook.sh` (a maker for the refused credential), `lab/lib-evidence-rules.sh` (the `g-baseline` and `g-timevalid` rules, the rule list, required files)
- Test: `demos/cert-hygiene/lab/tests/test-rules.sh`, `test-webhook.sh`

**The credential maker.** `lib-webhook.sh` signs with `step`; this certificate needs `openssl`. Put it in the same file beside `make_webhook_cert`, name it for what it produces rather than how, and make its comment say plainly that the lab's normal tooling refuses to emit this and why that is the point. It must produce a certificate that is time-valid, carries the right SAN, and chains to the CA whose certificate becomes the `caBundle` — everything correct except the thing under test.

**`g-timevalid` is the rule that makes this evidence.** It must check that the refused certificate's `notAfter` is in the future at **every** recorded tick, from its own recorded state. Without it, a G run is indistinguishable from an expiry run, and the whole contrast collapses. Write its test so it fails on a run whose certificate expired mid-way — construct that fixture, do not assume it.

**What must be recorded per tick:**

- The admission probe set with each attempt's exact response, in its phase (before the swap, while refused, after restore).
- The certificate's `notAfter` and the remaining validity at that tick, and its signature algorithm as the certificate itself reports it.
- `linkerd check` and `linkerd viz check` in full, with exit status. **G3 is the hypothesis worth being wrong about** — whether the check calls this certificate valid while the API server refuses it — and it is answerable only from complete transcripts recorded during the fault.
- The k3s journal across the fault, as the webhook scenarios record it.
- The mesh traffic probes.

**Steps:**

1. Read Task 3's `FINDINGS.md` and its transcripts first. Build for what it found.
2. Read `lib-webhook.sh`, `scenario-webhook.sh` and `lib-evidence-rules.sh` before changing them. Reuse the admission probes rather than copying them.
3. Build the scenario, both rules, and their tests.
4. `bash -n`, `shellcheck`, `just demo cert-hygiene test` clean.
5. One discovery run. Confirm the probe fails while the certificate is installed, that the certificate is recorded time-valid at every tick, and that the restore works. Report what the checks said, as observation only.
6. Commit and push, recording the discovery run as the others are recorded.

**If the scenario cannot produce a run whose certificate is provably time-valid throughout**, stop and report rather than adjusting the rule to let it pass. That rule is the scenario's reason for existing.
