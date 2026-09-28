# Task 6b: The tap-expiry evidence run, second attempt

Part of the [slice 3 plan](README.md). Read its Global Constraints first. This replaces [Task 6](task-06-v-run.md), whose run is published but not evidence.

**Why there is a second attempt.** The first run, `runs/30-tap-expiry/20260914T081309Z`, executed correctly and then failed its validity check for a bookkeeping reason: the `control-at-tree` rule reads `runs/00-baseline-control/*/validity.txt` from disk, and Task 5 had deleted the control's local copy after publishing it. **The control has since been restored** to `runs/00-baseline-control/20260914T071125Z`, fetched from its published archive and verified against its committed manifest (`evidence_valid=yes`, harness tree `206cd4f55895d89011a65c131f03c09c911b06588547f3162a13bab440f7dfa3`).

**Do not delete that control directory, and do not modify the harness.** The harness is correct and frozen; the first run's failure was a workspace state problem, now fixed.

**Steps:** identical to Task 6, which you should read and follow in full. In summary:

1. Confirm the control directory is present and valid, and that the harness tree still hashes to `206cd4f5…` and is clean.
2. `bash scripts/run.sh 30-tap-expiry` from demos/cert-hygiene — no `--discovery`, no `--short`. Roughly 50 minutes including the reconnect phase; detached, waited out with bounded foreground waits.
3. Check `validity.txt` is `evidence_valid=yes` — this time it should be, and if it is not, report the reason and stop rather than adjusting anything.
4. Check `tap-baseline.txt` says `result=ok`, the reconnect artifacts end `[exit 0]`, and the viz pod's UID differs across the restart.
5. Record the per-phase observations Task 6 step 4 lists, as seen and never judged.
6. Publish, verify, commit the manifest, attach the archive to release `cert-hygiene-evidence-2026-09-13`, and remove this run's local copy — **but not the control's**.

**One thing to check that Task 6 did not.** In the first run the reconnect rollout returned `[exit 0]` four seconds after the restart command was issued. Confirm from the recorded pod UIDs and timestamps that the viz pod genuinely cycled, rather than `kubectl rollout status` returning before the new pod replaced the old one. If the rollout returns that fast again and the UIDs do show a real replacement, say so explicitly — it is a fact about this deployment worth recording, not a defect.
