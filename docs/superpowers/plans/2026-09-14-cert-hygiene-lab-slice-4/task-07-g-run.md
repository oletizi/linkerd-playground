# Task 7: The G evidence run

Part of the [slice 4 plan](README.md). Read its Global Constraints first. **This task runs only if Task 3's gate passed and Task 4 built the scenario.**

**Goal:** one valid run of `41-webhook-algorithm` at the frozen slice 4 harness tree, published.

**The control it is judged against:** the run Task 5 recorded; this run's `git-state.txt` must carry the same harness tree hash.

**Steps:**

1. Confirm the harness tree is clean and matches the control's hash.
2. `bash scripts/run.sh 41-webhook-algorithm` — no `--discovery`, no `--short`. Detached, waited out with bounded foreground waits.
3. Check the run:
   - `validity.txt` is exactly `evidence_valid=yes`;
   - `g-baseline` passed — a normally-signed certificate worked in this same run, before the swap;
   - `g-timevalid` passed — **the refused certificate's `notAfter` is in the future at every recorded tick**. This is the rule that separates G from an expiry run. If it failed, the run is not evidence and no amount of interesting output rescues it.
4. Record in your report, as seen and never judged — Task 8 judges G1–G4:
   - the certificate's signature algorithm and key size as the certificate itself reports them, its `notAfter`, and the remaining validity at each tick;
   - the exact API-server error, verbatim, and whether it contains any time-validity language at all;
   - **`linkerd check`'s row for that webhook's certificate while the certificate is installed and being refused** — quote the row, say whether it passed, and give the command's exit status. Do the same for `linkerd viz check`. This is G3 and it is the most consequential thing the run records;
   - what the k3s journal holds across the fault, and whether its wording matches the API-server response;
   - whether the restore worked and the probe succeeded again afterwards;
   - whether mesh traffic failed at any point.
5. Publish: `KEEP_ARCHIVE=1 bash tools/evidence-upload.sh <run-dir>`, `bash tools/evidence-verify.sh <run-dir>`, commit the manifest only, attach the archive to the evidence release, remove the local copy.
6. If the run is invalid, publish and commit it anyway, then stop and report. Do not adjust `g-timevalid` to make a run pass.
