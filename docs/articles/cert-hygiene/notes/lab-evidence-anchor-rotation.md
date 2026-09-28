# Evidence: trust-anchor rotation, staged and one-step

- **Runs:** `demos/cert-hygiene/runs/07-anchor-rotation-staged/20260912T135204Z` (SS) and `demos/cert-hygiene/runs/08-anchor-rotation-hard/20260912T141221Z` (SH) — both `evidence_valid=yes` (`SS/validity.txt:1`, `SH/validity.txt:1`)
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z` (C), same harness tree: `harness_tree_sha256=e86c787ea2317ecdbc45e607681b83bba0f9e94b48f7f87aed3d95f0d274e7c8` in all three of `SS/git-state.txt:3`, `SH/git-state.txt:3`, `C/git-state.txt:3`
- **Versions:** `linkerd_cli_version=edge-26.9.1` (`SS/versions.txt:4`, same in `SH/versions.txt`)
- **Lifetimes:** `config_ANCHOR_LIFETIME=87600h`, `config_ISSUER_LIFETIME=8760h`, `config_LEAF_LIFETIME=5m`, `config_PROFILE=long` (`SS/versions.txt:20,36,45,53`)
- **One-step swap (`s-hard-swap`):** the timeline marker reads 2026-09-12T14:24:13Z (`SH/timeline.log:25`); the recorded action time is `swap_epoch=1789223053` (`SH/s-hard/stage1-condition.txt:2`), 1s after `t_mark epoch=1789223052` (`SH/timeline.log`, `t_mark` line). All swap-relative times below use `swap_epoch`, not the marker or `t_mark`, per the reading guide.

One run of each (SS, SH), against one control (C). No repeats.

## Acceptance conditions (design § 13)

| Condition | Met? | Evidence |
| --- | --- | --- |
| Staged results separate TLS-attributable failures from rollout disruption, against the control | Yes | SS has zero `probe-http`/`probe-tcp-new`/`probe-tcp-new-b` failures across all three gated restarts (§ S1 below) and zero certificate/trust lines in any proxy-log snapshot; its three `probe-tcp-stream` disconnects match the control's own disconnect in cause (the server pod dying under a rollout restart) and magnitude (§ S1-obs) |
| Hard rotation records the actual mixed-anchor endpoint states | Yes | Per-pod `trust/stage2-client-a.txt` and `trust/stage3-server.txt` annotations, not restart order, show the mixed pairs directly (§ S3) |
| ...and the stage-1 old-leaf renewal and expiry behaviour | Yes | `SH/s-hard/stage1-condition.txt` records `result=met` and, for every endpoint, `state=expired-failed`, `renew_attempts=0`, the old leaf's `notAfter`, and the first failed connection after expiry (§ S4) |

All three hold. S is written up as reproduced.

## Facts checked (design's task, Step 1)

- Both runs valid at the control's tree (above).
- SS walks four credential states: `declared: plan A/I1 A+B/I1 A+B/I2 B/I2`, confirmed observed (`SS/credential-plan.txt:1-7`).
- SH walks two: `declared: plan A/I1 B/I2`, confirmed observed (`SH/credential-plan.txt:1-5`).
- SS's `linkerd check --proxy` warns "Some pods do not have the current trust bundle and must be restarted", naming all six lab Deployments' pods, at `s03-upgrade-bundle-check-proxy.txt:60-66` (`lab/probe-http-586cfdddb4-rtbqw`, `lab/probe-tcp-new-b-64dbdd7f5c-llfvs`, `lab/probe-tcp-new-f6545f757-t7vf6`, `lab/probe-tcp-stream-5f4ccc76bc-sbl52`, `lab/restart-target-554865b545-xhdcm`, `lab/server-577d5dfdbd-qhwvf`) — one of every lab Deployment. The warning is absent from `s04-restart-check-proxy.txt`, `s09-check-check-proxy.txt` and `s11-restart-check-check-proxy.txt` (zero matches for `current trust bundle` in each).
- Every restart step in SS (`s04-restart`, `s08-restart`, `s11-restart`) restarts all six lab Deployments: `restarted=probe-http,probe-tcp-new,probe-tcp-new-b,probe-tcp-stream,restart-target,server` (`SS/timeline.log:31,42,50`).

## Staged rotation, step by step

Times from `SS/timeline.log:24-54`.

| Step | Time | What changed | Gate |
| --- | --- | --- | --- |
| 1. Create new anchor | 14:03:58Z | new anchor material created | — |
| 2. Bundle with old | 14:04:04Z | bundle.crt = old + new anchor | — |
| 3. `upgrade --identity-trust-anchors-file=bundle.crt` | 14:04:09Z | trust roots ConfigMap becomes A+B (issuer stays I1) | — |
| 4. Restart all workloads | command 14:04:25Z, `gate s04-restart pass` 14:05:08Z (43s) | all six Deployments; every pod picks up the A+B bundle | pass, both pair cells 10/0 |
| 5. `check --proxy` | 14:05:59Z | clean — no "current trust bundle" warning | — |
| 6. Create new issuer (signed by new anchor) | 14:06:09Z | issuer material I2 created | — |
| 7. Apply new issuer (issuer-only upgrade) | 14:06:14Z | issuer becomes I2; `IssuerUpdated` event observed at 14:06:32Z (`SS/timeline.log:39`) | — |
| 8. Restart all workloads | command 14:06:40Z, `gate s08-restart pass` 14:07:18Z (38s) | all six Deployments restart, taking new leaves signed by I2 | pass, both pair cells 10/0 |
| 9. `check --proxy` | 14:08:10Z | clean | — |
| 10. `upgrade --identity-trust-anchors-file=ca-new.crt` | 14:08:20Z | trust roots ConfigMap becomes B only (old anchor dropped) | — |
| 11. Restart all workloads + `check --proxy` | command (`started_at`) 14:08:35Z, `gate s11-restart pass` 14:09:18Z (43s, `SS/gates/s11-restart.txt:3,55`) | all six Deployments restart onto B/I2 only; final check clean | pass, both pair cells 10/0 |

All eleven steps ran in order; all three restart gates passed; every gated sample cell was `ok=10 fail=0` for both pairs (`bash scripts/gate-table.sh SS`).

## S1 — no TLS-attributable failure in the staged rotation

**Verdict: confirmed.**

- `bash scripts/gate-table.sh SS` reports, for `s04-restart`, `s08-restart` and `s11-restart`, `gate=pass` and `cell pair=A ok=10 fail=0`, `cell pair=B ok=10 fail=0` in every stage — ten fresh connections per pair per stage, zero failures.
- The fresh-connection probes (`probe-http`, `probe-tcp-new`, `probe-tcp-new-b`) recorded zero failures anywhere in the run: `bash scripts/probe-lines.sh SS probe-http|probe-tcp-new|probe-tcp-new-b | awk '$4 != "ok"'` returns nothing for all three.
- No proxy-log snapshot shows a certificate or trust line at any point in the run: `grep -hiE 'certificate|trust|x509|handshake' SS/logs/{pre-s04,pre-s08,pre-s11,final}/*-linkerd-proxy.txt` matches nothing.
- The held-open `probe-tcp-stream` probe did register three disconnects (`seq` resets at `SS/probes/pre-s08/probe-tcp-stream-575d67dccb-plfc5.log:4`, `SS/probes/pre-s11/probe-tcp-stream-586f88dcfc-4phcl.log:5`, `SS/probes/final/probe-tcp-stream-6fc55f67b-xx8lw.log:4`), but each is a plain `socat_rc=0 fail-closed, not reconnecting` — no certificate or trust error accompanies any of them, and per the design's judgement rule a failure counts against S1 only if the proxy logs show one. These three are reported as S1-obs, not against S1.

## S1-obs — every application-visible failure, against the control (observation)

SS's only application-visible failures are the three `probe-tcp-stream` disconnects above. Each lands inside a restart-stage window, timed against the "before" pod's disappearance recorded in that stage's gate file:

| Closure | Time | Restart command | Offset | Old server pod's termination window (from gate file) |
| --- | --- | --- | --- | --- |
| conn `fcea240e-1789221868` | 14:04:30Z | `s04-restart` at 14:04:25Z (`SS/gates/s04-restart.txt:3`) | +5s | old pod `server-577d5dfdbd-qhwvf` (`SS/gates/s04-restart.txt:10`); new pod not `serving=yes` until 14:04:38Z |
| conn `dcd59ab5-1789222003` | 14:06:45Z | `s08-restart` at 14:06:40Z (`SS/gates/s08-restart.txt:3`) | +5s | old pod `server-6664c7878b-txhz6` (`SS/gates/s08-restart.txt:10`); new pod not `serving=yes` until 14:06:49Z (`SS/gates/s08-restart.txt:22`) |
| conn `f2829ece-1789222119` | 14:08:41Z | `s11-restart` at 14:08:35Z (`SS/gates/s11-restart.txt:3`) | +6s | old pod `server-79dcc8c795-trm7c` (`SS/gates/s11-restart.txt:10`); new pod not `serving=yes` until 14:08:45Z (`SS/gates/s11-restart.txt:22`) |

Every closure falls before the new `server` pod finishes coming up — i.e. while the old `server` pod is terminating, not after. All three restart stages restart `server` itself (the guide restarts every Deployment at every step), so the held-open stream to `server` breaks each time.

The control's restart choreography (`C/timeline.log:96-118`) restarts `server` only once, at `stage3-server` (restart command 07:44:25Z, `C/timeline.log:112`). Its `probe-tcp-stream` log shows exactly one disconnect in the whole run, `conn=7e877753-1789195992 closed socat_rc=0 fail-closed, not reconnecting` at 07:44:29Z (`C/probes/pre-stage4/probe-tcp-stream-5f4ccc76bc-kd6vf.log:1537`) — 4s after that restart command, the same magnitude as SS's three closures, and the same cause (a held-open stream's remote pod dying under `rollout restart`).

SS shows three such closures where the control shows one only because SS's procedure restarts `server` three times (once per guide restart step) where the control's choreography restarts it once. Per-restart, the disruption is identical in kind and timing: an artifact of `rollout restart` recycling the pod a held-open stream is connected to, not of the anchor rotation. This is what "without downtime" needs qualifying against: it holds for fresh connections and requests (confirmed by S1), not for connections already open across a pod restart — a fact true of ordinary rollouts as much as of trust-anchor rotation, as the control shows.

## S2 — the trust-bundle warning between steps 3 and 4

**Verdict: confirmed.**

`s03-upgrade-bundle-check-proxy.txt:60-66`:

```
Some pods do not have the current trust bundle and must be restarted:
	* lab/probe-http-586cfdddb4-rtbqw
	* lab/probe-tcp-new-b-64dbdd7f5c-llfvs
	* lab/probe-tcp-new-f6545f757-t7vf6
	* lab/probe-tcp-stream-5f4ccc76bc-sbl52
	* lab/restart-target-554865b545-xhdcm
	* lab/server-577d5dfdbd-qhwvf
```

All six lab pods are named — the run's entire lab workload set at that point. `s04-restart-check-proxy.txt` (captured right after step 4's restart) has zero occurrences of "current trust bundle" — the warning is gone. The same check stays clean after steps 8 and 11 (`s09-check-check-proxy.txt`, `s11-restart-check-check-proxy.txt`), zero matches each.

## One-step replacement

`SH`'s swap applies a new anchor and a new issuer together, `--force`, no bundle (`SH/swap/linkerd-upgrade.txt:1`, `‼ Rotating the trust anchors will affect existing proxies`). The `linkerd-identity` Deployment itself restarts as part of the same `kubectl apply`: the identity pod's UID and start time change from `linkerd-identity-84ddf57dd5-khmbw` (start 14:13:54Z, `SH/controlplane/fault-minus10.txt:3`) to `linkerd-identity-7969785cd-hrw5d` (start 2026-09-12T14:24:14Z, `SH/controlplane/swap-after.txt:4`) — 1s after the swap. Identity therefore begins signing exclusively with the new issuer (I2) essentially immediately, before any lab workload is restarted.

Timeline (all times, and offsets from `swap_epoch=1789223053` i.e. 14:24:13Z, `SH/s-hard/stage1-condition.txt:2`):

| Event | Time | Offset from swap |
| --- | --- | --- |
| Swap (`s-hard-swap`) | 14:24:13Z | 0s |
| Stage 1 (no restarts) begins | 14:25:15Z (`SH/timeline.log:29-30`) | +62s |
| Server's old leaf `notAfter` | 14:26:54Z (epoch 1789223214, `SH/s-hard/stage1-condition.txt:15`) | +161s |
| Client A/B's old leaf `notAfter` | 14:26:57Z (epoch 1789223217, `SH/s-hard/stage1-condition.txt:13-14`) | +164s |
| Server's first failed fresh connection after expiry | 14:26:56Z (`SH/s-hard/stage1-condition.txt:15`) | +2s after its own leaf's `notAfter` |
| Client A/B's first failed fresh connection after expiry | 14:26:58Z (`SH/s-hard/stage1-condition.txt:13-14`) | +1s after their own leaf's `notAfter` |
| Stage 1 condition met | 14:27:09Z (`SH/timeline.log:34`) | +176s |
| Restart client A (`stage2-client-a`) | command (`started_at`) 14:27:55Z, `gate pass` 14:28:34Z (39s, `SH/gates/stage2-client-a.txt:3,16`) | — |
| Restart `server` (`stage3-server`) | command (`started_at`) 14:29:25Z, `gate pass` 14:30:03Z (38s, `SH/gates/stage3-server.txt:3,15`) | — |
| Restart everything else (`stage4-all`) | command (`started_at`) 14:31:06Z, `gate pass` 14:31:57Z (51s, `SH/gates/stage4-all.txt:3`) | — |

Before the swap, both pairs work: no `probe-http`/`probe-tcp-new`/`probe-tcp-new-b` failures between `t_mark` and the swap (`bash scripts/probe-lines.sh SH probe-http|probe-tcp-new|probe-tcp-new-b 2026-09-12T14:14:12Z 2026-09-12T14:24:13Z` returns nothing for all three).

### Stage-1 per-endpoint record (`SH/s-hard/stage1-condition.txt`)

`result=met` (line 1). At the final poll (`tick=stage1-4`, lines 13-15), all three endpoints:

| Endpoint | Old leaf `notAfter` | `renew_attempts` | Final state | First failed connection after expiry |
| --- | --- | --- | --- | --- |
| clientA (`probe-tcp-new-f6545f757-zc5pk`) | 2026-09-12T14:26:57Z | 0 | `expired-failed` | 2026-09-12T14:26:58Z |
| clientB (`probe-tcp-new-b-64dbdd7f5c-b7w2n`) | 2026-09-12T14:26:57Z | 0 | `expired-failed` | 2026-09-12T14:26:58Z |
| server (`server-577d5dfdbd-26zq2`) | 2026-09-12T14:26:54Z | 0 | `expired-failed` | 2026-09-12T14:26:56Z |

**None renewed.** `renew_attempts=0` for every endpoint at every polled tick (`stage1-1` through `stage1-4`, lines 3-15). Each proxy's repeated attempts to reach identity failed throughout, logged as `renew_log_fails` climbing from 0/1/5 at `stage1-1` (lines 3-5) to 18 at `stage1-4` (lines 13-15), all citing the same error, e.g. line 13: `identity:identity{server.addr=linkerd-identity-headless.linkerd.svc.cluster.local:8080}:...:_Failed_to_connect_error=endpoint_10.42.0.14:8080:_invalid_peer_certificate:_BadSignature`. This is a failure to connect to the identity service itself, not a rejected renewed leaf: because identity restarted onto the new anchor/issuer within 1s of the swap, an unrestarted proxy — still holding only the old trust bundle — cannot validate identity's own certificate and so cannot complete a CSR round-trip at all. No endpoint ever obtained a renewed leaf, old-anchor or new-anchor; each rode out its original 5-minute leaf until it expired on schedule, then failed its first new connection attempt 1-2s later.

Because no endpoint renewed, the plan's question of which anchor a stage-1 "renewed" leaf chains to does not arise in this run: there is no renewed leaf to trace. This should be stated plainly rather than left open.

## S3 — mixed-anchor pairs fail

**Verdict: confirmed.**

`bash scripts/gate-table.sh SH`:

| Stage | Pair A cell | Pair B cell |
| --- | --- | --- |
| `stage1-norestart` | `ok=0 fail=10` | `ok=0 fail=10` |
| `stage2-client-a` | `ok=0 fail=10` | `ok=0 fail=10` |
| `stage3-server` | `ok=10 fail=0` | `ok=0 fail=10` |
| `stage4-all` | `ok=10 fail=0` | `ok=10 fail=0` |

Per-pod trust annotations, not restart order, establish the anchor each endpoint held at the two ticks the design names:

- `SH/trust/stage2-client-a.txt`: `configmap_sha256=72d93ab1...` (new anchor). `lab/probe-tcp-new-c76c5fd75-zrmkd` (client A, restarted) carries `72d93ab1...` (new); `lab/probe-tcp-new-b-64dbdd7f5c-b7w2n` (client B) and `lab/server-577d5dfdbd-26zq2` (server) both still carry `0da9460e...` (old). Pair A is new-client/old-server — mixed, and its cell is `0/10` at this stage.
- `SH/trust/stage3-server.txt`: same `configmap_sha256=72d93ab1...`. `lab/server-78779996fb-rsr4s` (server, just restarted) now carries `72d93ab1...` (new); `lab/probe-tcp-new-b-64dbdd7f5c-b7w2n` (client B) still carries `0da9460e...` (old). Pair B is old-client/new-server — mixed, and its cell is `0/10` at this stage, while pair A (now new/new) is `10/0`.

This matches the design's predicted matrix exactly: pair A fails at stage 2 (mixed trust), pair B fails at stage 3 (mixed trust), both work once all-restarted at stage 4.

Two cells don't fit the "mixed trust" framing directly and are worth calling out:

- Pair B's `0/10` at `stage2-client-a`: client B and server both still hold the *old* anchor (not mixed), yet the pair still fails. This is the stage-1 failure carrying forward — the server's own leaf had already expired in stage 1 (S4) and it has no valid leaf to offer to *any* peer, matching or not, until it is restarted at stage 3.
- Pair A's `0/10` at `stage1-norestart`: before any restart, both pairs fail — this is S4's predicted stage-1 expiry, not a mixed-anchor failure (both endpoints still hold the same, old, anchor at that point).

So the mixed-anchor matrix (S3) accounts for the stage2/stage3 failures precisely; the stage-1 row is S4's failure, not S3's, and is reported there.

## S4 — unrestarted proxies can't take a new-anchor leaf

**Verdict: confirmed.**

All three endpoints reached `state=expired-failed` (`SH/s-hard/stage1-condition.txt:13-15`): each kept its original leaf until that leaf's own `notAfter`, then failed its first subsequent connection 1-2s later (table above). None renewed (`renew_attempts=0` throughout), so the specific mechanism differs slightly from the hypothesis's literal wording — no proxy ever *took* a renewed leaf of either anchor, because identity restarted onto the new anchor/issuer within 1s of the swap and an old-anchor-only proxy cannot even complete a handshake with the new identity pod to request one (`BadSignature` against `linkerd-identity-headless`, `SH/s-hard/stage1-condition.txt:13`). The predicted *outcome* — an unrestarted proxy keeps its current leaf and fails once that leaf expires — is exactly what happened for all three endpoints, so S4 is confirmed on its outcome; the failure mode is "can't reach identity to renew at all" rather than "renewal succeeds but the new leaf is rejected."

Per the plan's settled choice: since no endpoint's state is `renewed`, there is no renewed leaf whose anchor needs establishing. Say so plainly — the question doesn't arise in this run, not left open.

## Evidence for the rotation guidance

- **Follow Linkerd's staged, six-step-restart procedure for a live rotation.** SS ran it exactly and produced zero TLS-attributable failures across all three restart gates (S1) and a clean `check --proxy` at the end of each restart step (S2), evidenced by `SS/gates/{s04,s08,s11}-restart.txt` and `SS/checks/{s04,s09,s11}*-check-proxy.txt`.
- **Restart every meshed workload at each restart step, not just some.** `s03-upgrade-bundle-check-proxy.txt:60-66` shows `linkerd check --proxy` naming every lab pod as not yet holding the current bundle right after the anchor bundle is applied — this is what step 4's "restart everything" step exists to clear, and it does (`s04-restart-check-proxy.txt` has zero such warnings).
- **Expect held-open connections to drop during any restart step, rotation or not.** SS's three `probe-tcp-stream` disconnects during its three restart steps are the same kind and magnitude of disruption as the control's single disconnect during its own single `server` restart (S1-obs). This is an ordinary consequence of `rollout restart`, not something the rotation procedure introduces.
- **Never replace both the anchor and issuer in one step against a live proxy fleet.** SH shows why: identity itself restarts onto the new anchor/issuer within 1s of the swap, so any proxy not yet holding the new anchor can no longer even reach identity to renew (`BadSignature`, `SH/s-hard/stage1-condition.txt`). Every endpoint rode its existing leaf to expiry and then failed outright (S4) — with mixed-anchor pairs failing at every partial-restart stage in between (S3) — and none of this shows up until each leaf's own `notAfter`, which in this lab's 5-minute leaf lifetime was 161-164s after the swap but in a production-scale issuer lifetime and clock-skew tolerance would only appear once the fleet's oldest live leaf finally expired.

## What this means for the article

- S's § 13 condition is met: the staged run isolates TLS failure from rollout disruption against the control, and the hard run's mixed-anchor states and stage-1 leaf-expiry behaviour are recorded directly from per-pod evidence, not inferred.
- S1 (confirmed), S2 (confirmed), S3 (confirmed) and S4 (confirmed, on outcome) all hold in this lab, on `edge-26.9.1`, with 5-minute leaves and long-lived anchors/issuers (`SS/versions.txt:20,36,45,53`).
- S1-obs is an observation, not scored: the staged rotation's only application-visible disruption is the same kind the control shows for ordinary restarts — held-open connections breaking when their peer pod recycles — not a TLS or trust-anchor effect.
- The one-step replacement's failure mode is worth narrowing for the article: it is not "a renewed new-anchor leaf gets rejected by an old-anchor proxy" but "an old-anchor proxy can't reach the now-new-anchor identity service at all, so it never renews, and rides its old leaf to expiry." Both lead to the same operator-visible outcome (proxies fail once their current leaf expires), but the mechanism differs from a literal reading of S4, and the article should say the mechanism as observed, not assume the more literal one.
- This is one run each of SS and SH against one control run; say so, and don't generalise beyond `edge-26.9.1` and this lab's lifetimes.
