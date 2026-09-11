# Task 15: Scenario A

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 6, `06-anchor-expiry`, profile `anchor-short`: a 20-minute anchor, and a 120-minute issuer that outlives it. T_mark is the anchor's `notAfter`, and the expiry itself is the fault. The post-expiry actions are the defaults, and the window is the 1800 s default.

**Timing is measured per proxy.** Leaves are capped at the issuer's expiry, not the anchor's, so each proxy's last pre-expiry leaf expires at its own moment. Every tick's metrics already record, per proxy, `control_identity_cert_refresh_timestamp_seconds` (the last successful issuance), `…_expiration_timestamp_seconds` (that leaf's `notAfter`) and refresh counts. The probe logs record the first new-connection failure on each pair. Task 30 reads per-proxy survival from those.

**Recovery in named stages** (design § 6):
1. **Apply.** Create a new anchor and a new issuer signed by it, then apply both with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… --identity-trust-anchors-file=… --force | kubectl apply -f -`. Record control-plane pod UIDs before and after the upgrade's own rollouts, which shows what the upgrade itself restarted.
2. **No manual restarts** for `RECOVER_WINDOW_S`. To make "is identity issuing leaves chained to the new anchor?" a direct observation, a fresh meshed Deployment, `identity-canary`, is applied at the start of the stage. It is injected with the new trust bundle only, so it can become Ready only by obtaining a new-anchor leaf. Ticks run through the window, with identity logs and events at its end.
3. **Identity/control-plane restart, only if needed.** If the canary isn't Ready by the end of stage 2, restart `linkerd-identity`, then every other control-plane Deployment that has a pod started before the stage-1 apply. Control-plane components load trust roots at container start (source notes § 3 and § 4), and their `trust-root-sha256` annotations do not equal the ConfigMap hash even when current (slice-1 run `runs/05-issuer-expiry/20260911T021157Z/trust/baseline.txt`), so start time, not annotation, identifies them. Then watch the canary for another `RECOVER_WINDOW_S`. If it isn't needed, the stage is recorded as not needed.
4. **Workload restarts,** as the guide directs: every lab Deployment, gated and sampled (Task 7).
5. **Verify** with `linkerd check`: the `verify` tick.

The credential plan is `A/I1 → B/I2` (Task 3). A5 asks whether the canary became Ready in stage 2 (unless stage 1's rollouts already restarted identity) or only after stage 3; the records answer it.

**Files:**
- Create: `demos/cert-hygiene/scenarios/06-anchor-expiry.sh`, `demos/cert-hygiene/lab/workloads/identity-canary.yaml`
- Modify: `demos/cert-hygiene/lab/deploy.sh` (`identity-canary`), `demos/cert-hygiene/config.example.env` (`NEW_ANCHOR_LIFETIME`)

**Interfaces:**
- Consumes: Task 9 `run_scenario`, Task 7 `restart_and_gate`, `lab_deployments`, Task 8 `snap_before_restart`, `make_trust_anchor`, `make_issuer`, `write_cert`, `snap_controlplane`, `snap_logs`, `snap_events`, `observe_until`.
- Produces:
  - Deployment `identity-canary` (label `app=identity-canary`, container `idle`), applied without waiting by `deploy.sh identity-canary`.
  - Evidence: `certs/trust-anchor-new.{pem,txt}`, `certs/issuer-replacement.{pem,txt}`, `recover/linkerd-upgrade.txt`, `recover/a-stage1-rollout.txt`, `controlplane/a-stage1-before.txt`, `controlplane/a-stage1-after.txt`, tick `a-stage1`; `recover/a-stage2-canary.txt`, ticks `a-stage2-N`, `recover/a-stage2-canary-N.txt`, `logs/a-stage2/`, `events/a-stage2.txt`; when stage 3 runs: `recover/a-stage3-identity.txt`, `recover/a-stage3-identity-rollout.txt`, `recover/a-stage3-stale.txt`, `recover/a-stage3-control-plane.txt`, `controlplane/a-stage3-after.txt`, ticks `a-stage3-N`, `recover/a-stage3-canary-N.txt`; `gates/a-stage4.txt`, tick `a-stage4`.
  - Timeline markers: `a-stage1-apply`, `a-stage2`, `a-canary <stage>: Ready …|not Ready …`, `a-stage3 …` (run or not needed), `a-stage5`.
  - Config: `NEW_ANCHOR_LIFETIME=87600h` (S reuses it).

- [ ] **Step 1: Write `demos/cert-hygiene/lab/workloads/identity-canary.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-canary
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: identity-canary
  template:
    metadata:
      labels:
        app: identity-canary
    spec:
      containers:
        - name: idle
          image: ${IMAGE_BUSYBOX}
          command: ["sh", "-c", "while :; do sleep 3600; done"]
```

- [ ] **Step 2: Add it to `demos/cert-hygiene/lab/deploy.sh`**

Change the usage text on both usage lines to `<baseline|probe-new|identity-canary>`, add to the header comment `#   identity-canary: A's canary, created after recovery's apply; applied WITHOUT waiting.`, and add this case before the `*)` case:

```bash
  identity-canary)
    render identity-canary | kubectl apply -f -
    ;;
```

- [ ] **Step 3: Setting in `demos/cert-hygiene/config.example.env`**

Append to the `# ---- Credentials ----` section:

```bash
# A and S: lifetime of the new trust anchor that recovery or rotation creates.
NEW_ANCHOR_LIFETIME=87600h
```

- [ ] **Step 4: Write `demos/cert-hygiene/scenarios/06-anchor-expiry.sh`**

```bash
#!/usr/bin/env bash
# Scenario A (design section 6): a 20-minute trust anchor expires while its 120-minute
# issuer is still within its dates. T_mark is the anchor's notAfter. Recovery follows
# Linkerd's root-and-issuer replacement in named stages: apply; no manual restarts
# (with a canary that can only become Ready on a new-anchor leaf); an identity and
# control-plane restart only if needed; gated workload restarts; verify.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

A_APPLY_EPOCH=0

scenario_mark_epoch() {
  cert_not_after_epoch "$CERTS/ca.crt"
}

_a_canary_ready() { # STAGE TIMEOUT_S: ticks until identity-canary is Ready (0) or TIMEOUT_S passes (1)
  local stage="$1" deadline=$(( $(date -u +%s) + $2 )) n=1 t0 ready
  t0="$(date -u +%s)"
  while :; do
    tick "$stage-$n"
    capture "recover/$stage-canary-$n.txt" kubectl -n "$LAB_NS" get pods -l app=identity-canary -o wide
    ready="$(kubectl -n "$LAB_NS" get pods -l app=identity-canary \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "$ready" = True ]; then mark a-canary "$stage: Ready $(( $(date -u +%s) - t0 ))s into the stage"; return 0; fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then mark a-canary "$stage: not Ready after $2 s"; return 1; fi
    n=$((n + 1))
    sleep "$OBSERVE_INTERVAL_S"
  done
}

_a_stage3() { # identity, then every control-plane Deployment with a pod older than the apply
  local d sel stale=()
  mark a-stage3 "identity-canary not Ready after stage 2: restart linkerd-identity, then control-plane components started before the apply"
  capture recover/a-stage3-identity.txt kubectl -n linkerd rollout restart deploy/linkerd-identity
  capture recover/a-stage3-identity-rollout.txt kubectl -n linkerd rollout status deploy/linkerd-identity --timeout=300s
  while read -r d sel; do
    [ "$d" != linkerd-identity ] || continue
    if kubectl -n linkerd get pods -l "$sel" -o json \
        | jq -e --argjson a "$A_APPLY_EPOCH" '[.items[] | select((.status.startTime | fromdateiso8601) < $a)] | length > 0' > /dev/null; then
      stale+=("$d")
    fi
  done < <(kubectl -n linkerd get deploy -o json \
    | jq -r '.items[] | "\(.metadata.name) \(.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))"')
  printf 'apply_epoch=%s\nstarted_before_apply=%s\n' "$A_APPLY_EPOCH" "${stale[*]:-none}" > "$RUN_DIR/recover/a-stage3-stale.txt"
  if [ "${#stale[@]}" -gt 0 ]; then
    capture recover/a-stage3-control-plane.txt bash -c \
      'for d in "$@"; do kubectl -n linkerd rollout restart "deploy/$d" && kubectl -n linkerd rollout status "deploy/$d" --timeout=300s || exit 1; done' _ "${stale[@]}"
  else
    printf 'no other control-plane Deployment has a pod started before the apply\n' > "$RUN_DIR/recover/a-stage3-control-plane.txt"
  fi
  snap_controlplane a-stage3-after
  _a_canary_ready a-stage3 "$RECOVER_WINDOW_S" || true
}

scenario_recover() {
  local new="$CERTS/new" all=()
  # Stage 1: apply a new anchor and issuer, the documented way for an expired root.
  make_trust_anchor "$new" "$NEW_ANCHOR_LIFETIME"
  make_issuer "$new" "$REPLACEMENT_ISSUER_LIFETIME" "$new"
  write_cert trust-anchor-new "$new/ca.crt"
  write_cert issuer-replacement "$new/issuer.crt"
  snap_controlplane a-stage1-before
  A_APPLY_EPOCH="$(date -u +%s)"
  mark a-stage1-apply "linkerd upgrade with a new anchor and issuer, --force"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$new/issuer.crt' --identity-issuer-key-file='$new/issuer.key' --identity-trust-anchors-file='$new/ca.crt' --force | kubectl apply -f -"
  capture recover/a-stage1-rollout.txt bash -c \
    'for d in $(kubectl -n linkerd get deploy -o name); do kubectl -n linkerd rollout status "$d" --timeout=300s || exit 1; done'
  snap_controlplane a-stage1-after
  tick a-stage1
  # Stage 2: no manual restarts; the canary shows whether identity issues new-anchor leaves.
  mark a-stage2 "no manual restarts for ${RECOVER_WINDOW_S}s; identity-canary applied"
  capture recover/a-stage2-canary.txt bash "$LAB_DIR/deploy.sh" identity-canary
  if _a_canary_ready a-stage2 "$RECOVER_WINDOW_S"; then
    snap_logs a-stage2
    snap_events a-stage2
    mark a-stage3 "not needed: identity-canary became Ready in stage 2"
  else
    snap_logs a-stage2
    snap_events a-stage2
    _a_stage3
  fi
  # Stage 4: restart every meshed lab workload, as the guide directs; gated and sampled.
  snap_before_restart pre-a-stage4
  mapfile -t all < <(lab_deployments)
  restart_and_gate a-stage4 "${all[@]}"
  tick a-stage4
  # Stage 5: verify with linkerd check -- the verify tick that follows.
  mark a-stage5 "verify with linkerd check (the verify tick)"
}

run_scenario 06-anchor-expiry anchor-short "${1:?usage: 06-anchor-expiry.sh <run-dir>}"
```

- [ ] **Step 5: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && bash -n scenarios/06-anchor-expiry.sh lab/deploy.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scenarios/06-anchor-expiry.sh lab/deploy.sh'`
Expected: no output.

- [ ] **Step 6: Confirm `step` still signs an issuer that outlives its anchor**

The design records this as confirmed; re-check it against the pinned tooling without touching the cluster. Run: `bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && d=$(mktemp -d) && make_trust_anchor "$d" 20m && make_issuer "$d" 120m "$d" && openssl x509 -noout -enddate -in "$d/ca.crt" && openssl x509 -noout -enddate -in "$d/issuer.crt"; rm -rf "$d"'`
Expected: two `notAfter=` lines, the issuer's about 100 minutes after the anchor's. If `step` refuses or caps the issuer, stop and report to the user: A's profile needs revision.

- [ ] **Step 7: Commit**

A's evidence run is Task 24.

```bash
git add demos/cert-hygiene/scenarios/06-anchor-expiry.sh demos/cert-hygiene/lab demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add trust-anchor expiry scenario with named recovery stages"
git push
```
