# Task 20: Freeze the harness; run the control

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** Confirm the harness is complete and committed, and record a valid `00-baseline-control` run at that harness tree (design "Discovery versus evidence runs", steps 1–3). Every later evidence run needs a valid control at the same tree. This task also defines the run procedure every Phase 2 task follows.

**Files:**
- Create (evidence, committed): `demos/cert-hygiene/runs/00-baseline-control/<UTC>/`
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: the Phase 1 harness (Tasks 1–19), including its discovery runs.
- Produces: a valid control at harness tree `H`, where `H` is its `git-state.txt` `harness_tree_sha256`. Every Phase 2 run must carry the same `H`.

- [ ] **Step 1: The run procedure (every Phase 2 task uses it)**

For a scenario `S`, from the repo root:

1. **Clean tree.** `git status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'` prints nothing, and `demos/cert-hygiene/config.local.env` does not exist. If either fails, stop: never launch an evidence run from a dirty tree.
2. **Launch detached, as an evidence run.** `cd demos/cert-hygiene && bash scripts/run.sh S`. Never pass `--discovery` or `--short` in Phase 2. The last line is `runs/S/<stamp>`.
3. **Wait in bounded foreground waits.** `bash scripts/wait-run.sh runs/S/<stamp> 540`, repeated while it exits 124. The run is detached and survives the tool's time limit.
4. **Check it.**
   - Read `validity.txt`.
   - `ls runs/S/<stamp>/discovery.txt` must fail: an evidence run has none.
   - `(grep -rl 'PRIVATE KEY' runs || echo none)` must print `none`.
   - `du -sh runs/S/<stamp>`: if it exceeds 20M, report its largest files (`du -a runs/S/<stamp> | sort -n | tail`) to the user before committing.
   - Its `git-state.txt` must have `demo_repo_dirty=false` and `harness_tree_sha256=H`.
5. **Commit immediately**, valid or not, together with the README status change the task names:
   - `git add demos/cert-hygiene/runs/S docs/articles/cert-hygiene/README.md`
   - `git commit -m "cert-hygiene record S run <stamp>"`, adding `; not valid evidence` to the message when `validity.txt` says `no`
   - `git push`

   Never edit or delete a run.
6. **If the run is not valid,** read `validity.txt`, the result files it names, and `harness.log`.
   - *A harness fault* (a collector bug, a missing artifact the harness should have written): fix the harness, commit it, confirm a clean tree, re-run the control (this task's Step 3), then re-run only the scenarios the fix affects. The new tree hash invalidates earlier controls for later runs, not the runs themselves.
   - *A declared validity rule that the lab itself failed* (for example K's +10m measurement falling under 60 days, S-hard's stage 1 timing out, or W's plain upgrade failing for Linkerd's own reasons): record it, and re-run the scenario once at the same tree. If it fails the same way again, stop and report to the user; that is a finding about the harness design.
   - **Validity is not outcome.** A valid run in which a hypothesis is falsified, recovery never happens, or a gate times out is a result, not a failure. Never change the harness to make a hypothesis come true.

README status wording must stay reader-facing: no run paths, no scenario letters or hypothesis IDs.

- [ ] **Step 2: Confirm the harness is complete and committed**

Run: `just demo cert-hygiene test`
Expected: six `PASS:` lines.

Run: `cd demos/cert-hygiene && ls scenarios/ && wc -l lab/*.sh lab/tests/*.sh scenarios/*.sh scripts/*.sh | sort -n | tail -n 5`
Expected: the nine scenario files in the README's table; no file at 300 lines or more.

Run: `git status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'` and `git log -1 --format=%H`
Expected: no output from the first. The commit is the one Task 19's FINDINGS names, or a later one that changes only `runs/` or docs.

- [ ] **Step 3: Run the control**

Follow Step 1 with `S=00-baseline-control`. The run takes about an hour and a quarter.
Expected: `evidence_valid=yes`; `control-criteria.txt` starts `result=ok`; `bash scripts/gate-table.sh runs/00-baseline-control/<stamp>` shows `gate=none` for `stage1-norestart`, `gate=pass` for the three restart stages, and every cell `fail=0`.

In `docs/articles/cert-hygiene/README.md`, replace the "Second round of lab experiments" status bullet (added in Task 1) with:

```markdown
- **Second round of lab experiments** (webhook certificates, identity outage, `linkerd check` threshold, trust-anchor expiry and rotation, and a repeat of the issuer experiment): the lab is built, and a matching run where nothing expires has been recorded. The experiment runs are next; nothing from this round is a finding yet.
```

Commit with the run (Step 1.5).
