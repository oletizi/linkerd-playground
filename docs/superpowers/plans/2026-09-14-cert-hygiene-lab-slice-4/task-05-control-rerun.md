# Task 5: Freeze the harness and record a control at the new tree

Part of the [slice 4 plan](README.md). Read its Global Constraints first.

**Goal:** a valid `00-baseline-control` run at the harness tree slice 4 built. N and G both carry `control-at-tree`, so without it neither run is evidence.

**From here the harness does not change.** If a fault is found during a run, the fix is committed, this control is re-run, and only then the affected scenario.

**Steps:**

1. Confirm a clean tree: `git status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'` prints nothing.
2. Run the full unit suite (`just demo cert-hygiene test`). Every suite must pass.
3. Record the harness tree hash the runs will carry, so later tasks can quote it:
   `git ls-tree -r HEAD -- lib demos/cert-hygiene | awk -F '\t' '$2 !~ /^demos\/cert-hygiene\/runs\//' | shasum -a 256`
4. Launch the control: `bash scripts/run.sh 00-baseline-control` from demos/cert-hygiene — no `--discovery`, no `--short`. About an hour, detached, waited out with bounded foreground waits (`bash scripts/wait-run.sh <run> 540`, repeated while it times out).
5. Check the run: `validity.txt` is exactly `evidence_valid=yes`; `control-criteria.txt` says `result=ok`; the gate table shows every stage with every cell classified and no failures; `git-state.txt`'s `harness_tree_sha256` matches step 3.
6. Publish it: `KEEP_ARCHIVE=1 bash tools/evidence-upload.sh <run-dir>`, then `bash tools/evidence-verify.sh <run-dir>`, then commit the manifest and attach the archive to the evidence release with `gh release upload`.

   **Task 1 changed how `control-at-tree` finds the control.** It now reads committed manifests, so the local copy is no longer load-bearing. Verify that yourself before relying on it: after committing the manifest, move the run directory aside, confirm a scenario's validity check still finds the control, and move it back. Report how you confirmed it. If it does not work, say so — that is a Task 1 defect and the controller decides.
7. If the control is invalid, publish and commit it anyway, then stop and report: an invalid control blocks every timed scenario.
8. Report the tree hash prominently — Tasks 6 and 7 quote it.
