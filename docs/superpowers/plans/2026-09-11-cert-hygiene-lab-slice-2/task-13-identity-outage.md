# Task 13: Scenario O

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 4, `09-identity-outage`, profile `long`. It is the cleanest causal test in the slice: the credentials stay exactly the same, and only the identity service's availability changes.

**Timeline.**
- T_mark is `FAULT_LEAD_S` (600 s) after the moment T_mark is computed, which leaves room for pre ticks.
- At T_mark, `scenario_fault` scales `deploy/linkerd-identity` to 0 and records the control plane before and after.
- The outage lasts `OUTAGE_S=900`, longer than a 5-minute leaf plus the 20 s skew. The post-expiry window *is* the outage: this scenario sets `POST_EXPIRY_WINDOW_S` to `OUTAGE_S`.
- The default post-actions (apply `probe-new`, roll `restart-target`) run at T_mark + 60 s, during the outage (O3).
- Recovery scales identity back to 1 and records the replica change and the new identity pod's UID and start time. Then comes `restart_stages`: its stage 1 is the `RECOVER_WINDOW_S` window with no restarts, whose samples are recorded before any restart stage (O2's evidence), followed by R's gated stages and matrix.

**Invariant.** The issuer Secret's certificate and the trust anchor stay unchanged: the single-state credential plan (`A/I1`, Task 3) enforces both. The identity configuration is recorded at every tick as `deploy linkerd/linkerd-identity … template_sha256=` in `controlplane/<tick>.txt` (Task 5). Scaling does not change the pod template, so the write-up checks that every tick carries one value (design § 13).

**Files:**
- Create: `demos/cert-hygiene/scenarios/09-identity-outage.sh`
- Modify: `demos/cert-hygiene/config.example.env` (`OUTAGE_S`, `FAULT_LEAD_S`)

**Interfaces:**
- Consumes: Task 9 hooks and `run_scenario`, Task 8 `restart_stages`, Task 5 `snap_controlplane`.
- Produces (evidence names Task 28 reads): `fault/scale-down.txt`, `fault/identity-gone.txt`, `controlplane/fault-before.txt`, `controlplane/fault-after.txt`, `recover/scale-up.txt`, `recover/rollout-up.txt`, `controlplane/recover-identity-up.txt`; timeline markers `fault-identity-down`, `recover-identity-up`, `identity-pod <name> uid=<uid> start=<time>`; the four `gates/stage*.txt`.
- Config: `OUTAGE_S=900`, `FAULT_LEAD_S=600` (S-staged and S-hard reuse `FAULT_LEAD_S`).

- [ ] **Step 1: Settings in `demos/cert-hygiene/config.example.env`**

Append to the `# ---- Timing (seconds) ----` section:

```bash
# Fault-driven scenarios (O, S-staged, S-hard): observation time before the fault.
FAULT_LEAD_S=600
# O: identity outage, longer than a 5m leaf plus the 20s clock-skew allowance.
OUTAGE_S=900
```

- [ ] **Step 2: Write `demos/cert-hygiene/scenarios/09-identity-outage.sh`**

```bash
#!/usr/bin/env bash
# Scenario O (design section 4): the identity service is scaled to zero for OUTAGE_S,
# longer than a leaf's lifetime plus skew, while every credential stays unchanged. New
# workloads are created during the outage. After identity returns, a no-restart window
# is sampled first, then R's gated restart stages. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

POST_EXPIRY_WINDOW_S="$OUTAGE_S"   # the post window is the outage

scenario_mark_epoch() {
  echo $(( $(date -u +%s) + FAULT_LEAD_S ))
}

scenario_fault() {
  snap_controlplane fault-before
  mark fault-identity-down "scale deploy/linkerd-identity to 0 replicas for ${OUTAGE_S}s"
  capture fault/scale-down.txt kubectl -n linkerd scale deploy/linkerd-identity --replicas=0
  capture fault/identity-gone.txt kubectl -n linkerd wait --for=delete pod \
    -l linkerd.io/control-plane-component=identity --timeout=120s
  snap_controlplane fault-after
}

scenario_recover() {
  mark recover-identity-up "scale deploy/linkerd-identity back to 1 replica"
  capture recover/scale-up.txt kubectl -n linkerd scale deploy/linkerd-identity --replicas=1
  capture recover/rollout-up.txt kubectl -n linkerd rollout status deploy/linkerd-identity --timeout=300s
  snap_controlplane recover-identity-up
  mark identity-pod "$(kubectl -n linkerd get pod -l linkerd.io/control-plane-component=identity \
    -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} start={.status.startTime} {end}')"
  restart_stages
}

run_scenario 09-identity-outage long "${1:?usage: 09-identity-outage.sh <run-dir>}"
```

`POST_EXPIRY_WINDOW_S` is exported by `load_config`, so the reassignment is what `versions.txt` records (`config_POST_EXPIRY_WINDOW_S=900`).

- [ ] **Step 3: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && bash -n scenarios/09-identity-outage.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/09-identity-outage.sh'`
Expected: no output.

- [ ] **Step 4: Commit**

O's evidence run is Task 22.

```bash
git add demos/cert-hygiene/scenarios/09-identity-outage.sh demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add identity-outage scenario"
git push
```
