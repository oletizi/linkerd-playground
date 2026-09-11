# Task 26: S-staged and S-hard

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** A valid `07-anchor-rotation-staged` run and a valid `08-anchor-rotation-hard` run at the control's harness tree.

**Files:**
- Create (evidence, committed): `demos/cert-hygiene/runs/07-anchor-rotation-staged/<UTC>/`, `demos/cert-hygiene/runs/08-anchor-rotation-hard/<UTC>/`
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: Task 20's run procedure and valid control at tree `H`.
- Produces: runs `SS` and `SH`, each `evidence_valid=yes` at `H`. Task 32 reads both.

- [ ] **Step 1: S-staged**

Follow Task 20 Step 1 with `S=07-anchor-rotation-staged`. It takes under an hour: a 10-minute lead, then 11 steps with three gated restarts.

Sanity checks before committing:
- `grep -E ' s[0-9]{2} ' runs/07-anchor-rotation-staged/<stamp>/timeline.log` shows `s01` to `s11` in order.
- `bash scripts/gate-table.sh runs/07-anchor-rotation-staged/<stamp>` lists `s04-restart`, `s08-restart` and `s11-restart`.
- `head -n 6 runs/07-anchor-rotation-staged/<stamp>/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 A+B/I1 A+B/I2 B/I2` and four observed states.
- `tail -n 1` of `steps/s03-upgrade.txt`, `steps/s07-upgrade.txt` and `steps/s10-upgrade.txt` each print `[exit 0]`. If one doesn't, the run is still committed, but record it: the guide's step failed in the lab, which Task 32 must report.

README status: replace the bullet's last two sentences with: `The issuer experiment has been repeated twice; the webhook, identity-outage, linkerd check threshold, trust-anchor expiry and staged trust-anchor rotation experiments have been run. Write-ups are pending; the one-step trust-anchor replacement is next.` Commit with the run.

- [ ] **Step 2: S-hard**

Follow Task 20 Step 1 with `S=08-anchor-rotation-hard`. It takes under an hour.

Sanity checks before committing:
- `head -n 1 runs/08-anchor-rotation-hard/<stamp>/s-hard/stage1-condition.txt` prints `result=met`. If it prints `result=timeout`, the run is invalid under a declared rule: follow Task 20 Step 1.6, second case.
- `grep -c '^tick=' runs/08-anchor-rotation-hard/<stamp>/s-hard/stage1-condition.txt` is a multiple of 3 (three endpoints per tick).
- `bash scripts/gate-table.sh runs/08-anchor-rotation-hard/<stamp>` lists `stage1-norestart` (`gate=none`) and the three restart stages.

README status: replace the bullet with:

```markdown
- **Second round of lab experiments** (webhook certificates, identity outage, `linkerd check` threshold, trust-anchor expiry and rotation, and a repeat of the issuer experiment): every experiment has been run. The write-ups are in progress; until each is done, its results are not findings.
```

Commit with the run.
