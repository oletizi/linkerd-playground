# Task 25: A

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** A valid `06-anchor-expiry` run at the control's harness tree.

**Files:**
- Create (evidence, committed): `demos/cert-hygiene/runs/06-anchor-expiry/<UTC>/`
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: Task 20's run procedure and valid control at tree `H`.
- Produces: run `A`, `evidence_valid=yes` at `H`. Task 31 reads it.

- [ ] **Step 1: Run it**

Follow Task 20 Step 1 with `S=06-anchor-expiry`. It takes about an hour and a half: 20 minutes to the anchor's expiry, the 30-minute window, then the named stages (stage 3 only if needed).

Sanity checks before committing:
- `grep -E ' (t_mark|a-stage[0-9]|a-canary|restart|gate|done)' runs/06-anchor-expiry/<stamp>/timeline.log` shows `a-stage1-apply`, `a-stage2`, `a-canary` lines, an `a-stage3 …` line (run or "not needed"), `restart a-stage4 …`, `gate a-stage4 …`, `a-stage5`, and `done`.
- `tail -n 1 runs/06-anchor-expiry/<stamp>/recover/linkerd-upgrade.txt` prints `[exit 0]`.
- `head -n 4 runs/06-anchor-expiry/<stamp>/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 B/I2` and two observed states.

README status: replace the bullet's last two sentences with: `The issuer experiment has been repeated twice; the webhook, identity-outage, linkerd check threshold and trust-anchor expiry experiments have been run. Write-ups are pending; the trust-anchor rotation experiments are next.` Commit with the run.
