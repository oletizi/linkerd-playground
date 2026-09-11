# Task 21: W, Ignore and Fail

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 2: no harness changes** except under the Phase 2 rule in the README.

**Goal:** A valid `02-webhook-expiry-ignore` run and a valid `02-webhook-expiry-fail` run at the control's harness tree.

**Files:**
- Create (evidence, committed): `demos/cert-hygiene/runs/02-webhook-expiry-ignore/<UTC>/`, `demos/cert-hygiene/runs/02-webhook-expiry-fail/<UTC>/`
- Modify: `docs/articles/cert-hygiene/README.md` (status)

**Interfaces:**
- Consumes: Task 19's run procedure and valid control at tree `H`.
- Produces: runs `WI` and `WF`, each `evidence_valid=yes` at `H`. Task 27 reads both.

- [ ] **Step 1: Ignore**

Follow Task 19 Step 1 with `S=02-webhook-expiry-ignore`. It takes about an hour and a quarter (15 minutes to the first expiry, then 30 minutes, then recovery).

Sanity checks before committing:
- `head -n 6 runs/02-webhook-expiry-ignore/<stamp>/admission-baseline.txt` starts `result=ok` with five `ok:` lines.
- `grep ' webhook-expired ' runs/02-webhook-expiry-ignore/<stamp>/timeline.log` shows three lines, for `proxyInjector`, `policyValidator` and `profileValidator`, about 10 minutes apart.
- `ls runs/02-webhook-expiry-ignore/<stamp>/admission/` shows `baseline`, `pre-expiry`, several `post-NNNN` and `recovered`.
- `head -n 1 runs/02-webhook-expiry-ignore/<stamp>/recover/branch.txt` prints `branch=i`, `branch=ii` or `branch=iii`; for ii and iii, `recover/supplied-facts.txt` exists.
- `grep -c 'redacted' runs/02-webhook-expiry-ignore/<stamp>/recover/plain-manifest.yaml` prints at least 1.

README status: replace the bullet's last two sentences with: `The issuer experiment has been repeated twice, and the webhook experiment has been run with Linkerd's default failure policy. Write-ups are pending; the other experiment runs are next.` Commit with the run.

- [ ] **Step 2: Fail**

Follow Task 19 Step 1 with `S=02-webhook-expiry-fail`. Apply the same sanity checks. `webhooks/baseline.txt` must show `failurePolicy=Fail` on all three `config` lines.

README status: replace `and the webhook experiment has been run with Linkerd's default failure policy` with `and the webhook experiment has been run with each failure policy`. Commit with the run.
