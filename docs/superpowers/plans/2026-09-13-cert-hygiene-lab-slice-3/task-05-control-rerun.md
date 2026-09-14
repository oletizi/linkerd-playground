# Task 5: Freeze the harness and record a control at the new tree

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** a valid `00-baseline-control` run at the harness tree slice 3 built. Without it, the tap run cannot be evidence: V's rule list includes `control-at-tree`, which demands a valid control recorded at the same harness tree hash.

**From here the harness does not change.** If a fault is found during a run, the fix is committed, this control is re-run, and only then the affected scenario — the same rule slice 2 followed.

**Steps:**

1. Confirm a clean tree: `git status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'` prints nothing. Commit anything outstanding first.
2. Run the full unit suite (`just demo cert-hygiene test`) and record the result. Every suite must pass.
3. Record the harness tree hash the runs will carry, so later tasks can quote it:
   `git ls-tree -r HEAD -- lib demos/cert-hygiene | awk -F '\t' '$2 !~ /^demos\/cert-hygiene\/runs\//' | shasum -a 256`
4. Launch the control: `bash scripts/run.sh 00-baseline-control` from demos/cert-hygiene — no `--discovery`, no `--short`. It takes roughly an hour and runs detached; wait with bounded foreground waits (`bash scripts/wait-run.sh <run> 540`, repeated while it times out).
5. Check the run: `validity.txt` is exactly `evidence_valid=yes`; `control-criteria.txt` says `result=ok`; the gate table shows the four stages with every cell classified and no failures; `git-state.txt`'s `harness_tree_sha256` matches step 3.
6. Publish it: `bash tools/evidence-upload.sh <run-dir>`, then `bash tools/evidence-verify.sh <run-dir>` (which fetches it back through the CDN and compares against the local copy), then commit the manifest, remove the local run directory, and attach the archive to the evidence release with `gh release upload cert-hygiene-evidence-2026-09-13 <archive>`.
7. If the control is invalid, publish and commit it anyway, then stop and report: an invalid control blocks every timed scenario, and the controller decides what happens next.
8. Report the tree hash prominently — Tasks 6 and 7 quote it.
