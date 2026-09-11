# Task 24: K

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** A valid `20-check-threshold` run at the control's harness tree. K needs no control of its own, but it runs at the same tree as everything else.

**Files:**
- Create (evidence, committed): `demos/cert-hygiene/runs/20-check-threshold/<UTC>/` (a second one only under Step 2)
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: Task 20's run procedure.
- Produces: run `K`, `evidence_valid=yes` at `H`. Task 30 reads it.

- [ ] **Step 1: Run it**

Follow Task 20 Step 1 with `S=20-check-threshold`. It takes about 10 minutes: the reset, then two measurements.

Sanity checks before committing:
- `cat runs/20-check-threshold/<stamp>/k-remaining.txt` starts `result=ok`, with four `ok:` lines (minus and plus, `check` and `check_proxy`).
- `grep -h 'issuer cert is valid for at least 60 days' runs/20-check-threshold/<stamp>/k/*-check.txt` prints one line per transcript.
- `head -n 4 runs/20-check-threshold/<stamp>/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 A/I2`, `observed 1:` and `observed 2:`.

README status: replace the bullet's last two sentences with: `The issuer experiment has been repeated twice; the webhook, identity-outage and linkerd check threshold experiments have been run. Write-ups are pending; the trust-anchor experiments are next.` Commit with the run.

- [ ] **Step 2: Only if `k-remaining.txt` says `result=fail`**

That is "that step is repeated" (design § 5; Task 14 explains why the repeat is a fresh run). Commit the invalid run (Task 20 Step 1.5), then follow Task 20 Step 1 once more with the same scenario. If the second run also fails its `k-remaining` rule, stop and report both runs' `k/*-calc.txt` to the user.
