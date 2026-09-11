# Evidence: scenario #5, identity issuer expiry

- **Run:** `demos/cert-hygiene/runs/05-issuer-expiry/20260911T021157Z` — `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260911T014417Z` — `evidence_valid=yes`, same harness tree (both `git-state.txt` files: `harness_tree_sha256=e1d716bea90ae9ff4ca65ad3c16603b342bdb4a49705830f2cff19b5360e0cff`, `demo_repo_dirty=false`)
- **Versions:** `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `kubernetes_version=v1.36.4+k3s1` (`versions.txt`); proxy `release 2.368.0 (a66af81)` (`logs/pre-recover/identity-proxy.txt`). One OrbStack VM running a single k3s node.
- **Lifetimes:** anchor 720h (`config_ANCHOR_LIFETIME=720h`), issuer 15m (`config_ISSUER_LIFETIME=15m`), leaf 5m (`identity_args` has `-identity-issuance-lifetime=5m0s` and `-identity-clock-skew-allowance=20s`). The replacement issuer was 8760h (`config_REPLACEMENT_ISSUER_LIFETIME=8760h`). The control used an 87600h anchor and an 8760h issuer.
- **T_mark (issuer notAfter):** 2026-09-11T02:30:54Z. `timeline.log` has `t_mark epoch=1789093854 utc=2026-09-11T02:30:54Z`, and `certs/issuer-initial.txt` has `Not After : Sep 11 02:30:54 2026 UTC`.

**Evidence gaps and pending re-run.** This run captured no workload `linkerd-proxy` logs: on edge-26.9.1 the proxy is a native-sidecar init container, and the collector at this run's harness tree walked only `.spec.containers`. It also captured no probe line between T+574 and T+1211. Both gaps were fixed in the harness afterwards. Until a re-run at the fixed harness, these stay open: H3's mechanism, H4 for workload proxies, which side rejected the handshakes in H5, and why H8's pre-existing proxies never re-certified. The `evidence_valid=yes` verdicts of this run and its control were computed by the harness at tree `e1d716be…`; validity requirements added to the harness later apply to future runs only.

Paths are relative to the run directory unless they start with `demos/`. Times are UTC. `T+N` means N seconds after T_mark. The `--timestamps` prefixes in `logs/` are container-runtime timestamps in the VM's local time (−07:00), so `19:30:57` is 02:30:57Z. The leaf-expiry gauge is `control_identity_cert_expiration_timestamp_seconds` (`config_LEAF_EXPIRY_METRIC` in `versions.txt`).

This is one run, on one Linkerd version, with these lifetimes. It shows what happened here, not what always happens. Anything marked **Source-derived** comes from [linkerd-source-notes.md](linkerd-source-notes.md) or the spec's § 4.2; it was not observed in this run.

## Where the evidence is, and what is missing

- **Probe history.** In this run, `probes/<probe>.log` holds only the pods created by the stage-2 restarts; the first line is `2026-09-11T02:51:08Z` (T+1214). The collector writes those files at the end with `kubectl logs deploy/<probe>` (`demos/cert-hygiene/lab/collect.sh`, line 129, at the run's `demo_repo_commit` 8d158f4). By then stage 2 had replaced every probe pod. The original probe pods' history runs from start-up to T+574 and is in `logs/pre-recover/<pod>-probe.txt`, so H5, H6 and the HTTP observation are judged from there. No probe line covers T+574 to T+1211, when those pods were replaced.
- **Proxy logs.** No workload `linkerd-proxy` container log was captured, in either log snapshot. The only proxy log is the identity pod's, in `identity-proxy.txt`. This limits the judgement on H3's competing prediction and on H4.

## Timeline

| UTC | T+ | Marker in `timeline.log` |
| --- | --- | --- |
| 02:11:57 | −1137 | `reset mode=short` |
| 02:16:17 | −877 | `tick baseline` |
| 02:29:58 | −56 | `tick fault-minus60` |
| 02:30:44 | −10 | `tick fault-minus10` |
| 02:30:54 | 0 | T_mark (issuer notAfter) |
| 02:31:04 | +10 | `tick fault-plus10` |
| 02:31:55 | +61 | `applied probe-new`, `rolled restart-target`, `tick post-1` |
| 02:40:25 | +571 | `tick post-18`, the last post-expiry tick |
| 02:40:29 | +575 | `recover`, `recover-apply linkerd upgrade with the replacement issuer; no trust-anchor flag` |
| 02:41:02 | +608 | `issuer-updated IssuerUpdated event seen 31s after apply`, `tick recover-1` |
| 02:45:58 | +904 | `tick recover-9` (recovery gate still unmet) |
| 02:46:05 | +911 | `restart stage 1: the workloads that never became Ready (probe-new, restart-target)` |
| 02:50:59 | +1205 | `tick recover-s1-9` (gate still unmet) |
| 02:51:05 | +1211 | `restart stage 2: every lab Deployment, as Linkerd's issuer-rotation guide directs` |
| 02:51:48 | +1254 | `recovered at tick recover-s2-2`, `recovery after stage-2 restarts`, `tick verify` |
| 02:51:55 | +1261 | `done` |

According to `logs/final/identity.txt`, the identity controller loaded the replacement issuer at 02:41:00 (T+606).

## H1 — refresh cadence approaching T_mark

**Verdict:** confirmed.

**Evidence:** These are the `server` proxy's gauges, from the `== lab/server-577d5dfdbd-9tk8f :4191` section of `metrics/<tick>.txt`. There is one row for each new leaf.

| tick | `refresh_timestamp_seconds` | `expiration_timestamp_seconds` | refresh at | gap since previous refresh | lifetime left at refresh |
| --- | --- | --- | --- | --- | --- |
| baseline | 1789092966.8594118 | 1789093286.0 | T−887.1 | — | 319.1 s |
| pre-8 | 1789093190.273353 | 1789093510.0 | T−663.7 | 223.4 s | 319.7 s |
| pre-16 | 1789093414.0944598 | 1789093734.0 | T−439.9 | 223.8 s | 319.9 s |
| pre-23 | 1789093638.0407055 | 1789093854.0 | T−216.0 | 223.9 s | 216.0 s |
| pre-28 | 1789093789.2304786 | 1789093854.0 | T−64.8 | 151.2 s | 64.8 s |
| fault-minus10 | 1789093834.586681 | 1789093854.0 | T−19.4 | 45.4 s | 19.4 s |
| fault-plus10 | 1789093848.1886087 | 1789093854.0 | T−5.8 | 13.6 s | 5.8 s |

Each gap is 70% of the lifetime left at the previous refresh: 0.7 × 319.1 = 223.4, 0.7 × 216.0 = 151.2, 0.7 × 64.8 = 45.4, and 0.7 × 19.4 = 13.6. The identity controller issued matching leaves (`logs/pre-recover/identity.txt`; all five lab proxies share the `default.lab` identity):

```
time="2026-09-11T02:27:18Z" ... issued certificate for default.lab.serviceaccount.identity.linkerd.cluster.local until 2026-09-11 02:30:54 +0000 UTC
time="2026-09-11T02:29:49Z" ... issued certificate for default.lab... until 2026-09-11 02:30:54 +0000 UTC
time="2026-09-11T02:30:34Z" ... issued certificate for default.lab... until 2026-09-11 02:30:54 +0000 UTC
time="2026-09-11T02:30:48Z" ... issued certificate for default.lab... until 2026-09-11 02:30:54 +0000 UTC
```

The 10 s floor shows in the identity pod's own proxy. Its last leaf was issued at `02:30:47Z ... until 2026-09-11 02:30:54` (`logs/pre-recover/identity.txt`, line 55), and its next attempt came at `current time 2026-09-11T02:30:57Z` (`logs/pre-recover/identity-proxy.txt`, line 36). That is 10 s later, although 70% of the roughly 6 s it had left would have been under 5 s.

**Notes:**
- **Source-derived:** the proxy refreshes at 70% of the remaining lifetime, clamped to [10 s, 24 h] (notes § 2).
- The first leaf clamped to the issuer is the one issued at T−216; before it, each leaf had about 320 s (5 m plus 20 s skew). The cadence therefore tightened only over the issuer's last 216 s.
- **Inference from the source-derived 10 s floor:** for the workload proxies, the refresh after T−5.8 would have fallen at T+4.2, after expiry. No workload attempt at T+4.2 is recorded. What is observed is that their refresh gauge never moved again (see H4 and H8).
- With the default 24 h leaf the same shape would stretch across the issuer's last day. That is an inference; it was not observed.

## H2 — simultaneous leaf expiry

**Verdict:** confirmed.

**Evidence:** `metrics/fault-minus10.txt` (`sampled_at_epoch=1789093844`, T−10), every lab proxy:

```
== lab/probe-http-586cfdddb4-zczc9 :4191
control_identity_cert_expiration_timestamp_seconds 1789093854.0
== lab/probe-tcp-new-76f5d56859-nb79h :4191
control_identity_cert_expiration_timestamp_seconds 1789093854.0
== lab/probe-tcp-stream-5f4ccc76bc-w7wcg :4191
control_identity_cert_expiration_timestamp_seconds 1789093854.0
== lab/restart-target-554865b545-2nj5w :4191
control_identity_cert_expiration_timestamp_seconds 1789093854.0
== lab/server-577d5dfdbd-9tk8f :4191
control_identity_cert_expiration_timestamp_seconds 1789093854.0
```

1789093854 is the `t_mark epoch`. The control-plane proxies were clamped the same way (`logs/pre-recover/identity.txt`, lines 47–49): `02:30:33Z issued certificate for linkerd-identity... until 2026-09-11 02:30:54`, `02:30:34Z ... linkerd-destination... until 2026-09-11 02:30:54`, and `02:30:34Z ... linkerd-proxy-injector... until 2026-09-11 02:30:54`.

**Notes:** Every mesh identity in the cluster, control plane included, expired in the same second. Traffic did not fail in the same second (see H5, H6 and the HTTP observation).

## H3 — identity refuses CSRs

**Verdict:**
- **Controller behaviour: confirmed.** The controller stayed running and ready. It refused every CSR that reached it, and each refusal produced one `IssuerValidationFailed` event.
- **Competing prediction, its observable consequence: confirmed.** Every refused CSR came from the identity pod's own proxy.
- **Competing prediction, its mechanism: inconclusive.** The prediction says the other proxies fail at the TLS handshake. That would appear only in workload proxy logs, which were not captured.

**Evidence:**
- **Running and ready.** `pods/post-18.txt` (T+571): `linkerd-identity-c5fdfb7b5-khzvl 2/2 Running 0 24m`.
- **Refusals.** `logs/final/identity.txt` has 61 `could not process CSR` lines, from `02:30:57Z` (T+3) to `02:40:58Z` (T+604). The first:
  `level=error msg="could not process CSR because of CA cert validation failure: x509: certificate has expired or is not yet valid: current time 2026-09-11T02:30:57Z is after 2026-09-11T02:30:54Z ... - CSR Identity : linkerd-identity.linkerd.serviceaccount.identity.linkerd.cluster.local"`.
  All 61 name the same CSR identity, `linkerd-identity.linkerd.serviceaccount.identity.linkerd.cluster.local`. No certificate was issued between T_mark and the reload at 02:41:00.
- **Events.** The first `Warning IssuerValidationFailed deployment/linkerd-identity` event was already present at T+10 (`events/fault-plus10.txt`). `events/issuer-updated.txt` (T+608) holds nine separate events, 02:30:57Z to 02:32:18Z. It also holds one `(combined from similar events)` event with COUNT `52`, whose latest message reads `current time 2026-09-11T02:40:58Z`. 9 + 52 = 61, so there was one event per refused CSR.
  - The brief's `grep -c IssuerValidationFailed events/*.txt` prints 10 for the later snapshots. That undercounts, because Kubernetes folds repeats into the combined event; the COUNT column holds the real number.
- **Workload proxies' CSRs never arrived.** From `fault-plus10` to `recover-s2-1`, the `server` proxy's counters stay at `control_identity_cert_refreshes_total{result="ok"} 7` and `control_identity_cert_refreshes_total{result="error"} 0` (`metrics/post-18.txt`, `metrics/recover-s2-1.txt`). The other pre-existing lab proxies show the same (`metrics/recover-1.txt`).
  - `probe-new` and the new `restart-target` pod, which were created after T_mark, show `expiration_timestamp_seconds 0.0` with `ok` and `error` both `0` at `recover-1`.
  - Over the same period the `server` proxy's identity-client request counter kept rising. `control_identity_balancer_queue_requests_total{addr="linkerd-identity-headless.linkerd.svc.cluster.local:8080"}` was `8` at `fault-plus10` and `22` at `post-18`.

**Notes:**
- **Source-derived:** the identity pod's proxy requires TLS on port 8080, and its own leaf also expired at T_mark (spec § 4.2).
- The pattern fits that prediction. **Observed:** the identity pod's proxy reaches the controller over localhost (`controller{addr=localhost:8080}` in `logs/pre-recover/identity-proxy.txt`, line 11), and it is the only proxy whose CSRs arrived. **Inference, not observed:** localhost traffic skips the identity pod's inbound TLS requirement, which would make this the one proxy that requirement did not stop.
- This run cannot show whether the other proxies failed at the handshake. Deciding it needs the `linkerd-proxy` logs of a workload pod and of `probe-new`, between T_mark and the reload.
- **Source-derived:** a failed certify logs `Failed to obtain identity` (notes § 2). The workload proxies' `result="error"` counter never moved while their request counter rose. That suggests their attempts never completed as certify failures at all. This is an inference.

## H4 — `Failed to obtain identity`, retried every 10 s

**Verdict:** confirmed for the identity pod's own proxy. Inconclusive for workload proxies, because their logs were not captured.

**Evidence:** `logs/pre-recover/identity-proxy.txt`, lines 36, 38 and 40:

```
ERROR ... linkerd_proxy_identity_client::certify: Failed to obtain identity error=code: 'Unknown error', message: "x509: certificate has expired or is not yet valid: current time 2026-09-11T02:30:57Z is after 2026-09-11T02:30:54Z ..."
ERROR ... Failed to obtain identity ... current time 2026-09-11T02:31:07Z is after 2026-09-11T02:30:54Z ...
ERROR ... Failed to obtain identity ... current time 2026-09-11T02:31:17Z is after 2026-09-11T02:30:54Z ...
```

`logs/final/identity-proxy.txt` holds 61 of these lines. The first carries the runtime timestamp `19:30:57.966` (T+3) and the last `19:40:58.392` (T+604), so there are 60 intervals over about 600 s: every 10 s.

No `Failed to obtain identity` line appears anywhere in the run outside the two `identity-proxy.txt` files. As noted above, the `server` proxy's `control_identity_balancer_queue_requests_total` rose from 8 at `fault-plus10` to 22 at `post-18`, while `refreshes_total{result="error"}` stayed at 0.

**Notes:**
- The identity proxy's error text is the controller's validation error, passed through as `code: 'Unknown error'`. That matches source, which says identity returns a raw error rather than a gRPC status (notes § 3).
- For the workload proxies, the request counter shows that attempts continued, but the counter does not count certify attempts one-for-one. It cannot settle the cadence, and none of those attempts ended in a recorded error.
- Workload `linkerd-proxy` logs would decide both the log line and the cadence.

## H5 — new connections fail at T_mark

**Verdict:** confirmed, to the probe's 2 s resolution.

**Evidence:** `logs/pre-recover/probe-tcp-new-76f5d56859-nb79h-probe.txt`:

```
2026-09-11T02:30:54Z probe-tcp-new seq=440 ok
2026-09-11T02:30:56Z probe-tcp-new seq=441 fail socat_rc=1 reply= err=2026/09/11 02:30:56 socat[2211] E read(5, 0xffffa50e7000, 8192): Connection reset by peer
```

The last `ok` is at T+0 and the first `fail` at T+2. After T_mark there are 285 `fail` lines and no `ok` line, up to the last captured line, `2026-09-11T02:40:28Z probe-tcp-new seq=725 fail` (T+574). The only earlier failure is `seq=1` at 02:16:08Z, during probe start-up before baseline.

**Notes:** The application saw a TCP reset rather than a TLS error. That fits the proxies terminating mTLS on its behalf, but that is an inference. The run does not record which side rejected the handshake: the client proxy rejecting `server`'s expired leaf, or `server`'s proxy rejecting the client's. Workload proxy logs would show it.

## HTTP probe (no prediction)

**Observed:** `probe-http` did not fail between T_mark and the end of its captured history. In `logs/pre-recover/probe-http-586cfdddb4-zczc9-probe.txt`, `2026-09-11T02:30:54Z probe-http seq=440 ok http=200` is followed by 285 `ok` lines and no `fail`, ending at `2026-09-11T02:40:28Z probe-http seq=725 ok http=200` (T+574). Throughout, both proxies on that path held leaves that had expired at T_mark. `metrics/post-18.txt` shows `control_identity_cert_expiration_timestamp_seconds 1789093854.0` for both `probe-http-586cfdddb4-zczc9` and `server-577d5dfdbd-9tk8f`.

**Notes:** The evidence does not show why HTTP kept working. The spec offers an explanation: requests reuse a proxy-to-proxy connection opened before T_mark, so no new handshake takes place. That is source-derived reasoning; no connection-level metrics or proxy logs were captured to confirm it. How much longer it would have kept working is unknown, because the record stops at T+574 and the pod was replaced at T+1211.

## H6 — established session survives

**Verdict:** confirmed for the 574 s after T_mark that were recorded.

**Evidence:** `logs/pre-recover/probe-tcp-stream-5f4ccc76bc-w7wcg-probe.txt` has exactly one `connect` line: `2026-09-11T02:16:08Z probe-tcp-stream seq=0 conn=2859b050-1789092968 connect target=server.lab.svc.cluster.local:9000` (T−886). All 728 probe lines carry `conn=2859b050-1789092968`.

After T_mark there are 286 `ok` lines. They include `2026-09-11T02:30:56Z probe-tcp-stream seq=442 conn=2859b050-1789092968 ok`, logged the same second `probe-tcp-new` first failed. The last is `2026-09-11T02:40:28Z probe-tcp-stream seq=727 conn=2859b050-1789092968 ok` (T+574). There is no `closed` or `end-of-stream` line.

**Notes:**
- What happened to the session after T+574 is not recorded. Stage 2 terminated its pod: `pods/recover-s2-1.txt` shows `probe-tcp-stream-5f4ccc76bc-w7wcg 2/2 Terminating`.
- The brief's command against `probes/probe-tcp-stream.log` finds the stage-2 pod instead of this one; see observation 5 below.
- **Source-derived:** TLS does not revalidate a peer's certificate in the middle of a session (spec § 4.2).

## H7a — a pod created after T_mark never becomes Ready

**Verdict:** confirmed for the post-expiry window, T+61 to T+571.

**Evidence:** `pods/post-18-probe-new-ddf9946ff-wn2np-describe.txt` (T+571):

```
Initialized                 False
Ready                       False
Warning  Unhealthy  3m29s (x242 over 8m30s)  kubelet  spec.initContainers{linkerd-proxy}: Startup probe failed: HTTP probe failed with statuscode: 503
Normal   Killing    91s (x3 over 6m31s)      kubelet  spec.initContainers{linkerd-proxy}: Init container linkerd-proxy failed startup probe
```

In `pods/post-18-probe-new-ddf9946ff-wn2np.yaml`, the `initContainerStatuses` entry for `linkerd-proxy` shows `ready: false`, `restartCount: 3` and `started: false`. `pods/post-18.txt` lists `probe-new-ddf9946ff-wn2np 0/2 Init:1/2 3 (61s ago) 8m31s`. The proxy never held a leaf: `metrics/post-18.txt` shows `control_identity_cert_expiration_timestamp_seconds 0.0` for this pod.

**Notes:**
- The proxy runs as a native sidecar: an init container with a startup probe. So "never Ready" was not a pod waiting quietly: the kubelet killed and restarted the proxy three times in 8m31s.
- **Source-derived:** the proxy waits for an identity before it serves (notes § 4).
- After the issuer was replaced, the same pod became Ready without the harness restarting it. `pods/recover-2-probe-new-ddf9946ff-wn2np-describe.txt` (T+652) shows `Ready True`, and `metrics/recover-2.txt` shows its first leaf refresh at `1789094471.3766702` (T+617.4).

## H7b — the rollout stalls and the old pod keeps running

**Verdict:** confirmed.

**Evidence:**
- **Rollout.** `pods/post-18-rollout.txt`: `Waiting for deployment "restart-target" rollout to finish: 1 old replicas are pending termination...` and `error: timed out waiting for the condition`.
- **Replacement pod.** `pods/post-18-restart-target-5cffc96d6b-956wt-describe.txt` shows `Ready False`, the same startup-probe failures (`x241 over 8m30s`), and `Killing ... (x3 over 6m31s)`.
- **Old pod.** `pods/post-18-restart-target-554865b545-2nj5w-describe.txt` shows `Status: Running` and `Ready True`.
- **Pod listing.** `pods/post-18.txt` has `restart-target-554865b545-2nj5w 2/2 Running 0 24m` next to `restart-target-5cffc96d6b-956wt 0/2 Init:1/2 3 (61s ago) 8m31s`.

**Notes:**
- The old pod stayed Ready even though its own leaf had expired at T_mark (`metrics/post-18.txt`: `restart-target-554865b545-2nj5w`, `expiration_timestamp_seconds 1789093854.0`). Its readiness did not reflect the expired credential.
- After the issuer was replaced, the rollout completed during the `recover-1` tick. The old pod is still listed `2/2 Running` in `pods/recover-1.txt`; the rollout check taken later in that tick reports `deployment "restart-target" successfully rolled out` (`pods/recover-1-rollout.txt`); the old pod is gone in `pods/recover-2.txt`.

## H8 — recovery chain without restarts

**Verdict:** falsified.
- The first two links held: the Secret changed, and identity hot-reloaded it without a restart.
- The third link held only for proxies that had no identity yet. None of the pre-existing lab proxies, whose leaves expired at T_mark, re-certified. Four of them (`probe-http`, `probe-tcp-new`, `probe-tcp-stream`, `server`) went the 605 s between the reload (T+606) and the stage-2 restarts (T+1211) without doing so. The fifth, the old `restart-target` pod, never re-certified before its rollout removed it: it is listed `2/2 Running` in `pods/recover-1.txt`, the rollout reports complete in `pods/recover-1-rollout.txt`, and the pod is gone in `pods/recover-2.txt`.
- The harness reached recovery only after stage 2 restarted every lab Deployment. The spec's "no pod restarts are needed" contradicted Linkerd's documented procedure: the [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/), to which "Replacing expired certificates" points for the issuer-only case, says to restart the proxies of all injected workloads after applying a new issuer. This run is consistent with the documentation. It shows that a full restart worked, not which restarts were necessary: stage 1 restarted `probe-new` and `restart-target`, which had already become Ready by `recover-2`, and stage 2 restarted every lab Deployment at once (`recover/restart-stage2.txt`), including `server`, which spec § 2 otherwise never restarts.

**Evidence, link by link:**

1. **The Secret is updated.** `resourceVersion=637` in `secrets/pre-recover-identity-issuer.txt` becomes `resourceVersion=2611` in `secrets/recover-1-identity-issuer.txt`. `recover/linkerd-upgrade.txt` records `secret/linkerd-identity-issuer configured` and `configmap/linkerd-identity-trust-roots unchanged`. `trust-invariant.txt` records `ok: trust configuration identical across 3 snapshots`.
2. **Identity loads it.** `logs/final/identity.txt` at `02:41:00Z` (T+606, 31 s after the apply) has `msg="Issuer cert loaded" invalid_after=1820630429 process_clock_time=1789094460 ttl_seconds=31535969`, then `msg="Updated identity issuer"`. `events/issuer-updated.txt` has `Normal IssuerUpdated deployment/linkerd-identity linkerd-identity Updated identity issuer`. `issuer_cert_ttl_seconds` goes from `-572.018225457` (`metrics/post-18.txt`) to `3.1535966230955437e+07` (`metrics/recover-1.txt`).
3. **Proxies re-certify.** Only proxies without an identity did.
   - After the reload, identity issued in this order: `02:41:08Z ... linkerd-identity... until 2026-09-11 02:46:28`, `default.lab` at `02:41:11Z` and `02:41:12Z`, then `linkerd-proxy-injector` and `linkerd-destination` at `02:41:12Z`.
   - The two `default.lab` leaves went to the two lab pods that had no identity. `metrics/recover-2.txt` shows `probe-new-ddf9946ff-wn2np` refreshing at `1789094471.3766702` (T+617.4) and `restart-target-5cffc96d6b-956wt` at `1789094472.451799` (T+618.5).
   - The pre-existing proxies did not move. At `metrics/recover-s2-1.txt` (T+1212), `server-577d5dfdbd-9tk8f` still reads `expiration_timestamp_seconds 1789093854.0`, `refresh_timestamp_seconds 1789093848.1886087`, `refreshes_total{result="ok"} 7` and `{result="error"} 0`, the same as at `fault-plus10`. `probe-http`, `probe-tcp-new` and `probe-tcp-stream` show the same values through `recover-s2-1`, as did the old `restart-target` for as long as it was recorded (`metrics/recover-1.txt`; it is gone in `pods/recover-2.txt`).
   - `logs/final/identity.txt` shows 14 `default.lab` leaves issued after the reload, and each one lines up with a first certification or a refresh of a pod created after T_mark: 2 at 02:41:11–12, 2 at 02:44:55–56, 2 at 02:46:07 (stage 1), 2 at 02:49:51, and 6 at 02:51:07 (stage 2).
   - Meanwhile the `server` proxy kept sending identity requests that produced no result: `control_identity_balancer_queue_requests_total{addr="linkerd-identity-headless.linkerd.svc.cluster.local:8080"}` was `23` at `recover-1`, `49` at `recover-9`, and `78` at `recover-s1-9`.
4. **Probes recover.** No probe line covers the recover ticks, because the original probe pods' logs stop at T+574.
   - The harness's recovery gate is `_recovered_now` in `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`. It passes when the latest `probe-http` and `probe-tcp-new` lines are `ok` and both the `restart-target` and `probe-new` rollouts have finished.
   - The gate was not met at any of `recover-1` to `recover-9` or `recover-s1-1` to `recover-s1-9`, and this run did not record its inputs. At `recover-1`, `probe-new-ddf9946ff-wn2np` was still `0/2 Init:1/2` (`pods/recover-1.txt`), and at `recover-s1-1` the stage-1 replacements were `0/2 Init:0/2` (`pods/recover-s1-1.txt`), so at those two ticks the `probe-new` rollout check alone could have failed the gate.
   - From `recover-2` to `recover-9` and from `recover-s1-2` to `recover-s1-9`, both rollouts had completed: each `restart-target` rollout check reports `successfully rolled out`, and the listing shows a single `probe-new` pod, `2/2 Running`. At those ticks, by the gate's logic, a gated probe's latest line was not `ok`. This is an inference from the harness code, not a recorded probe line. The harness now writes each gate call's inputs to `recover/<tick>-gate.txt`, so future runs record them.
   - After stage 2 the new probe pods report: `probes/probe-tcp-new.log` has `2026-09-11T02:51:08Z probe-tcp-new seq=1 fail ... Connection reset by peer`, then `ok` from `2026-09-11T02:51:10Z probe-tcp-new seq=2 ok` (T+1216); `probes/probe-http.log` has `ok` from its first line, `2026-09-11T02:51:08Z probe-http seq=1 ok http=200`.
   - `timeline.log` has two `restart` markers (T+911 and T+1211) and ends with `recovery after stage-2 restarts`.

**Confound: control-plane restarts caused by `linkerd upgrade`.**
- `linkerd upgrade` re-rendered the control plane. `recover/linkerd-upgrade.txt` records `deployment.apps/linkerd-identity configured`, `deployment.apps/linkerd-destination configured` and `deployment.apps/linkerd-proxy-injector configured`.
- Two of those three deployments were restarted. `pods/recover-1.txt` (T+608) lists new `linkerd-destination-6664986575-w9mg9 0/4 Init:1/2 0 31s` and `linkerd-proxy-injector-754697546f-svljl 0/2 Init:1/2 0 31s` beside the old pods; the old pods are gone by `pods/recover-2.txt`.
- The identity pod was **not** restarted. `linkerd-identity-c5fdfb7b5-khzvl` keeps the same name and `RESTARTS 0` in every listing, and its AGE runs on from `24m` in `pods/post-18.txt` to `35m` in `pods/verify.txt`. Its log is one continuous process: the last refusal, at 02:40:58, carries `m=+1500.640944546`, and `Issuer cert loaded` follows two seconds later. So identity hot-reloaded the mounted Secret, and the leaves issued at 02:41:08–12 came from the reloaded process.
- The upgrade did not touch the lab pods. `pods/recover-9.txt` still lists, for example, `probe-http-586cfdddb4-zczc9 2/2 Running 0 29m` and `server-577d5dfdbd-9tk8f 3/3 Running 0 29m`.
- The confound leaves two questions open:
  - Would `probe-new` and the new `restart-target` have become Ready as quickly if `linkerd-destination` had not restarted at the same moment? The evidence cannot separate the two. **Source-derived:** a proxy's readiness waits on identity (notes § 4).
  - Did the old control-plane pods re-certify? There is one `linkerd-destination` issuance at 02:41:12, when the new pod was waiting in `Init:1/2`, and nothing shows that the old pod re-certified. Without the upgrade's restart, the destination and injector proxies may have stayed on expired leaves like the lab proxies. That is an inference; it was not observed.

**Notes:**
- In this run, H8's "no pod restarts are needed" held only for workloads that had never obtained an identity.
- The evidence does not show why the pre-existing proxies did not re-certify after the reload, and the source notes do not cover it. One untested explanation: a proxy holding an expired leaf cannot complete the TLS handshake to the identity service, even after identity's own proxy has a valid leaf again (it re-certified at 02:41:08).
- Workload `linkerd-proxy` logs from the recover phase would decide this. A longer recover window would show whether those proxies recover on their own eventually.

## Observations the hypotheses did not anticipate

1. **Only the identity pod's own CSRs reached the controller after T_mark.** All 61 refusals name its identity, and no workload proxy recorded a certify result (see H3).
2. **Proxies whose leaf had expired did not recover when the issuer was replaced.** They kept their T_mark expiry for the 605 s between the reload and stage 2 (see H8).
3. **Stage 1 was not enough.**
   - Stage 1 restarted `probe-new` and `restart-target`. Neither is on a probe's path, and both had already become Ready at `recover-2`, so the stage's label, "the workloads that never became Ready", did not fit this run.
   - The failing probe's path was `probe-tcp-new` → `server`. Both proxies kept leaves that expired at T_mark through `recover-s1-9` (`metrics/recover-s1-9.txt`: `expiration_timestamp_seconds 1789093854.0` for `probe-tcp-new-76f5d56859-nb79h` and `server-577d5dfdbd-9tk8f`).
   - Stage 2 replaced them. The six new lab pods were certified at 02:51:07, T+1213 (six `default.lab` lines in `logs/final/identity.txt`), and show `expiration_timestamp_seconds 1789095387.0` in `metrics/verify.txt`. `probe-tcp-new` reported `ok` from T+1216.
4. **`linkerd check` passed while leaves were expired.** Every check file from `recover-1` to `verify`, for both `linkerd check` and `linkerd check --proxy`, ends with the harness's `[exit 0]` line, and the line before it is `Status check results are √`. That includes `√ data plane proxies certificate match CA` (`checks/recover-5-check-proxy.txt`), while four lab proxies held leaves that expired at T_mark (`metrics/recover-5.txt`: `expiration_timestamp_seconds 1789093854.0` for `probe-http`, `probe-tcp-new`, `probe-tcp-stream` and `server`). **Source-derived:** that check compares each pod's injected trust-anchor PEM text with the `linkerd-identity-trust-roots` ConfigMap; it never inspects leaf certificates (notes § 7).
   - From T+10 to T+571, the only failure the checks reported was `× issuer cert is within its validity period`, with `issuer certificate is not valid anymore. Expired on 2026-09-11T02:30:54Z` (`checks/fault-plus10-check.txt`).
   - No check line mentions workload leaf certificates at any tick.
5. **After stage 2, the new stream probe's first connection was reset at once.** `probes/probe-tcp-stream.log` reads `2026-09-11T02:51:08Z probe-tcp-stream seq=0 conn=291875c8-1789095068 connect ...`, then `socat[12] E read(5, ...): Connection reset by peer`, then `2026-09-11T02:51:08Z probe-tcp-stream seq=1 conn=291875c8-1789095068 closed socat_rc=1 fail-closed, not reconnecting` (T+1214).
   - `probe-tcp-new`'s first attempt failed in the same second with the same error.
   - At that moment the old `server` pod, whose leaf had expired, was still `Terminating` (`pods/recover-s2-1.txt`). The evidence does not show which endpoint the connections reached.
   - The recovery gate excludes the stream probe by design, so the run reached `verify` with no live stream session. Spec § 4.3 lists "All probes `ok`" for the verify phase, and `probe-tcp-stream` did not meet that here.
   - This does not affect H6, which rests on the original pod's log.

## Control comparison

Every `‼` line in the #5 run's `checks/*.txt` is a certificate-lifetime warning:

- `‼ trust anchors are valid for at least 60 days` appears in all 142 check files, because the anchor was 720h: `root.linkerd.cluster.local will expire on 2026-10-11T02:15:54Z` (`checks/fault-minus10-check.txt`).
- `‼ issuer cert is valid for at least 60 days` appears in 62 files. These are both commands at every tick from `baseline` to `fault-minus10`: `issuer certificate will expire on 2026-09-11T02:30:54Z` (`checks/baseline-check.txt`).

The only `×` line is `× issuer cert is within its validity period`. It appears in 38 files: both commands at `fault-plus10` and at `post-1` through `post-18`.

The control's 102 check files (`demos/cert-hygiene/runs/00-baseline-control/20260911T014417Z/checks/`) contain no `‼` line and no `×` line, and each ends with the harness's `[exit 0]` line, with `Status check results are √` on the line before it. Neither run has a warning that is not about certificate lifetime, so there is no difference to explain. The control's `control-criteria.txt` records `result=ok`, with all eight criteria `ok`, including `ok: no certificate-lifetime warnings` and `ok: one stream connection`.

## What this means for the article brief

- **Issuer expiry: "failure spreads gradually"** (spec § 8; settled by #5).
  - Credential expiry was simultaneous: every leaf in the cluster, control plane included, expired at T_mark (H2).
  - Traffic did not fail gradually. It split by connection type: new mTLS connections failed within 2 s (H5), while an established TCP session and the HTTP probe kept working for the 574 s recorded (H6, HTTP).
  - Pods created or rolled after expiry never became Ready before the issuer was replaced, and a one-replica rollout stalled with the old pod still serving (H7a, H7b).
  - Replacing the issuer reloaded identity without a restart. But proxies whose leaves had already expired did not re-certify in the 605 s observed, and recovery came only after a restart of every lab Deployment (H8; that run used edge-26.9.1 with a 5m leaf). H8's no-restart hypothesis contradicted Linkerd's documented procedure, which says to restart the proxies of all injected workloads after applying a new issuer; the run is consistent with that documentation. It shows that a full restart worked, not which restarts were necessary: stage 1 hit pods that had already recovered, and stage 2 restarted everything at once, `server` included.
  - **Still resting on source reading or inference alone:**
    - why HTTP survived (connection reuse);
    - how long established or pooled connections survive past 574 s;
    - whether stuck proxies would ever recover on their own;
    - why they did not re-certify;
    - everything at the default 24h leaf lifetime.
- **"Exact `linkerd check` output for each failure"** (the #5 part).
  - `linkerd check` showed `‼ issuer cert is valid for at least 60 days` from the first tick for a 15-minute issuer. Its detail line gave the exact expiry (`issuer certificate will expire on 2026-09-11T02:30:54Z`, `checks/baseline-check.txt`). The headline severity stayed `‼` from the first tick until expiry, with no escalation as expiry approached.
  - It went `×` on `issuer cert is within its validity period` by T+10 and stayed there until the issuer was replaced.
  - It then passed (`√`) at every tick of the recover phase, including `data plane proxies certificate match CA` under `--proxy`, while four lab proxies were still running on expired leaves. No check line at any tick mentioned workload leaf certificates. **Source-derived:** that `--proxy` check compares each pod's injected trust-anchor PEM text with the `linkerd-identity-trust-roots` ConfigMap and never inspects leaf certificates (notes § 7).
  - **Still resting on source reading alone:**
    - that the 60-day threshold is fixed and cannot be configured;
    - that an issuer with 59 days left would get the same `‼` headline as this 15-minute issuer, so the headline alone cannot tell the two apart (the 59-day case was not run);
    - that `linkerd check` never inspects leaf certificates in general. This run shows only that it did not here.
