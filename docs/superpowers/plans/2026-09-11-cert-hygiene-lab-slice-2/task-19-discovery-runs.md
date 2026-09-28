# Task 19: Discovery runs of the new scenarios, and of R

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 1:** harness changes are still allowed here; this is the last task before the freeze.

**Goal:** Before any evidence run, run each of the six new scenarios once, and R once, end to end as discovery runs with shortened observation windows, and apply the Phase 2 sanity checks to each.

Only the control has been smoke-run so far (Task 9). A bug first found in Phase 2 would force a new control run of about an hour and a quarter at every fix. Here it costs only a commit and a repeat of the affected discovery run.
- **R is included** because its recovery was rewritten in Task 10: the `recover-apply` and `wait_issuer_updated` path, followed by the gated stages. It would otherwise first run in Phase 2.
- **Both W scenario files run**, because their admission and recovery paths differ: Fail rejects what Ignore lets through.

That makes eight runs.

**Discovery runs are never evidence** (design "Discovery versus evidence runs"):
- `scripts/run.sh --discovery --short` puts each run under `runs/_discovery/<UTC>-<scenario>/` with `discovery.txt`, and `evaluate_validity` always writes `evidence_valid=no` with `reason=discovery run: never evidence` (Tasks 3, 8).
- `--short` lowers `POST_EXPIRY_WINDOW_S` to 420 s, `RECOVER_WINDOW_S` to 120 s and `W_POST_WINDOW_S` to 120 s, never raising a value. The lowered values are recorded in `discovery-windows.txt`, a `discovery-windows` timeline marker and `versions.txt`. Evidence runs refuse the override (Task 9).
- Profile lifetimes are not shortened, so R still takes 15 minutes to its issuer's expiry, W 35 minutes to its last expiry and A 20 minutes to its anchor's.

**Files:**
- Create (discovery, committed): eight `demos/cert-hygiene/runs/_discovery/<UTC>-<scenario>/` runs, and `demos/cert-hygiene/runs/_discovery/<UTC>-scenario-smoke/FINDINGS.md`
- Create (not committed; `.lab-logs/` is git-ignored): `demos/cert-hygiene/.lab-logs/check-not-scraped.sh`
- Modify: harness files only if a check reveals a harness fault (then commit, and repeat the affected runs)

**Interfaces:**
- Consumes: the Phase 1 harness (Tasks 1–18), the Task 18 helpers (`S=demos/cert-hygiene/scripts`).
- Produces: a harness that has run every scenario end to end, and a FINDINGS file listing each run and its check results. Task 20 freezes that harness.

- [ ] **Step 1: Commit and confirm a clean tree**

Run: `just demo cert-hygiene test`, expecting six `PASS:` lines. Then `git status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'`, which must print nothing (commit first if it does).

- [ ] **Step 2: The discovery-run procedure (used for each scenario below)**

For a scenario `X`, from `demos/cert-hygiene`:
1. `bash scripts/run.sh --discovery --short X`. The last line is `runs/_discovery/<stamp>-X`; call it `D`.
2. `bash scripts/wait-run.sh $D 540`, repeated while it exits 124.
3. Common checks:
   - `timeline.log` ends `done`. Its first line is `discovery discovery run, never evidence: discovery=yes short_windows=yes`, and a `discovery-windows` marker follows.
   - `cat $D/discovery-windows.txt` starts `short_windows=applied`.
   - `cat $D/validity.txt` shows `evidence_valid=no`, with only these reasons:
     - `reason=discovery run: never evidence`;
     - for every scenario except `20-check-threshold`, `reason=no valid 00-baseline-control run with harness tree …` (no evidence control exists yet);
     - a declared validity rule that failed because of Linkerd's own behaviour (item 6, second case).

     Any other reason is a harness fault.
   - `(grep -rl 'PRIVATE KEY' $D || echo none)` prints `none`.
4. The scenario's own checks (Steps 3–10).
5. Commit the run at once, whatever its result: `git add runs/_discovery`, `git commit -m "cert-hygiene record discovery run of X"`, `git push`.
6. **If a check fails, or `validity.txt` has another reason:** read `harness.log` and the files the check or reason names. Then:
   - *A harness fault* (a collector bug, a missing artifact the harness should have written, a command built wrongly): fix the harness and commit the fix (`cert-hygiene fix <what> found by the X discovery run`). Repeat this procedure for `X`, and for every scenario already run whose code path the fix touches.
   - *A declared validity rule that failed because of Linkerd's own behaviour* (S-hard's stage 1 timing out, W's plain upgrade failing for Linkerd's own reasons, or K's remaining-validity rule): record it in the FINDINGS (Step 11) and repeat this procedure for `X` once. If it happens again, stop and report both runs to the user. Don't change the harness around it.

   Keep every run.

- [ ] **Step 3: `05-issuer-expiry`** (about 35 minutes)

- `grep -E ' (t_mark|recover-apply|issuer-updated|restart|gate|done)' $D/timeline.log` shows, in order: `t_mark`, `recover-apply`, `issuer-updated`, `restart stage2-client-a …`, `gate stage2-client-a …`, the same for `stage3-server` and `stage4-all`, then `done`.
- `tail -n 1 $D/recover/linkerd-upgrade.txt` prints `[exit 0]`; `controlplane/recover-applied.txt` exists.
- `head -n 4 $D/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 A/I2`, `observed 1:` and `observed 2:`.
- `bash $S/gate-table.sh $D` lists `stage1-norestart` (`gate=none`), `stage2-client-a`, `stage3-server` and `stage4-all`, each with two `cell` lines.

- [ ] **Step 4: `02-webhook-expiry-ignore`** (about an hour)

- `head -n 6 $D/admission-baseline.txt` starts `result=ok` with five `ok:` lines.
- `grep ' webhook-expired ' $D/timeline.log` shows three lines (`proxyInjector`, `policyValidator`, `profileValidator`) about 10 minutes apart. Each names `first tick starting after it: <tick>, started <UTC>`, with a start time after that certificate's `notAfter`.
- `ls $D/admission/` shows `baseline`, `pre-expiry`, several `post-NNNN` and `recovered`.
- The time from the last `webhook-expired` marker to `recover-delete` is about the lowered `W_POST_WINDOW_S` (120 s) plus at most one tick interval. The post window therefore ends at T3 plus W's window.
- `head -n 1 $D/recover/plain-render.txt` shows `$ bash -o pipefail -c linkerd upgrade > …` with no `''` after `upgrade`. `tail -n 1` of `plain-render.txt` and `plain-apply.txt` each print `[exit 0]`, and `grep -c redacted $D/recover/plain-manifest.yaml` is at least 4.
- `head -n 1 $D/recover/branch.txt` prints `branch=i`, `branch=ii` or `branch=iii`; for ii and iii, `recover/supplied-facts.txt` exists.
- **Proxy-less pods are listed, not scraped.** An `inject-probe` pod admitted without a proxy appears in a tick's metrics only if that tick ran before its deletion. If it does, its section must carry `[no linkerd-proxy container: not scraped]`, not fetch retries; no such section at all is fine. Write this check script with the Write tool at `demos/cert-hygiene/.lab-logs/check-not-scraped.sh`:

  ```bash
  #!/usr/bin/env bash
  # Task 19 check: every proxy-less inject-probe pod that appears in a tick's metrics is
  # listed as "not scraped" rather than retried. Runs on the host; only reads.
  # Usage: check-not-scraped.sh <run-dir>
  set -euo pipefail
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/common.sh"
  run="${1:?usage: check-not-scraped.sh <run-dir>}"
  bad=0; listed=0
  for obs in "$run"/admission/*/inject-probe-*.observed.yaml; do
    [ -f "$obs" ] || continue
    if grep -q 'name: linkerd-proxy$' "$obs"; then continue; fi
    [ "$(tail -n 1 "$obs")" = "[exit 0]" ] || continue
    pod="$(basename "$obs" .observed.yaml)"
    for m in "$run"/metrics/*.txt; do
      next="$(awk -v h="== lab/$pod :4191" '$0 == h { getline; print; exit }' "$m")"
      [ -n "$next" ] || continue
      listed=$((listed + 1))
      if [ "$next" != "[no linkerd-proxy container: not scraped]" ]; then
        echo "not marked: $pod in $m: $next"; bad=1
      fi
    done
  done
  echo "proxy-less pod sections checked: $listed"
  exit "$bad"
  ```

  Run: `bash .lab-logs/check-not-scraped.sh $D`. Expected: `proxy-less pod sections checked: N` (N may be 0) and exit 0.

- [ ] **Step 5: `02-webhook-expiry-fail`** (about an hour)

Apply the Step 4 checks, except the proxy-less-pod check: under Fail, `inject-probe` pods are rejected after T1, so none is admitted without a proxy. In addition, `grep failurePolicy $D/webhooks/baseline.txt` must show `failurePolicy=Fail` on all three `config` lines.

- [ ] **Step 6: `09-identity-outage`** (about 30 minutes)

- `grep -E ' (fault-identity-down|applied|recover-identity-up|identity-pod|stage|restart|done)' $D/timeline.log` shows, in order:
  - the outage;
  - `applied probe-new` during it;
  - `recover-identity-up`, and an `identity-pod … uid=…` line;
  - `stage stage1-norestart …` before `restart stage2-client-a …`;
  - `done`.
- `grep -h 'deploy linkerd/linkerd-identity' $D/controlplane/post-1.txt` shows `replicas=0`.
- `head -n 3 $D/credential-plan.txt` shows `result=ok` and a single `observed 1:` line.
- `grep POST_EXPIRY_WINDOW_S $D/discovery-windows.txt` shows `420`, above the 320 s leaf window.

- [ ] **Step 7: `20-check-threshold`** (about 10 minutes; nothing to shorten)

- `cat $D/k-remaining.txt` starts `result=ok` with four `ok:` lines. A `result=fail` here is the second case of Step 2 item 6.
- `grep -h 'issuer cert is valid for at least 60 days' $D/k/*-check.txt` prints one line per transcript.
- `head -n 4 $D/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 A/I2`, `observed 1:` and `observed 2:`.

- [ ] **Step 8: `06-anchor-expiry`** (about 45 minutes)

- `grep -E ' (t_mark|a-stage[0-9]|a-canary|restart|gate|done)' $D/timeline.log` shows, in order:
  - `a-stage1-apply`, then `a-stage2`;
  - `a-canary` lines, and an `a-stage3 …` line (run or "not needed");
  - `restart a-stage4 …`, `gate a-stage4 …`, then `a-stage5`;
  - `done`.
- `tail -n 1 $D/recover/linkerd-upgrade.txt` prints `[exit 0]`.
- `cat $D/recover/a-stage2-canary-*-state.txt` shows `state=` lines. The `a-canary` marker that ends a stage reads either `Ready with a new-anchor leaf` with `proxy=yes`, or `not proven`; never Ready without a proxy.
- `head -n 4 $D/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 B/I2` and two observed states.

- [ ] **Step 9: `07-anchor-rotation-staged`** (about 25 minutes)

- `grep -E ' s[0-9]{2} ' $D/timeline.log` shows `s01` to `s11` in order.
- `bash $S/gate-table.sh $D` lists `s04-restart`, `s08-restart` and `s11-restart`, each with its cells.
- `head -n 6 $D/credential-plan.txt` shows `result=ok`, `declared: plan A/I1 A+B/I1 A+B/I2 B/I2` and four observed states.
- `tail -n 1` of `steps/s03-upgrade.txt`, `steps/s07-upgrade.txt` and `steps/s10-upgrade.txt` each print `[exit 0]`. A non-zero exit is recorded as a finding for Task 32, not fixed in the harness, unless `harness.log` shows the harness built the command wrongly.

- [ ] **Step 10: `08-anchor-rotation-hard`** (about 25 minutes)

- `head -n 1 $D/s-hard/stage1-condition.txt` prints `result=met`. A `result=timeout` is the second case of Step 2 item 6.
- `grep -c '^tick=' $D/s-hard/stage1-condition.txt` is a multiple of 3.
- `bash $S/gate-table.sh $D` lists `stage1-norestart` (`gate=none`) and the three restart stages.

- [ ] **Step 11: Record the smoke results and commit**

Write `demos/cert-hygiene/runs/_discovery/<stamp>-scenario-smoke/FINDINGS.md` with the Write tool. It records:
- one heading per scenario, with its discovery run or runs and their directories;
- each check's result, quoting the lines;
- every harness fix made, with its commit;
- every declared rule that failed because of Linkerd's own behaviour, and the result of the repeat;
- the final harness commit (`git log -1 --format=%H`).

The `02-webhook-expiry-ignore` not-scraped check (Step 4) is best-effort: by construction it may find zero proxy-less pod sections (`N` in `proxy-less pod sections checked: N` can legitimately be `0`, since an `inject-probe` pod only lands in a tick's metrics if that tick happened to run before the pod's deletion). Record `check-not-scraped.sh`'s output whatever `N` is; treat `N=0` as "the check found nothing to exercise it", never as proof the rule holds.

Behaviour the checks reveal about Linkerd (for example the W branch, or whether the canary needed stage 3) is recorded as seen and never judged: these runs are not evidence.

```bash
git add demos/cert-hygiene/runs/_discovery
git commit -m "cert-hygiene record discovery runs of every new scenario and R"
git push
```
