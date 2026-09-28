# Evidence: identity-service outage

- **Run:** `demos/cert-hygiene/runs/09-identity-outage/20260912T115519Z` — `validity.txt` line 1: `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z`, same harness tree — `git-state.txt` in both runs records `harness_tree_sha256=e86c787ea2317ecdbc45e607681b83bba0f9e94b48f7f87aed3d95f0d274e7c8`
- **Versions:** `versions.txt`: `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `kubernetes_version=v1.36.4+k3s1`; identity args include `-identity-issuance-lifetime=5m0s -identity-clock-skew-allowance=20s`
- **Lifetimes:** `config_ANCHOR_LIFETIME=87600h`, `config_ISSUER_LIFETIME=8760h` (long-lived anchor and issuer), `config_LEAF_LIFETIME=5m`, `config_OUTAGE_S=900`
- **Outage start (`fault-identity-down`):** `timeline.log:25` — `2026-09-12T12:07:22Z fault-identity-down scale deploy/linkerd-identity to 0 replicas for 900s`. This is 2 s after T_mark (`timeline.log:2` — `t_mark ... utc=2026-09-12T12:07:20Z`), because the fault fires after `tick fault-minus10` completes. All times below are given as `F+Ns` from this `fault-identity-down` marker (`F` = `2026-09-12T12:07:22Z`); the one exception is the acceptance-condition row, which quotes both markers directly.

## Acceptance conditions (design § 13)

| Condition | Met? | Evidence |
| --- | --- | --- |
| Credential and configuration invariant holds | Yes | `credential-plan.txt:1-3`: `result=ok`, one observed state (`A/I1`). `controlplane/*.txt` (67 files, one per tick): `grep -h 'deploy linkerd/linkerd-identity' */*.txt \| awk '{print $NF}' \| sort \| uniq -c` returns a single value, `template_sha256=22d8b8d6d2b66a28c5d066f103f6568c684c35821c5dfe220ad244b6727cf59d`; only `replicas=` and `generation=` change across ticks (e.g. `controlplane/baseline.txt:6` `replicas=1 generation=1` vs `controlplane/stage4-all.txt` `replicas=1 generation=3`). |
| Outage outlasts the leaf window | Yes | `fault-identity-down` at `2026-09-12T12:07:22Z` (`timeline.log:25`), `recover-identity-up` at `2026-09-12T12:22:57Z` (`timeline.log:58`). Elapsed: 935 s, which exceeds 320 s (5 m leaf + 20 s skew). |
| No-restart recovery window evaluated before any restart stage | Yes | `timeline.log:60` `stage stage1-norestart: no restarts for 300s` precedes `timeline.log:72` `restart stage2-client-a: probe-tcp-new`. `gates/stage1-norestart.txt` holds its ten samples per pair (lines 1-16 pair A, 17-27 pair B) plus leaf state (lines 28-30). |

All three conditions hold, so O's § 13 bar is met by this run.

## Timeline (times as `F+Ns`; `F = 2026-09-12T12:07:22Z`)

| F+s | UTC | Event | Source |
| --- | --- | --- | --- |
| −2 | 12:07:20Z | `t_mark` | `timeline.log:2` |
| 0 | 12:07:22Z | `fault-identity-down`, identity scaled to 0 for 900 s | `timeline.log:25` |
| 58 | 12:08:20Z | `applied probe-new` | `timeline.log:27` |
| 59 | 12:08:21Z | `rolled restart-target` | `timeline.log:28` |
| 161 | 12:10:03Z | first probe failure, pairs A and B | `probes/pre-stage2/probe-tcp-new-f6545f757-49q2f.log:382`, `probes/pre-stage2/probe-tcp-new-b-64dbdd7f5c-r6q68.log:382` |
| 935 | 12:22:57Z | `recover-identity-up`, identity scaled back to 1 | `timeline.log:58` |
| 936 | 12:22:58Z | new identity pod starts | `timeline.log:59` / `controlplane/recover-identity-up.txt:3` |
| 951 | 12:23:13Z | `stage1-norestart` begins (no restarts for 300 s); `probe-new`/`restart-target` first reach Ready | `timeline.log:60`; `pods/stage1-1-probe-new-ddf9946ff-75rp8-describe.txt:17` |
| 1227 | 12:27:49Z | `stage1-norestart` samples taken, no restarts | `timeline.log:71` |
| 1274 | 12:28:36Z | `restart stage2-client-a: probe-tcp-new` | `timeline.log:72` |
| 1381 | 12:30:23Z | `restart stage3-server: server` | `timeline.log:75` |
| 1498 | 12:32:20Z | `restart stage4-all: probe-http probe-new probe-tcp-new-b probe-tcp-stream restart-target` | `timeline.log:78` |

## O1 — proxies work until their current leaf expires

**Verdict: supported**, run `20260912T115519Z`.

Leaf expiries recorded at `fault-minus10` (before the outage) are unchanged from every earlier tick, i.e. these are each proxy's final pre-outage leaf:

- `probe-tcp-new` and `probe-tcp-new-b`: `control_identity_cert_expiration_timestamp_seconds 1789215005.0` = `2026-09-12T12:10:05Z` (F+163s) — `metrics/fault-minus10.txt:11,47` (via `pod-series.sh $O probe-tcp-new/-b control_identity_cert_expiration_timestamp_seconds`)
- `server`: `1789215002.0` = `2026-09-12T12:10:02Z` (F+160s) — same series for `server`

First new-connection failure for each pair, both at the same instant:

- Pair A (`probe-tcp-new` → `server`): `2026-09-12T12:10:03Z probe-tcp-new seq=381 fail socat_rc=1 reply= err=... Connection reset by peer` — `probes/pre-stage2/probe-tcp-new-f6545f757-49q2f.log:382` (last `ok` at `seq=380`, `2026-09-12T12:10:01Z`, the line immediately before)
- Pair B (`probe-tcp-new-b` → `server`): identical wording and second, `probes/pre-stage2/probe-tcp-new-b-64dbdd7f5c-r6q68.log:382`

Both failures land at F+161s (`12:10:03Z`), between the server's own leaf expiry (F+160s) and the clients' leaf expiry (F+163s) — right at the later of each pair's two relevant expiries, and 159s inside the 320 s (leaf + skew) bound. The mode is `Connection reset by peer`, i.e. the TLS handshake is torn down rather than silently hanging. No sample in the pre-outage ticks (`baseline` through `fault-plus10`) fails; every probe after `12:10:03Z` up to recovery fails. This is exactly the predicted shape: proxies keep serving connections on their still-valid leaf, and new connections fail once the relevant leaf(s) expire.

## O2 — expired proxies re-certify on their own after identity returns (open question)

**Verdict: falsified**, run `20260912T115519Z`, judged strictly from the no-restart window (`stage1-norestart`, `12:23:13Z`–`12:27:49Z`, F+951s to F+1227s — before `stage2-client-a`'s restart at F+1274s).

For the three proxies whose leaves expired during the outage (`probe-tcp-new`, `probe-tcp-new-b`, `server`), the refresh timestamp and refresh counter are unchanged from their pre-outage values across every tick of the no-restart window:

- `probe-tcp-new`: `control_identity_cert_refresh_timestamp_seconds 1789214685.043949` at `post-1` (`12:08:21Z`) through `stage1-10` (`12:27:43Z`); `control_identity_cert_refreshes_total{result="ok"} 3` unchanged over the same span — `metrics/stage1-1.txt` (via `pod-series.sh`)
- `probe-tcp-new-b`: refresh timestamp `1789214685.039807`, refreshes `ok=3`, unchanged `post-1` through `stage1-10`, and still unchanged at `stage2-client-a` (`12:30:14Z`) and `stage3-server` (`12:32:07Z`) — it is not itself restarted until `stage4-all` (`12:32:20Z`), where the timestamp finally jumps to `1789216342.87` (a new pod, `probe-tcp-new-b-f9b654d5d-pmbgl`)
- `server`: refresh timestamp `1789214682.0416549`, refreshes `ok=3`, unchanged `post-1` through `stage1-10` and `stage2-client-a`; it is restarted at `stage3-server`, where the timestamp jumps to a new pod's value

None of these three ever refreshes while its own pod survives — the only way any of them gets a fresh leaf is a pod restart. The gated samples confirm the connections stayed broken throughout the no-restart window: `gates/stage1-norestart.txt:16` `cell pair=A ok=0 fail=10 status=classified`, `gates/stage1-norestart.txt:27` `cell pair=B ok=0 fail=10 status=classified` — ten failed fresh-connection attempts each, taken between `12:27:49Z` and the stage's leaf-state read at `12:28:32Z` (`gates/stage1-norestart.txt:28-30`, still showing the same expired-leaf `expiry=` values and `ok=3` refresh counts as before the outage).

`logs/pre-stage2/probe-tcp-new-b-64dbdd7f5c-r6q68-linkerd-proxy.txt` (the proxy log for the still-unrestarted pod, captured after `recover-identity-up`) shows no successful certify call after recovery; the process kept the leaf it minted before the outage and never asked identity for a new one. Slice 1's open question — whether a proxy that lived through an issuer change re-certifies without a restart — has the same answer for a plain identity outage with no credential change at all: it does not. A `linkerd-proxy` renews on its own timer well before expiry, not on demand after an outage; once its leaf has already expired, only a restart gets it a new one.

## O3 — pods created during the outage never become Ready until identity returns

**Verdict: supported**, run `20260912T115519Z`.

`probe-new` (applied at F+58s, `timeline.log:27`) and the new `restart-target` replica (rolled at F+59s, `timeline.log:28`) are both created during the outage. Every snapshot from `post-1` (`12:08:21Z`) through `post-28` (`12:21:51Z`, the last tick before recovery) shows the same state for `probe-new-ddf9946ff-75rp8`:

- `pods/post-28-probe-new-ddf9946ff-75rp8-describe.txt:17`: `Status: Pending`
- Conditions: `Ready False` / `ContainersReady False`, reason `ContainersNotReady`, message `containers with unready status: [linkerd-proxy idle]`
- The `linkerd-proxy` container (a restartable init container in this proxy model) is climbing restarts: `Restart Count: 5`, last state `Terminated`/`Error`, message `Failed to resolve control-plane component ... DNS error: no records found for Query { name: Name("linkerd-identity-headless.linkerd.svc.cluster.local.") ...}` — expected, since identity has 0 replicas and so no Service endpoints
- `Events:` (`pods/post-28-probe-new-ddf9946ff-75rp8-describe.txt:207-208`): `Warning Unhealthy (x481 over 13m) ... Startup probe failed: HTTP probe failed with statuscode: 503` and `Normal Killing (x5 over 11m) ... Init container linkerd-proxy failed startup probe`
- The main `idle` container never starts: `State: Waiting`, `Reason: PodInitializing`

`restart-target-6c8df6454-2mf72` shows the identical pattern at `post-28` (`Status: Pending`, its `linkerd-proxy` init container at `Restart Count: 5`).

The first snapshot where either pod is Ready is `stage1-1`, the very first tick after recovery (`12:23:13Z`, F+951s, 16 s after `recover-identity-up`): `pods/stage1-1-probe-new-ddf9946ff-75rp8-describe.txt` reads `Status: Running`, `Ready True`, `ContainersReady True`; `pods/stage1-1-restart-target-6c8df6454-2mf72-describe.txt` reads `Status: Running`. Both pods went from perpetually-restarting-and-never-Ready to Ready within one 30 s tick of identity's return, and not before.

## Control-plane identity

`controlplane/fault-before.txt:3` (last snapshot before the fault): `pod linkerd/linkerd-identity-84cfd4665c-6ct2t uid=b99ea65e-59af-42d1-a793-6a31c4206f37 start=2026-09-12T11:56:59Z ... trust=037caa252dc40495aa25d8c0f61c8accb2d3ae6f1a8d769454f0edbd02939f96`

`controlplane/recover-identity-up.txt:3` (after recovery): `pod linkerd/linkerd-identity-84cfd4665c-mzljs uid=9736df06-947e-43e1-b5d9-8863f4b4a923 start=2026-09-12T12:22:58Z ... trust=037caa252dc40495aa25d8c0f61c8accb2d3ae6f1a8d769454f0edbd02939f96`

Different pod name and UID, same pod-template hash (`22d8b8d6d2b66a28c5d066f103f6568c684c35821c5dfe220ad244b6727cf59d`, unchanged across all 67 `controlplane/*.txt` snapshots) and the same `trust=` hash before and after. Recovery ran a brand-new identity process (`fault-after.txt` has no `linkerd-identity-` pod line at all — 0 replicas) while the credentials it serves stayed byte-for-byte the same, exactly as the credential-plan invariant requires.

**A fact recorded but not settled by this run's evidence.** `linkerd-destination-8568fff678-9fssl` and `linkerd-proxy-injector-565558dfc6-p7mgf` both started at `2026-09-12T11:56:59Z` (`controlplane/baseline.txt:2,4`) and show `restarts=0` in every one of the 67 control-plane snapshots, including `stage4-all` after every workload had been restarted — only `linkerd-identity` itself was ever restarted (scaled to 0 and back). The outage (935 s) outlasts the 5-minute leaf, so on the same logic as O1 and O3, `linkerd-destination`'s and `linkerd-proxy-injector`'s own proxy sidecars should also have had their leaves expire during the outage. The collector keeps only identity's own control-plane logs; `logs/pre-stage2/` (and the other `logs/pre-stage*/` labels) hold no `linkerd-destination-*` or `linkerd-proxy-injector-*` files at all — confirmed by listing the directory. So this run cannot show what those two pods' proxies actually did with their own certificates during the outage, nor directly attribute any specific downstream effect to it. It is left here as an open question, not a claim: **did `linkerd-destination`'s and `linkerd-proxy-injector`'s own proxies re-certify without a restart (which would be a second, unlabelled instance of O2's question), or did their outbound mTLS to other control-plane components fail silently in a way this collector never captured?** Answering it would need those two pods' own `linkerd-proxy` logs collected in a future run.

## The restart stages after recovery

| Stage | Restarted | Gate | Pair A samples | Pair B samples | Control (same stage) |
| --- | --- | --- | --- | --- | --- |
| `stage1-norestart` | — | `none` | `ok=0 fail=10` | `ok=0 fail=10` | `ok=10 fail=0` / `ok=10 fail=0` |
| `stage2-client-a` | `probe-tcp-new` | `pass` | `ok=0 fail=10` | `ok=0 fail=10` | `ok=10 fail=0` / `ok=10 fail=0` |
| `stage3-server` | `server` | `pass` | `ok=0 fail=10` | `ok=0 fail=10` | `ok=10 fail=0` / `ok=10 fail=0` |
| `stage4-all` | `probe-http probe-new probe-tcp-new-b probe-tcp-stream restart-target` | `pass` | `ok=0 fail=10` | `ok=0 fail=10` | `ok=10 fail=0` / `ok=10 fail=0` |

(O's cells from `bash $S/gate-table.sh $O`; control's from the same command against `runs/00-baseline-control/20260912T065110Z`.)

This is worth calling out with care rather than folding quietly into the table above: **every gated sample failed in O, at all four stages, including `stage4-all` after every meshed workload — client A, `server`, and client B — had been restarted.** The control shows the opposite at every stage: `ok=10 fail=0`, so the control-plane rollout choreography itself, absent any TLS disruption, does not cause probe failures at these gates. The failure *mode* changes partway through O, though, and that mode change is itself evidence: `stage1-norestart`'s ten failures per pair are all `socat_rc=1`, `Connection reset by peer` (`gates/stage1-norestart.txt`, same wording as the O1 quotes above) — a TLS-attributable reset, consistent with both sides still holding expired leaves. From `stage2-client-a` on, every failure is `socat_rc=0 reply= err=` — the TCP connection is accepted but no data comes back (`gates/stage2-client-a.txt:17`, `gates/stage3-server.txt:18`, `gates/stage4-all.txt:49`) — even at `stage4-all`, after the restarted pair's own leaves are fresh (e.g. `probe-tcp-new-7d9c765c94-jbxf6` shows `expiry=1789216663.0`, newly issued, in the `stage4-all` leaf line of `gates/stage4-all.txt`). That a *TLS-clean* pair (fresh leaves on both sides) still gets an accepted-but-silent connection is not explained by anything this run captured about the probe pair's own certificates. Per the fact above, `linkerd-destination` and `linkerd-proxy-injector` were never restarted and their own proxy logs were not collected, so whether their state during or after the outage is implicated is an inference, not a demonstrated cause — stated here as an open question the article should not resolve past what these artifacts show.

## For the comparison with issuer and anchor expiry

- **Fault:** identity scaled to 0 replicas for 935 s (nominal 900 s configured); no credential ever changes — same trust anchor, same issuer, same identity Deployment pod-template hash throughout (`controlplane/*.txt`, 67 snapshots, one `template_sha256` value).
- **Was the signer valid?** Yes, throughout. The issuer certificate itself never expired or changed; what was unavailable was the identity *service* that signs CSRs and serves it, not the signer's own validity.
- **Could workloads reach the identity service?** No, for the full 935 s outage: identity had 0 replicas, so `linkerd-identity-headless.linkerd.svc.cluster.local` had no endpoints (confirmed by the `probe-new` proxy's own DNS-resolution error, `pods/post-28-probe-new-ddf9946ff-75rp8-describe.txt`).
- **How failure spread:** existing proxies kept working on their already-issued leaves until each leaf's own expiry (O1, supported) — a `Connection reset by peer` at that point, not a hang. New pods created during the outage never became Ready; their `linkerd-proxy` sidecar failed its startup probe waiting on identity (O3, supported). Once a proxy's leaf expired, it did not renew on its own after identity came back — only a pod restart got it a fresh leaf (O2, falsified for the no-restart window). After every meshed workload was restarted, probes into `server` still failed, now as accepted-connection-no-reply rather than reset — a change this run cannot fully explain (see "restart stages" above and the control-plane-identity open question).
- **What recovery took:** identity scaled back to 1 (a new pod, new UID, same credentials); a 300 s no-restart window still failed on every gated sample; only `stage2`/`stage3`/`stage4` (targeted restarts of client A, `server`, then everything else) restored fresh leaves to the probe pairs, and even then the connection samples kept failing.
- **What `linkerd check` showed:** not part of this scenario's evidence set — O's task did not run `linkerd check` during the outage; no claim is made here either way.

## What this means for the article

- O's design § 13 acceptance condition is **met**: the credential/configuration invariant held, the 935 s outage exceeded the 320 s leaf-plus-skew bound, and the no-restart window was evaluated before any restart stage. This scenario is reproduced, in the sense § 13 defines, at `demos/cert-hygiene/runs/09-identity-outage/20260912T115519Z` against control `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z`.
- O1 (proxies keep working on their current leaf, then fail once it expires) is **supported**: both probe pairs' first failures land within 3 s of their pair's later leaf expiry, well inside the 320 s bound, and the failure mode is a TLS-consistent connection reset.
- O2 (expired proxies re-certify on their own, no restart) is **falsified** by the no-restart window: refresh timestamps and refresh counters for every proxy whose leaf expired sat frozen through the entire `stage1-norestart` period, and the gated samples kept failing throughout it. In this lab (Linkerd `edge-26.9.1`, 5 m leaf, 900 s outage), only a pod restart obtains a fresh leaf after an outage this long — this closes the question slice 1 left open, for the plain-outage case with no credential change.
- O3 (outage-created pods never Ready until identity returns) is **supported**: both new pods stayed `Pending`/not-Ready with a climbing-restart `linkerd-proxy` sidecar for the full outage and reached Ready within one 30 s tick of identity's return.
- One run is one run: these are the failure and recovery behaviours of this identity outage, in this lab, with this Linkerd build and these lifetimes — not a general claim about identity outages of other durations, other Linkerd versions, or other credential states.
- Flagged as an open question, not a finding: probes into a freshly-restarted, TLS-clean pair still failed as "connection accepted, no reply" through `stage4-all`, and `linkerd-destination`/`linkerd-proxy-injector` were never restarted during recovery with their own proxy logs uncollected. The article should present this as something this run observed but cannot explain, not resolve it either way.
