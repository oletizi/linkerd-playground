# Task 16: Scenario S-staged

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 7, `07-anchor-rotation-staged`, profile `long`: the 11 steps of Linkerd's [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/), exactly, starting from a valid anchor (which is what separates S from A). It is step-driven (`run_steps_scenario`). After `FAULT_LEAD_S` of pre ticks:

| Step | Action | Tick after it |
| --- | --- | --- |
| 1 | Create a new anchor (`certs/trust-anchor-new`) | `s01-new-anchor` |
| 2 | Bundle it with the old one: `step certificate bundle ca-new.crt ca.crt bundle.crt` (`certs/trust-bundle`) | `s02-bundle` |
| 3 | `linkerd upgrade --identity-trust-anchors-file=bundle.crt \| kubectl apply -f -` | `s03-upgrade-bundle` |
| 4 | Restart the meshed workloads: every lab Deployment, gated (`gates/s04-restart.txt`) | `s04-restart` |
| 5 | `linkerd check --proxy` (`steps/s05-check-proxy.txt`) | `s05-check` |
| 6 | Create a new issuer signed by the new anchor (`certs/issuer-new`) | `s06-new-issuer` |
| 7 | Apply it with the issuer-only upgrade; wait for `IssuerUpdated` | `s07-apply-issuer` |
| 8 | Restart the meshed workloads, gated (`gates/s08-restart.txt`) | `s08-restart` |
| 9 | `linkerd check --proxy` (`steps/s09-check-proxy.txt`) | `s09-check` |
| 10 | `linkerd upgrade --identity-trust-anchors-file=ca-new.crt \| kubectl apply -f -` | `s10-new-anchor-only` |
| 11 | Restart the meshed workloads, gated (`gates/s11-restart.txt`), then `linkerd check --proxy` (`steps/s11-check-proxy.txt`) | `s11-restart-check` |

Every restart step restarts **all** lab Deployments, as the guide says. Holding one back would leave it trusting only the old anchor when step 7 introduces certificates chained to the new one, which is the very failure the procedure exists to avoid. After each upgrade, the control-plane rollouts are waited for and recorded (`steps/sNN-rollout.txt`). Every tick records `linkerd check` and `linkerd check --proxy` (S2 reads tick `s03-upgrade-bundle`), per-pod trust hashes, credential state and probe metrics. The credential plan is `A/I1 → A+B/I1 → A+B/I2 → B/I2` (Task 3).

S1 attributes a failure to TLS only through proxy logs, and only for gated samples: the pods each restart replaces have their logs and probe history captured just before it (`logs/pre-sNN/`, `probes/pre-sNN/`). S1-obs compares every application-visible failure with the control's restart disruption (Task 31).

**Files:**
- Create: `demos/cert-hygiene/scenarios/07-anchor-rotation-staged.sh`

**Interfaces:**
- Consumes: Task 9 `run_steps_scenario`, `observe_until`, Task 7 `restart_and_gate`, `lab_deployments`, Task 8 `snap_before_restart`, `wait_issuer_updated`, `make_trust_anchor`, `make_issuer`, `write_cert`, `NEW_ANCHOR_LIFETIME`, `REPLACEMENT_ISSUER_LIFETIME`, `FAULT_LEAD_S`.
- Produces: the ticks and gate records in the table; `certs/trust-anchor-new.{pem,txt}`, `certs/trust-bundle.{pem,txt}`, `certs/issuer-new.{pem,txt}`; `steps/s03-upgrade.txt`, `steps/s07-upgrade.txt`, `steps/s10-upgrade.txt`, `steps/sNN-rollout.txt`, `steps/s05-check-proxy.txt`, `steps/s09-check-proxy.txt`, `steps/s11-check-proxy.txt`; timeline markers `s01` … `s11` with the guide step's text.

- [ ] **Step 1: Write `demos/cert-hygiene/scenarios/07-anchor-rotation-staged.sh`**

```bash
#!/usr/bin/env bash
# Scenario S-staged (design section 7): the 11 steps of Linkerd's manual trust-anchor
# rotation guide, exactly, from a valid anchor. Each restart step restarts every lab
# Deployment and is gated and sampled; a tick follows every step. Launch with
# scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

_s_upgrade() { # NN ARGS...: linkerd upgrade ARGS | kubectl apply -f -, then control-plane rollouts
  local nn="$1"
  shift
  capture "steps/s$nn-upgrade.txt" bash -o pipefail -c "linkerd upgrade $(printf '%q ' "$@") | kubectl apply -f -"
  capture "steps/s$nn-rollout.txt" bash -c \
    'for d in $(kubectl -n linkerd get deploy -o name); do kubectl -n linkerd rollout status "$d" --timeout=300s || exit 1; done'
}

_s_restart() { # NN: restart every meshed lab workload, gated and sampled
  local all=()
  snap_before_restart "pre-s$1"
  mapfile -t all < <(lab_deployments)
  restart_and_gate "s$1-restart" "${all[@]}"
}

scenario_steps() {
  local new="$CERTS/new"
  observe_until $(( $(date -u +%s) + FAULT_LEAD_S )) pre
  mkdir -p "$RUN_DIR/steps"

  mark s01 "create a new trust anchor"
  make_trust_anchor "$new" "$NEW_ANCHOR_LIFETIME"
  write_cert trust-anchor-new "$new/ca.crt"
  tick s01-new-anchor

  mark s02 "bundle it with the old one (step certificate bundle)"
  step certificate bundle "$new/ca.crt" "$CERTS/ca.crt" "$CERTS/bundle.crt"
  write_cert trust-bundle "$CERTS/bundle.crt"
  tick s02-bundle

  mark s03 "linkerd upgrade --identity-trust-anchors-file=bundle.crt"
  _s_upgrade 03 --identity-trust-anchors-file="$CERTS/bundle.crt"
  tick s03-upgrade-bundle

  mark s04 "restart the meshed workloads"
  _s_restart 04
  tick s04-restart

  mark s05 "linkerd check --proxy"
  capture steps/s05-check-proxy.txt linkerd check --proxy --wait 20s
  tick s05-check

  mark s06 "create a new issuer signed by the new anchor"
  make_issuer "$CERTS/issuer-new" "$REPLACEMENT_ISSUER_LIFETIME" "$new"
  write_cert issuer-new "$CERTS/issuer-new/issuer.crt"
  tick s06-new-issuer

  mark s07 "apply the new issuer (issuer-only linkerd upgrade)"
  _s_upgrade 07 --identity-issuer-certificate-file="$CERTS/issuer-new/issuer.crt" \
    --identity-issuer-key-file="$CERTS/issuer-new/issuer.key"
  wait_issuer_updated 180
  tick s07-apply-issuer

  mark s08 "restart the meshed workloads"
  _s_restart 08
  tick s08-restart

  mark s09 "linkerd check --proxy"
  capture steps/s09-check-proxy.txt linkerd check --proxy --wait 20s
  tick s09-check

  mark s10 "linkerd upgrade --identity-trust-anchors-file=ca-new.crt"
  _s_upgrade 10 --identity-trust-anchors-file="$new/ca.crt"
  tick s10-new-anchor-only

  mark s11 "restart the meshed workloads, and run linkerd check --proxy"
  _s_restart 11
  capture steps/s11-check-proxy.txt linkerd check --proxy --wait 20s
  tick s11-restart-check
}

run_steps_scenario 07-anchor-rotation-staged long "${1:?usage: 07-anchor-rotation-staged.sh <run-dir>}"
```

`write_cert trust-bundle` stores both anchors in `certs/trust-bundle.pem`; its `.txt` inspects the first. `make_issuer`'s `ANCHOR_DIR` argument is the new anchor's directory, so the new issuer chains to B.

- [ ] **Step 2: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && bash -n scenarios/07-anchor-rotation-staged.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/07-anchor-rotation-staged.sh'`
Expected: no output.

- [ ] **Step 3: Check the bundle command against the pinned tooling**

Run: `bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && d=$(mktemp -d) && make_trust_anchor "$d/a" 1h && make_trust_anchor "$d/b" 1h && step certificate bundle "$d/b/ca.crt" "$d/a/ca.crt" "$d/bundle.crt" && grep -c "BEGIN CERTIFICATE" "$d/bundle.crt"; rm -rf "$d"'`
Expected: `2`.

- [ ] **Step 4: Commit**

S-staged's evidence run is Task 25.

```bash
git add demos/cert-hygiene/scenarios/07-anchor-rotation-staged.sh
git commit -m "cert-hygiene add staged trust-anchor rotation scenario"
git push
```
