# Task 6: The tap-expiry evidence run

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** one valid run of `30-tap-expiry`, recorded at the frozen slice 3 harness tree, published.

**The control this run is judged against:** `runs/00-baseline-control/20260914T071125Z`, harness tree `206cd4f55895d89011a65c131f03c09c911b06588547f3162a13bab440f7dfa3`. This run's `git-state.txt` must carry the same hash, or `control-at-tree` fails and the run is not evidence.

**Steps:**

1. Confirm the harness tree is clean and its hash still matches the control's. If it does not, stop and report: something changed after the freeze, and the controller decides.
2. `bash scripts/run.sh 30-tap-expiry` from demos/cert-hygiene — no `--discovery`, no `--short`, so the full windows apply. Roughly 40 minutes plus the reconnect window, detached; wait with bounded foreground waits.
3. Check the run:
   - `validity.txt` is exactly `evidence_valid=yes`.
   - `tap-baseline.txt` says `result=ok` — tap worked while its certificate was valid, which is what makes everything after the expiry meaningful.
   - `reconnect/backing.txt` names a Deployment; `reconnect/restart.txt` and `reconnect/rollout.txt` both end `[exit 0]`; the viz pod's UID differs before and after.
   - Per-tick `tap/`, `apiservices/`, `viz/` and check transcripts exist across the expiry and the reconnect phase.
4. Record in your report, as seen and never judged — Task 8 judges V1:
   - the tap certificate's `notAfter` and the time of each phase;
   - for the last tick before the expiry, the first tick after it, the last tick before the reconnect, and each reconnect tick: whether `linkerd viz tap` returned events (and how many), the APIService's `Available` status with its reason, and whether `linkerd viz check`'s tap row passed;
   - whether the mesh traffic probes failed at any point, and when relative to the reconnect restart;
   - the exact text of the first tap failure and of the APIService condition after the restart.
5. Publish: `KEEP_ARCHIVE=1 bash tools/evidence-upload.sh <run-dir>`, then `bash tools/evidence-verify.sh <run-dir>`, then commit the manifest, attach the kept archive to the release `cert-hygiene-evidence-2026-09-13` with `gh release upload`, and remove the local run directory and the archive.
6. If the run is invalid, publish and commit it anyway, then stop and report with `validity.txt`'s reasons. Do not re-run it or change the harness.
