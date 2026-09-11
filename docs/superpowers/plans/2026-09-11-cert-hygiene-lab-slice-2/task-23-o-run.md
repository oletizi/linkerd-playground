# Task 23: O

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** A valid `09-identity-outage` run at the control's harness tree.

**Files:**
- Create (evidence, committed): `demos/cert-hygiene/runs/09-identity-outage/<UTC>/`
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: Task 20's run procedure and valid control at tree `H`.
- Produces: run `O`, `evidence_valid=yes` at `H`. Task 29 reads it.

- [ ] **Step 1: Run it**

Follow Task 20 Step 1 with `S=09-identity-outage`. It takes about an hour: a 10-minute lead, the 15-minute outage, then the stages.

Sanity checks before committing:
- `grep -E ' (fault-identity-down|applied|recover-identity-up|identity-pod|stage|restart|done)' runs/09-identity-outage/<stamp>/timeline.log` shows the outage, `applied probe-new` during it, `recover-identity-up`, an `identity-pod … uid=…` line, `stage stage1-norestart …` before `restart stage2-client-a …`, and `done`.
- `grep -h 'deploy linkerd/linkerd-identity' runs/09-identity-outage/<stamp>/controlplane/post-1.txt` shows `replicas=0`.
- `head -n 3 runs/09-identity-outage/<stamp>/credential-plan.txt` shows `result=ok` and a single `observed 1:` line.

README status: replace the bullet's last two sentences with: `The issuer experiment has been repeated twice; the webhook and identity-outage experiments have been run. Write-ups are pending; the other experiment runs are next.` Commit with the run.
