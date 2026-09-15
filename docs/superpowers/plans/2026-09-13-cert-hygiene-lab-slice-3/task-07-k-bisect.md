# Task 7: Bisect the `linkerd check` 60-day boundary

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** replace "somewhere in a 24-hour window" with a measured bracket, by running the threshold scenario at several replacement-issuer lifetimes.

**What is already known, from slice 2's evidence run and its supplementary run:**

| Remaining validity when the check ran | Issuer row |
| --- | --- |
| 60 days + 557 s | warned (fatal `‼`) |
| 61 days + 30 min | passed (`√`) |

So the boundary lies above 60 days + 557 s and at or below 61 days + 30 min — about 24 hours wide. One plausible explanation is that the check allows for a certificate's own issuance window, but nothing in our evidence establishes that.

**K needs no control run**, because it judges no probe outcome. Each run is about 15 minutes.

**Steps:**

1. Confirm the tree is clean. Record the harness tree hash in your report, though K's validity does not depend on matching a control.
2. Run the scenario at a lifetime you choose, passing it as the argument Task 4 added: `bash scripts/run.sh 20-check-threshold <lifetime>` from demos/cert-hygiene, waited out with bounded foreground waits.
3. After each run, read `k/plus-calc.txt` and the two plus transcripts, and compute the remaining validity at the moment each check ran and whether the issuer row passed or warned. **The remaining validity, not the configured lifetime, is what locates the boundary** — the certificate is signed a little before the check runs, so the two differ by however long the reset and the issuer-only upgrade took.
4. **Bisect.** Start at the midpoint of the known bracket (about 60 days + 12 hours) and halve the remaining interval with each run, choosing each lifetime from what the previous runs measured. Four runs take the bracket from about 24 hours to roughly 90 minutes. Stop after four runs, or earlier if two consecutive runs land within an hour of each other.
5. Publish each run as it finishes — `KEEP_ARCHIVE=1 bash tools/evidence-upload.sh <run-dir>`, `bash tools/evidence-verify.sh <run-dir>`, commit the manifest, attach the archive to release `cert-hygiene-evidence-2026-09-13`, remove the local copy — so a crash never loses a completed run.
6. A run whose `k-remaining.txt` says `result=fail` is invalid: publish and commit it, and treat its measurement as unusable. Do not repeat it in-run; note it and choose the next lifetime.
7. In your report, give a table of every run: the lifetime passed, the remaining validity measured at each check's start and end, and the issuer row's verdict. State the final bracket as two measured numbers — the largest remaining validity that still warned, and the smallest that passed — and nothing beyond what those support. Do not claim a mechanism.
