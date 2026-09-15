# Task 10: Scenario R changes

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 2. R is slice 1's issuer-expiry scenario (`05-issuer-expiry`), re-run with the fixed harness. Most of its changes already live in shared code:
- the 1800 s post-expiry window (Task 8's config);
- connection metrics, workload proxy logs, per-pod probe history and credential state on every tick (Tasks 4–5);
- the second client (Task 6).

What remains is recovery. Slice 1's "tick until recovered, then escalate" loop is replaced by R's four cumulative stages, gated and sampled on both client→server pairs (`restart_stages`, Task 8). Together they produce the matrix of design § 2:

| Stage | Pair A: client / server | Pair B: client / server |
| --- | --- | --- |
| 1. no restart (`stage1-norestart`) | stale / stale | stale / stale |
| 2. client A restarted (`stage2-client-a`) | fresh / stale | stale / stale |
| 3. `server` restarted (`stage3-server`) | fresh / fresh | stale / fresh |
| 4. all restarted (`stage4-all`) | fresh / fresh | fresh / fresh |

Nothing restarts `server` or the stream pod before stage 3. Restarting `server` at stage 3 ends the established stream, and stage 4 restarts the stream pod, so the stream is observed for the whole 1800 s window (R4) and then until stage 3. The recovery also records which control-plane pods the issuer-only upgrade restarted (`controlplane/recover-applied.txt`, the confound slice 1's write-up had to rule out by hand).

**Files:**
- Modify (full rewrite): `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`

**Interfaces:**
- Consumes: `run_scenario`, `restart_stages`, `wait_issuer_updated`, `snap_controlplane`, `make_issuer` (`lib/certs.sh`), `cert_not_after_epoch`, `write_cert`, `capture`, `mark`, `snap_events`.
- Produces (evidence names later tasks read):
  - `certs/issuer-replacement.{pem,txt}`, `recover/linkerd-upgrade.txt`
  - `controlplane/recover-applied.txt` (after the `IssuerUpdated` wait)
  - timeline markers `recover-apply`, `issuer-updated`
  - `events/issuer-updated.txt`
  - the four `gates/stage*.txt` records and their ticks (Task 8 names)

- [ ] **Step 1: Rewrite `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`**

```bash
#!/usr/bin/env bash
# Scenario R (design section 2): slice 1's issuer expiry (#5), re-run. The identity
# issuer expires mid-run while the trust anchor and its key stay valid; T_mark is the
# issuer's notAfter. After a 1800 s post-expiry window, recovery signs a replacement
# issuer from the SAME anchor, applies it the documented way, and then maps endpoint
# state through four gated stages: no restarts; client A; server; everything else.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  cert_not_after_epoch "$CERTS/issuer.crt"
}

scenario_recover() {
  local rep="$CERTS/replacement"
  # The replacement is signed by the EXISTING anchor; nothing here touches the trust
  # roots. The credential plan (A/I1 -> A/I2) verifies both.
  make_issuer "$rep" "$REPLACEMENT_ISSUER_LIFETIME" "$CERTS"
  write_cert issuer-replacement "$rep/issuer.crt"
  mark recover-apply "linkerd upgrade with the replacement issuer; no trust-anchor flag"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$rep/issuer.crt' --identity-issuer-key-file='$rep/issuer.key' | kubectl apply -f -"
  wait_issuer_updated 180
  snap_events issuer-updated
  snap_controlplane recover-applied
  restart_stages
}

run_scenario 05-issuer-expiry issuer-short "${1:?usage: 05-issuer-expiry.sh <run-dir>}"
```

- [ ] **Step 2: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && bash -n scenarios/05-issuer-expiry.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/05-issuer-expiry.sh'`
Expected: no output.

- [ ] **Step 3: Confirm the timeline budget**

The issuer lives 15 minutes from certificate generation. `reset.sh` pulls images before generating certificates, so baseline arrives a few minutes after generation, and `_scenario_setup` dies if less than `LEAF_LIFETIME + 60 s` (360 s) remains before T_mark. The slice-1 run reached baseline 877 s before T_mark (`runs/05-issuer-expiry/20260911T021157Z/timeline.log`: baseline at 02:16:17, T_mark 02:30:54), so the margin holds. No change is needed; record nothing.

- [ ] **Step 4: Commit**

The scenario is not run here: R's evidence runs are Task 21, after the harness freeze.

```bash
git add demos/cert-hygiene/scenarios/05-issuer-expiry.sh
git commit -m "cert-hygiene re-run issuer expiry with gated recovery stages"
git push
```
