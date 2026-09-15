# Task 6: The N evidence runs

Part of the [slice 4 plan](README.md). Read its Global Constraints first.

**Goal:** two valid runs, `40-webhook-unavailable-ignore` and `40-webhook-unavailable-fail`, recorded at the frozen slice 4 harness tree and published.

**The control these are judged against:** the run Task 5 recorded. Both runs' `git-state.txt` must carry its harness tree hash, or `control-at-tree` fails and they are not evidence.

**Steps:**

1. Confirm the harness tree is clean and its hash still matches the control's. If it does not, stop and report.
2. Run each policy in turn — not in parallel; there is one cluster. No `--discovery`, no `--short`. Launch detached and wait with bounded foreground waits.
3. Check each run:
   - `validity.txt` is exactly `evidence_valid=yes`;
   - `n-baseline` and `n-restored` both passed, which together prove the probe worked before the fault and again after it;
   - the webhook's certificate is recorded at every tick with a `notAfter` in the future — if any tick shows otherwise the run is not a control and you should stop and report;
   - the admission probes exist for all three phases with their exact responses.
4. Record in your report, as seen and never judged — Task 8 judges N1–N5:
   - the replica counts and pod state through each phase, with the times the pods went and returned;
   - for `Fail`: the exact text of the rejected API request, and whether it contains any X.509 or time-validity language;
   - for `Ignore`: whether the probe pod was admitted, and whether it came up with a proxy — quote the container list;
   - `linkerd check`'s and `linkerd viz check`'s output during the fault, including which rows failed, which passed, and the exit status of each;
   - the webhook certificate's `notAfter` and fingerprint at the tick during the fault, against the configured `caBundle`;
   - whether the mesh traffic probes failed at any point.
5. Publish each: `KEEP_ARCHIVE=1 bash tools/evidence-upload.sh <run-dir>`, `bash tools/evidence-verify.sh <run-dir>`, commit the manifest only, attach the archive to the evidence release under the same naming the existing assets use, then remove the local run directory and archive. Publish the first before starting the second.
6. If a run is invalid, publish and commit it anyway, then stop and report with `validity.txt`'s reasons. Do not re-run it or change the harness.

**The point of these runs is what stayed healthy**, not what broke. Give the certificate state and the check output the same care the failure gets — they are the evidence that this is a different cause from expiry.
