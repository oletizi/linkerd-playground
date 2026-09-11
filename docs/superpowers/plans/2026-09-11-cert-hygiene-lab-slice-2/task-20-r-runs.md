# Task 20: R, twice

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** Two valid `05-issuer-expiry` runs at the control's harness tree. Design § 2: a second clean run is worth more than more prose about one run.

**Files:**
- Create (evidence, committed): two `demos/cert-hygiene/runs/05-issuer-expiry/<UTC>/` directories
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: Task 19's run procedure and valid control at tree `H`.
- Produces: runs `RA` and `RB` (their stamps; named so they can't be confused with hypotheses R1–R4), each `evidence_valid=yes` at `H`. Task 26 reads both.

- [ ] **Step 1: First run**

Follow Task 19 Step 1 with `S=05-issuer-expiry`. It takes about an hour and a quarter.

Sanity checks before committing (the run's own records, not judgements):
- `grep -E ' (t_mark|recover-apply|issuer-updated|restart|gate|done)' runs/05-issuer-expiry/<stamp>/timeline.log` shows, in order: `t_mark`, `recover-apply`, `issuer-updated`, `restart stage2-client-a …`, `gate stage2-client-a …`, the same for `stage3-server` and `stage4-all`, then `done`.
- `head -n 4 runs/05-issuer-expiry/<stamp>/credential-plan.txt` shows `result=ok`, then `declared: plan A/I1 A/I2`, then `observed 1:` and `observed 2:`.
- `bash scripts/gate-table.sh runs/05-issuer-expiry/<stamp>` lists four stages.

README status: in the "Second round of lab experiments" bullet, replace its last sentence with: `The repeat of the issuer experiment has been recorded once; the second recording is next. Nothing from this round is a finding yet.` Commit with the run.

- [ ] **Step 2: Second run**

Follow Task 19 Step 1 again with `S=05-issuer-expiry`. Apply the same sanity checks.

README status: replace that sentence with: `The issuer experiment has been repeated twice; its write-up is pending. The other experiment runs are next.` Commit with the run.
