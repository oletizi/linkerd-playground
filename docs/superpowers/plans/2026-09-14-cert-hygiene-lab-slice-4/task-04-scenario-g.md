# Task 4: Scenario G — the certificate is refused for its algorithm

Part of the [slice 4 plan](README.md). Read its Global Constraints first, then the [design](../../specs/2026-09-14-cert-hygiene-lab-slice-4-design.md) § 4, which defines G1–G4 and G's validity rules.

**This task runs only if Task 3's gate passed.** Task 3's findings tell you which certificate is refused and what the error looks like; build for that one, not for the candidate list.

**Goal:** a scenario that installs a time-valid, correctly-chained webhook serving certificate the API server refuses for its algorithm, probes the admission path, and restores a normally-signed certificate — recording at every tick that the refused certificate had not expired.

**Files:**
- Create: `demos/cert-hygiene/scenarios/41-webhook-algorithm.sh`, `demos/cert-hygiene/lab/profiles/webhook-algorithm.env`
- Modify: `demos/cert-hygiene/lab/lib-webhook.sh` (a maker for the refused credential), `lab/lib-evidence-rules.sh` (the `g-baseline` and `g-timevalid` rules, the rule list, required files)
- Test: `demos/cert-hygiene/lab/tests/test-rules.sh`, `test-webhook.sh`

**The credential maker.** Task 3 falsified the premise this brief was written on: `step` *will* emit a SHA-1 leaf, through a certificate template setting `"signatureAlgorithm": "SHA1-RSA"`. Only its command-line flags refuse. So do **not** add an `openssl` path — keep the harness on one signing tool, and put the maker in `lib-webhook.sh` beside `make_webhook_cert`. Its comment should say that only `step`'s flags refuse this and a template does not, because that is a fact about the tool a reader might otherwise trust as a safeguard.

It must produce a certificate that is time-valid, carries the right SAN, and chains to the CA whose certificate becomes the `caBundle` — everything correct except the thing under test.

**`g-timevalid` is the rule that makes this evidence.** It must check that the refused certificate's `notAfter` is in the future at **every** recorded tick, from its own recorded state. Without it, a G run is indistinguishable from an expiry run, and the whole contrast collapses. Write its test so it fails on a run whose certificate expired mid-way — construct that fixture, do not assume it.

**What must be recorded per tick:**

- The admission probe set with each attempt's exact response, in its phase (before the swap, while refused, after restore).
- The certificate's `notAfter` and the remaining validity at that tick, and its signature algorithm as the certificate itself reports it.
- `linkerd check` in full, with exit status. **G3 is the hypothesis worth being wrong about** — whether the check calls this certificate valid while the API server refuses it — and it is answerable only from complete transcripts recorded during the fault. Task 3 found `linkerd check` does *not* pass the row: it goes `×` naming `insecure algorithm SHA1-RSA` and halts early. **That does not settle G3** — a discovery run is not evidence, and the hypothesis is judged from the evidence run's own transcripts. Record; do not conclude.
- **`linkerd viz check` is dropped from G.** Task 3 found viz is not installed on the webhook profiles, so all three of its transcripts read "namespace not found" — a recorded non-answer that would clutter the evidence and tempt a reader into reading absence as a result. Do not add viz to G's profile to chase it; G is about the API server's treatment of a serving certificate, and viz is a separate surface.
- The k3s journal across the fault. **Capture it with a relative `--since`, not an absolute UTC timestamp.** Task 3's first journal capture came back `-- No entries --` because it passed a UTC `--since` to a `journalctl` reading local time on a UTC-7 VM. That artifact is preserved empty under the write-once rule; do not reproduce the bug.
- Sample each tick's timestamps **once**. Task 3's time-validity captures took the epoch and the ISO string from two separate `date` calls, leaving a one-second skew inside a single record. All its arithmetic used the epochs only, but a record that disagrees with itself invites a reader to distrust both halves.
- The mesh traffic probes.

**Steps:**

1. Read Task 3's report at `.superpowers/sdd/slice4/task-3-report.md` and the run it published — `runs/_discovery/20260914T201438Z-algorithm`, read through `bash tools/evidence.sh cat`, never the B2 API. Build for what it found.

   **Use the ServiceProfile validator**, the component Task 3 proved end to end including restore. The mechanism under test is the API server's certificate verification, which is not component-specific, and the sp-validator has the smallest blast radius: a refused proxy-injector certificate under `failurePolicy=Fail` would fail every pod creation in injected namespaces, and a run that cannot recover is a lost run. N used the proxy injector, so the write-up will have to state that the two scenarios tested different components rather than implying one; that is a caveat worth paying for a scenario that reliably restores.

   **Use `failurePolicy=Fail`.** Under `Ignore` the client sees nothing — Task 3 confirmed only the journal and the admitted object carry any trace — and G1 is about the error the API server returns.
2. Read `lib-webhook.sh`, `scenario-webhook.sh` and `lib-evidence-rules.sh` before changing them. Reuse the admission probes rather than copying them.
3. Build the scenario, both rules, and their tests.
4. `bash -n`, `shellcheck`, `just demo cert-hygiene test` clean.
5. One discovery run. Confirm the probe fails while the certificate is installed, that the certificate is recorded time-valid at every tick, and that the restore works. Report what the checks said, as observation only.
6. Commit and push, recording the discovery run as the others are recorded.

**If the scenario cannot produce a run whose certificate is provably time-valid throughout**, stop and report rather than adjusting the rule to let it pass. That rule is the scenario's reason for existing.
