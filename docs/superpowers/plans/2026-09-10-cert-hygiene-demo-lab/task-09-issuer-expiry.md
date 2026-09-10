# Task 9: Scenario #5, issuer expiry

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** Implement `05-issuer-expiry`: the shared timeline with a short issuer, plus the recover phase from spec § 4.3. Then run it with a valid control at the **same harness tree** and commit a run whose `validity.txt` says `evidence_valid=yes`.

**Recovery procedure (source):** Linkerd's [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/) is the one [Replacing expired certificates](https://linkerd.io/2-edge/tasks/replacing_expired_certificates/) points to for the issuer-only case. It applies a new issuer with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… | kubectl apply -f -`. It passes **no** trust-anchor flag and uses no `--force`. It then says to restart the proxies of all injected workloads.

H8 predicts that restart is unnecessary, so the harness restarts only in recorded escalation stages, and only if recovery hasn't happened on its own:
1. Wait `RECOVER_WINDOW_S` with no restarts.
2. Restart the two workloads that never became Ready (`probe-new`, `restart-target`).
3. Restart every lab Deployment, as the guide says.

**Files:**
- Create: `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`
- Create (evidence, committed): `demos/cert-hygiene/runs/00-baseline-control/<UTC>/` (a re-run at this harness tree) and `demos/cert-hygiene/runs/05-issuer-expiry/<UTC>/`

**Interfaces:**
- Consumes: `lab/scenario-common.sh` (`run_scenario`, `post_expiry_hook`, `CERTS`, `LAB_NS`); the collector (`mark`, `capture`, `tick`, `snap_secret`, `snap_events`, `write_cert`); `lib/certs.sh` (`make_issuer`); `lib-evidence.sh` (`cert_not_after_epoch`); `scripts/run.sh` and `scripts/wait-run.sh` (Task 8)
- Produces these evidence names:
  - `certs/issuer-replacement.{pem,txt}`
  - `recover/linkerd-upgrade.txt`, and `recover/restart-stage{1,2}.txt` when used
  - recovery ticks `recover-N`, `recover-s1-N`, `recover-s2-N` (each with pod detail and `secrets/<tick>-identity-issuer.txt`)
  - timeline markers `recover-apply`, `issuer-updated`, `restart`, `recovered`, `recovery`
  - `events/issuer-updated.txt`

- [ ] **Step 1: Write `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`**

```bash
#!/usr/bin/env bash
# Scenario #5 (design spec section 4): the identity issuer expires mid-run while the
# trust anchor and its key stay valid. T_mark is the issuer's notAfter. Recovery signs
# a replacement issuer from the SAME anchor and applies it the documented way; restarts
# happen only in recorded stages, and only if recovery has not happened on its own.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  cert_not_after_epoch "$CERTS/issuer.crt"
}

_recovered_now() { # new-connection probes ok, and both post-expiry workloads rolled out.
  # The stream probe is excluded: it fails closed, so once its connection is gone it
  # never reports ok again, by design.
  local p
  for p in probe-http probe-tcp-new; do
    kubectl -n "$LAB_NS" logs "deploy/$p" -c probe --tail=1 2>/dev/null \
      | grep -qE ' seq=[0-9]+ ok( |$)' || return 1
  done
  kubectl -n "$LAB_NS" rollout status deploy/restart-target --timeout=1s >/dev/null 2>&1 || return 1
  kubectl -n "$LAB_NS" rollout status deploy/probe-new --timeout=1s >/dev/null 2>&1 || return 1
}

_recover_ticks() { # PREFIX TIMEOUT_S: tick until recovered (return 0) or timed out (return 1)
  local prefix="$1" deadline=$(( $(date -u +%s) + $2 )) n=1
  while :; do
    tick "$prefix-$n"
    post_expiry_hook "$prefix-$n"
    snap_secret "$prefix-$n"
    if _recovered_now; then mark recovered "at tick $prefix-$n"; return 0; fi
    [ "$(date -u +%s)" -lt "$deadline" ] || return 1
    n=$((n + 1))
    sleep "$OBSERVE_INTERVAL_S"
  done
}

_wait_issuer_updated() { # TIMEOUT_S: record when (or whether) identity reloaded the issuer
  local t0 deadline
  t0="$(date -u +%s)"
  deadline=$(( t0 + $1 ))
  until kubectl -n linkerd get events --field-selector reason=IssuerUpdated -o name 2>/dev/null | grep -q .; do
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
      mark issuer-updated "no IssuerUpdated event within ${1}s"
      return 0
    fi
    sleep 5
  done
  mark issuer-updated "IssuerUpdated event seen $(( $(date -u +%s) - t0 ))s after apply"
}

scenario_recover() {
  local rep="$CERTS/replacement"
  # Invariant (spec 4.3): the replacement is signed by the EXISTING anchor, and
  # nothing here touches the trust roots. trust/*.txt snapshots verify it.
  make_issuer "$rep" "$REPLACEMENT_ISSUER_LIFETIME" "$CERTS"
  write_cert issuer-replacement "$rep/issuer.crt"
  mark recover-apply "linkerd upgrade with the replacement issuer; no trust-anchor flag"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$rep/issuer.crt' --identity-issuer-key-file='$rep/issuer.key' | kubectl apply -f -"
  _wait_issuer_updated 180
  snap_events issuer-updated

  if _recover_ticks recover "$RECOVER_WINDOW_S"; then
    mark recovery "no workload restarts"
    return 0
  fi
  mark restart "stage 1: the workloads that never became Ready (probe-new, restart-target)"
  capture recover/restart-stage1.txt kubectl -n "$LAB_NS" rollout restart deploy/probe-new deploy/restart-target
  if _recover_ticks recover-s1 "$RECOVER_WINDOW_S"; then
    mark recovery "after stage-1 restarts"
    return 0
  fi
  mark restart "stage 2: every lab Deployment, as Linkerd's issuer-rotation guide directs"
  capture recover/restart-stage2.txt kubectl -n "$LAB_NS" rollout restart deploy
  if _recover_ticks recover-s2 "$RECOVER_WINDOW_S"; then
    mark recovery "after stage-2 restarts"
    return 0
  fi
  mark recovery "not recovered after stage-2 restarts"
}

run_scenario 05-issuer-expiry short "${1:?usage: 05-issuer-expiry.sh <run-dir>}"
```

- [ ] **Step 2: Syntax-check and shellcheck**

Run: `cd demos/cert-hygiene && bash -n scenarios/05-issuer-expiry.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/05-issuer-expiry.sh'`
Expected: no output.

- [ ] **Step 3: Commit the scenario BEFORE any run**

Adding this file changes the harness tree hash. The control from Task 8 no longer matches, so the control is re-run in Step 4.

```bash
git add demos/cert-hygiene/scenarios/05-issuer-expiry.sh
git commit -m "cert-hygiene add issuer-expiry scenario"
git push
git status --porcelain -- lib demos/cert-hygiene
```
Expected: the last command prints nothing.

- [ ] **Step 4: Re-run the control at this harness tree**

Run: `just demo cert-hygiene run 00-baseline-control`, then `just demo cert-hygiene wait runs/00-baseline-control/<stamp>` (repeat the wait if the tool's time limit ends it).
Expected: `evidence_valid=yes`. If it is not, follow Task 8 Step 11 and don't start #5.

Commit it straight away:

```bash
git add demos/cert-hygiene/runs/00-baseline-control
git commit -m "cert-hygiene record negative control at the issuer-expiry harness tree"
git push
```

This commit touches only `runs/`, so the harness tree is unchanged.

- [ ] **Step 5: Run scenario #5**

Run: `just demo cert-hygiene run 05-issuer-expiry`
Expected: the last line is `runs/05-issuer-expiry/<stamp>`.

While it runs, `tail -n 5 demos/cert-hygiene/runs/05-issuer-expiry/<stamp>/timeline.log` shows the phases in order:
- `reset`, `t_mark`, `tick baseline`, `tick pre-N`
- the `fault-*` ticks
- `applied probe-new`, `rolled restart-target`, `tick post-N`
- `recover`, `recover-apply`, `issuer-updated`, `tick recover-N`, a `recovery …` line
- `tick verify`, `done`

Wait with `just demo cert-hygiene wait runs/05-issuer-expiry/<stamp>`, repeating as needed.
Expected: exit 0, `done`, `evidence_valid=yes`.

- [ ] **Step 6: If the run is not valid, diagnose — never edit evidence**

Read `validity.txt` and `harness.log`. An invalid #5 run is still committed (Step 7). Fix the harness and commit. Because the fix changes the harness tree, repeat Steps 4–5: a new control first, then a new #5.

**Validity is not the same as outcome.** A run in which recovery never happens, or where any hypothesis is falsified, can still be `evidence_valid=yes`. That is a finding, not a failure. Don't "fix" the harness to make a hypothesis come true.

- [ ] **Step 7: Check size and keys, update the README, and commit the evidence**

Run: `du -sh demos/cert-hygiene/runs/05-issuer-expiry/* && (grep -rl 'PRIVATE KEY' demos/cert-hygiene/runs || echo none)`
Expected: `none`. If any run directory exceeds 20M, report its largest files to the user before committing.

In `docs/articles/cert-hygiene/README.md`:
- Set the `#5 Issuer expiry` row to `Valid run: demos/cert-hygiene/runs/05-issuer-expiry/<stamp>; observations pending (plan Task 10)`.
- Update the `Baseline control` row to the Step 4 run.
- Set the `Lab harness` row to `Built; #5 evidence recorded (plan Task 9 of 10)`.

```bash
git add demos/cert-hygiene/runs/05-issuer-expiry docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record issuer-expiry run"
git push
```
