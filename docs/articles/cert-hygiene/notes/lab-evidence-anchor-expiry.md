# Evidence: trust-anchor expiry

- **Run:** `demos/cert-hygiene/runs/06-anchor-expiry/20260912T125027Z` — `validity.txt:1`: `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z`, same harness tree — `git-state.txt` in both runs records `harness_tree_sha256=e86c787ea2317ecdbc45e607681b83bba0f9e94b48f7f87aed3d95f0d274e7c8`
- **Versions:** `versions.txt`: `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `kubernetes_version=v1.36.4+k3s1`; identity args include `-identity-issuance-lifetime=5m0s -identity-clock-skew-allowance=20s`
- **Lifetimes:** `versions.txt`: `config_ANCHOR_LIFETIME=20m`, `config_ISSUER_LIFETIME=120m` (outlives the anchor), `config_LEAF_LIFETIME=5m` (profile `anchor-short`). The recovery bundle applied in stage 1 uses `config_NEW_ANCHOR_LIFETIME=87600h` and `config_REPLACEMENT_ISSUER_LIFETIME=8760h` — those long lifetimes are the recovery credentials only, not what this scenario is testing.
- **T_mark (anchor `notAfter`):** `2026-09-12T13:12:22Z` — `timeline.log:2` (`t_mark epoch=1789218742 utc=2026-09-12T13:12:22Z`), matching `certs/trust-anchor.txt:9` (`Not After : Sep 12 13:12:22 2026 UTC`) exactly. The issuer's own `notAfter` is `certs/issuer-initial.txt:9`: `Sep 12 14:52:22 2026 UTC`, 100 minutes later, confirming the issuer outlives the anchor as the profile intends.

All times below are given as `T+Ns` relative to T_mark (`T` = `2026-09-12T13:12:22Z`).

## Acceptance conditions (design § 13)

| Condition | Met? | Evidence |
| --- | --- | --- |
| Per-proxy final-leaf timing exists for every lab proxy | Yes | The table in A2 below covers all six baseline lab proxies (`probe-http`, `probe-tcp-new`, `probe-tcp-new-b`, `probe-tcp-stream`, `restart-target`, `server`), each with a last-issuance and final-leaf-`notAfter` value from `metrics/post-1.txt`. |
| Identity CSR evidence exists | Yes | A1 quotes `logs/pre-recover/identity.txt:60-61` (last issuance, then the first refusal on the very next log line) and the `IssuerValidationFailed` event counts. |
| Checks exist, before and after T_mark | Yes | A4 quotes `checks/fault-minus10-check.txt:41` and `checks/fault-plus10-check.txt:41-47`. |
| The named recovery stages exist, including whether an identity/control-plane restart was needed | Yes | `timeline.log:107,109,111,112,113,116` carry `a-stage1-apply` through `a-stage5`; `recover/linkerd-upgrade.txt` ends `[exit 0]`; `controlplane/a-stage1-before.txt` and `-after.txt` show the identity pod's UID change; `timeline.log:111` (`a-canary`) and `recover/a-stage2-canary-1-state.txt` record `state=proven`; `timeline.log:112` records `a-stage3 not needed: identity-canary became Ready in stage 2`, and no `recover/a-stage3-*` files exist in this run. |

All four hold, so A's § 13 bar is met by this run.

## Timeline

| T+s | UTC | Event | Source |
| --- | --- | --- | --- |
| −63 | 13:11:19Z | Last pre-expiry issuance for the five-proxy cohort (`probe-http`, `probe-tcp-new`, `probe-tcp-new-b`, `probe-tcp-stream`, `restart-target`) | `logs/pre-recover/identity.txt:60` |
| −66 | 13:11:16Z | Last pre-expiry issuance for `server` | derived from `metrics/post-1.txt:264` (`control_identity_cert_refresh_timestamp_seconds 1789218676.0409482`) |
| 0 | 13:12:22Z | `t_mark` / `fault` — the anchor's own expiry | `timeline.log:2,44` |
| +60 | 13:13:22Z | `applied probe-new`; `rolled restart-target` | `timeline.log:46-47` |
| +62 | 13:13:24Z | First identity CSR refusal | `logs/pre-recover/identity.txt:61` |
| +254 | 13:16:36Z | `server`'s final leaf expires | `metrics/post-1.txt:263` (`control_identity_cert_expiration_timestamp_seconds 1789218996.0`) |
| +256 | 13:16:38Z | First new-connection failures, pairs A and B, together | `probes/pre-a-stage4/probe-tcp-new-f6545f757-rmbcn.log:715`, `probes/pre-a-stage4/probe-tcp-new-b-64dbdd7f5c-kg6q6.log:715` |
| +257 | 13:16:39Z | The other five proxies' final leaves expire | `metrics/post-1.txt:11,77,119,159,195` (`control_identity_cert_expiration_timestamp_seconds 1789218999.0`) |
| +1784 | 13:42:06Z | `recover` | `timeline.log:106` |
| +1785 | 13:42:07Z | `a-stage1-apply`: `linkerd upgrade --force` with a new anchor and issuer | `timeline.log:107` |
| +1821 | 13:42:43Z | `a-stage2`: no manual restarts for 300 s; `identity-canary` applied | `timeline.log:109` |
| +1846 | 13:43:08Z | `a-canary`: canary proven, 25 s into stage 2 | `timeline.log:111` |
| +1850 | 13:43:12Z | `a-stage3 not needed`: canary became Ready in stage 2 | `timeline.log:112` |
| +1856 | 13:43:18Z | `restart a-stage4`: all remaining workloads restarted | `timeline.log:113` |
| +1904 | 13:44:06Z | `gate a-stage4 pass` | `timeline.log:114` |
| +1952 | 13:44:54Z | `a-stage5`: verify with `linkerd check` | `timeline.log:116` |
| +1973 | 13:45:15Z | `done` | `timeline.log:118` |

## A1 — identity refuses every CSR from T_mark on

**Verdict: confirmed.**

The last successful issuance before the fault and the first refusal are consecutive lines in the identity log:

- `logs/pre-recover/identity.txt:60`: `time="2026-09-12T13:11:19Z" level=info msg="issued certificate for default.lab.serviceaccount.identity.linkerd.cluster.local until 2026-09-12 13:16:39 +0000 UTC: ..."` (T-63s)
- `logs/pre-recover/identity.txt:61`: `time="2026-09-12T13:13:24Z" level=error msg="could not process CSR because of CA cert validation failure: x509: certificate has expired or is not yet valid: current time 2026-09-12T13:13:24Z is after 2026-09-12T13:12:22Z ... Invalid After 2026-09-12 14:52:22 +0000 UTC ..."` (T+62s)

No CSR is presented in between (the gap from T+0 to T+62s is simply the time until the next proxy's renewal was due), but from the first CSR after T_mark on, every one is refused: `grep -c 'could not process CSR' logs/pre-recover/identity.txt` returns **213**, and a scan of every `issued certificate` timestamp against the window `[T_mark, a-stage1-apply)` (`13:12:22Z`–`13:42:07Z`) finds **zero** issuances in that 1785 s span. The refusal reason names the anchor's own expiry each time: `Invalid After 2026-09-12 14:52:22 +0000 UTC` is the *issuer's* validity (still open), but the CA-chain check fails on the anchor, whose `notAfter` (`2026-09-12T13:12:22Z`) is quoted directly in the error (`... is after 2026-09-12T13:12:22Z`).

`IssuerValidationFailed` events: `fault-plus10.txt` (T+10s) has **0** — too soon for any client to have hit a refused CSR — while `a-stage2.txt`, `pre-recover.txt`, and `final.txt` each hold **11** (`grep -c IssuerValidationFailed events/*.txt`), i.e. the refusals are visible as cluster events too, and they persist through the pre-recovery window and into the final snapshot.

## A2 — each pair works until its own final leaf expires; failures are staggered

**Verdict: confirmed** for "each pair works until its own final leaf expires"; **falsified** for "staggered across proxies, not simultaneous."

Per-proxy final-leaf table (from the first `post-N` tick, `metrics/post-1.txt`, `2026-09-12T13:13:22Z`):

| Proxy | Last issuance (T+) | Final leaf `notAfter` (T+) | Source (line in `metrics/post-1.txt`) |
| --- | --- | --- | --- |
| `probe-http` | 13:11:19Z (T-63s) | 13:16:39Z (T+257s) | lines 11-12 |
| `probe-tcp-new-b` | 13:11:19Z (T-63s) | 13:16:39Z (T+257s) | lines 77-78 |
| `probe-tcp-new` | 13:11:19Z (T-63s) | 13:16:39Z (T+257s) | lines 119-120 |
| `probe-tcp-stream` | 13:11:19Z (T-63s) | 13:16:39Z (T+257s) | lines 159-160 |
| `restart-target` | 13:11:19Z (T-63s) | 13:16:39Z (T+257s) | lines 195-196 |
| `server` | 13:11:16Z (T-66s) | 13:16:36Z (T+254s) | lines 263-264 |

The spread of leaf expiries across all six proxies is **3 seconds** (`1789218999.0 − 1789218996.0`), not the "well above one probe interval" the reading guide sets as the bar for staggered. The probe interval itself is 2 s (`GATE_SAMPLE_INTERVAL_S=2` in `versions.txt`; also visible directly in the probe logs, which tick every 2 s), so a 3 s spread is barely more than one interval — practically simultaneous, not staggered.

First new-connection failure per pair (`probes/pre-a-stage4/`):

- Pair A (`probe-tcp-new` → `server`): last `ok` at `13:16:36Z seq=713` (`probe-tcp-new-f6545f757-rmbcn.log:714`), first `fail` at `13:16:38Z seq=714 fail socat_rc=1 ... Connection reset by peer` (`probe-tcp-new-f6545f757-rmbcn.log:715`)
- Pair B (`probe-tcp-new-b` → `server`): identical timing and wording (`probe-tcp-new-b-64dbdd7f5c-kg6q6.log:714-715`)

Both pairs' first failures land at the same second, **T+256s (13:16:38Z)** — 2 s (one probe interval) after `server`'s own leaf expired at T+254s, and 1 s before the *clients'* own leaves would have expired at T+257s. The failure is driven by the earlier-expiring endpoint of each pair, exactly as A2 predicts for "each pair works until its own final leaf expires" — but because both pairs share the same `server` endpoint, and `server`'s leaf is the earlier of the two in both pairs, both pairs fail at the identical instant. There is no staggering to observe in this run's data: the six proxies' leaves clustered within 3 s of each other, so the "failures staggered across proxies" half of A2 does not hold here.

*(Inference, not observed directly.)* The clustering is consistent with every lab workload having been deployed at the same moment during `reset`: identity's issuance-lifetime clock for each proxy starts from the same pod-creation time, so their renewal cycles — and therefore their final pre-expiry leaves — run in lockstep rather than drifting apart. This is an inference about *why* the leaves clustered, not something the run measures directly.

`probe-http` and `probe-tcp-stream` never fail at all, at any point in this run (`probe-http`: 971 lines, all `ok`; `probe-tcp-stream`: 1517 lines across the whole run, all `ok` or `connect`/`closed` markers tied to its one restart at `a-stage4`, none a `fail`). This is consistent with the reading guide's note that `probe-http` may reuse a connection rather than opening a new one per request, and with `probe-tcp-stream` holding a single TCP connection (`conn=c645a483-1789217560`, established at epoch `1789217560`, roughly 19.7 minutes before T_mark) open across the entire fault and into recovery — it is closed only when `probe-tcp-stream` itself is restarted in `a-stage4` (`probes/final/...`, `13:43:22Z closed socat_rc=1 fail-closed, not reconnecting`, immediately followed by a fresh `connect` on the new pod). Anchor expiry does not itself break an already-open connection; only a *new* TLS handshake fails.

## A3 — new connections fail; new pods never become Ready

**Verdict: confirmed.**

The pairs' post-expiry failures are established in A2 above (T+256s for both pairs, continuing — `bash scripts/probe-lines.sh` for `probe-tcp-new`/`-b` over the whole pre-recovery window shows 796 `fail` lines against 764 `ok` lines, i.e. every attempt after T+256s fails until recovery).

New pods created during the fault window never reach `Ready`:

- `probe-new` (applied at T+60s, `timeline.log:46`): its `Ready` condition is `status: "False"`, `reason: ContainersNotReady`, `message: 'containers with unready status: [linkerd-proxy idle]'` at `pods/post-1-probe-new-ddf9946ff-s4nn4.yaml` and unchanged through `pods/post-58-probe-new-ddf9946ff-s4nn4.yaml` (the last pre-recovery tick, T+2000s) — the same condition, word for word.
- `restart-target-65847f75d-b5d5j` (the new replica from the T+60s `rollout restart`): the identical `Ready: False / ContainersNotReady / [linkerd-proxy idle]` condition at `pods/post-1-restart-target-65847f75d-b5d5j.yaml`.

Both pods' `linkerd-proxy` container never gets a leaf (`control_identity_cert_expiration_timestamp_seconds 0.0` for both, `metrics/post-1.txt:41,225`), because identity refuses every CSR from T+62s on (A1). Only after `a-stage1`'s new anchor/issuer are applied and the workloads are restarted in `a-stage4` do the equivalent pods become `Ready`: `pods/verify-probe-new-74d7f7b7d6-5cnt9.yaml` shows `type: Ready` with no unready message, and `pods/verify-rollout-probe-new.txt`: `deployment "probe-new" successfully rolled out`.

## A4 — `linkerd check` goes fatal on the anchor's validity period

**Verdict: confirmed.**

- Before T_mark, `checks/fault-minus10-check.txt:41`: `√ trust anchors are within their validity period`
- After T_mark, `checks/fault-plus10-check.txt:41-47`:
  ```
  × trust anchors are within their validity period
      Invalid anchors:
  	* 175662501769834515639873889554883419724 root.linkerd.cluster.local not valid anymore. Expired on 2026-09-12T13:12:22Z
      see https://linkerd.io/2/checks/#l5d-identity-trustAnchors-are-time-valid for hints
  ...
  Status check results are ×
  [exit 1]
  ```

The check names the exact expiry timestamp recorded as T_mark, and the run exits fatal (`exit 1`), not merely with a warning.

## A5 — does recovery need identity restarted? (a tested inference)

**Verdict: inconclusive** — this run cannot isolate the question, for a reason worth stating plainly rather than glossing over.

`a-stage1-apply` (`linkerd upgrade --identity-issuer-certificate-file=… --identity-trust-anchors-file=… --force | kubectl apply -f -`) did not leave the existing control-plane pods in place: `recover/a-stage1-rollout.txt` shows `kubectl rollout status` waiting on and confirming all three Deployments — `deployment "linkerd-destination" successfully rolled out`, `deployment "linkerd-identity" successfully rolled out`, `deployment "linkerd-proxy-injector" successfully rolled out` — and the before/after control-plane snapshots confirm it at the object level:

- `controlplane/a-stage1-before.txt:3`: `pod linkerd/linkerd-identity-9998cb547-vw7t6 uid=030647b8-4fc6-4bd4-8197-42010f8fec90 ... trust=14d28fe9...`
- `controlplane/a-stage1-after.txt:4`: `pod linkerd/linkerd-identity-5479f4d689-scx9n uid=ba60d8b6-5948-4900-8de5-76b6695d9a56 start=2026-09-12T13:42:09Z ... trust=fd976f31...`
- `controlplane/a-stage1-before.txt:6` / `a-stage1-after.txt:8`: `deploy linkerd/linkerd-identity generation=1 ...` → `generation=2 ...`, `template_sha256` changed (`97d46d4b...` → `e08b8649...`)

The same UID-change-plus-generation-bump pattern holds for `linkerd-destination` and `linkerd-proxy-injector`. In other words, stage 1's own `--force` upgrade restarted every control-plane component itself, before stage 2 (the "no manual restarts" window) even began.

The canary was proven **in stage 2**, 25 s after it started: `timeline.log:111` / `recover/a-stage2-canary-1-state.txt`: `state=proven pod=identity-canary-7bcf7697c9-46nrq proxy=yes trust=c5ebd7aec1567a... ready=True started=1789220563 refresh=1789220564.7893947`, and `logs/a-stage2/identity.txt` shows the matching issuance at the same instant (`time="2026-09-12T13:42:44Z" level=info msg="issued certificate for default.lab.serviceaccount.identity.linkerd.cluster.local until 2026-09-12 13:48:04 +0000 UTC: ..."`). No `state=no-proxy` line appears anywhere in this run's `recover/` files: the canary was admitted with its proxy sidecar already injected, so the injector was serving normally at that moment. `a-stage3 not needed` (`timeline.log:112`) followed, and no `recover/a-stage3-*` files exist — stage 3 never ran.

But because stage 1 itself already restarted identity, "the canary was proven in stage 2" does **not** show that identity issues new-anchor leaves *without* an explicit restart — it shows that identity issues new-anchor leaves after being restarted, which stage 1's upgrade did as a side effect of applying the new credentials. The design's actual question — would identity still be serving old-anchor leaves after `a-stage1-apply` if the upgrade's own rollout had *not* restarted it — is not something this run can answer, because that counterfactual never occurred. This run confirms only that Linkerd's documented recovery procedure (`upgrade --force`, applied as `kubectl apply`) does restart identity, and that once restarted, identity issues valid new-anchor leaves quickly (canary proven 25 s into stage 2, T+1846s). Whether an explicit, separate identity restart (stage 3) would be *necessary* if the upgrade rollout somehow did not restart identity is left open by this run.

The stage-4 gate confirms the workload-restart stage completed cleanly once recovery was in place: `bash scripts/gate-table.sh $A` → `stage=a-stage4 ... gate=pass unmet=- / cell pair=A ok=10 fail=0 status=classified / cell pair=B ok=10 fail=0 status=classified`, with both pairs' leaves refreshed to the new anchor (`expiry=1789220921.0`, i.e. a fresh 5-minute leaf issued after the restart).

## The recovery stages

1. **`a-stage1-apply`** (`timeline.log:107`, T+1785s): `linkerd upgrade` with a new anchor and issuer, `--force`, piped to `kubectl apply -f -`. `recover/linkerd-upgrade.txt` ends `[exit 0]`. This stage's own rollout restarted all three control-plane Deployments (`linkerd-destination`, `linkerd-identity`, `linkerd-proxy-injector`) — see A5.
2. **`a-stage2`** (`timeline.log:109`, T+1821s): no manual restarts for `RECOVER_WINDOW_S=300`; `identity-canary` applied (`recover/a-stage2-canary.txt`: `deployment.apps/identity-canary created`, `[exit 0]`). The canary reached `state=proven` 25 s in (`recover/a-stage2-canary-1-state.txt`, T+1846s), with a matching identity-log issuance chained to the new anchor.
3. **`a-stage3`**: **not needed** (`timeline.log:112`, T+1850s: `a-stage3 not needed: identity-canary became Ready in stage 2`). No `recover/a-stage3-*` files exist in this run — an explicit identity/control-plane restart beyond what stage 1's own upgrade did was never exercised.
4. **`a-stage4`** (`timeline.log:113`, T+1856s): `kubectl rollout restart` on every remaining meshed workload (`identity-canary probe-http probe-new probe-tcp-new probe-tcp-new-b probe-tcp-stream restart-target server`), gated. Gate result: `pass`, both pairs `10/0 classified` (`gates/a-stage4.txt`; `bash scripts/gate-table.sh $A`).
5. **`a-stage5`** (`timeline.log:116`, T+1952s): verify with `linkerd check`. `checks/verify-check.txt` ends `Status check results are √`, `[exit 0]`; `pods/verify-rollout-*.txt` confirm every Deployment rolled out successfully.

## For the comparison with issuer expiry and the identity outage

- **Fault:** the trust anchor's own expiry (`T_mark`, `certs/trust-anchor.txt:9`) — no service was taken down and no configuration changed; the credential itself became invalid.
- **Was the signer valid?** No — the anchor (the root of trust) expired at T_mark; the issuer it signed remained within its own `notAfter` (100 minutes later) but every CSR check fails on the anchor, not the issuer.
- **Could workloads reach the identity service?** Yes, throughout — identity kept running and kept receiving CSRs (213 refused attempts recorded); the failure is a validation rejection, not an outage or an unreachable endpoint.
- **How failure spread:** existing connections were unaffected (the held-open `probe-tcp-stream` connection and, apparently, `probe-http`'s reused connection never failed). New connections into the endpoint with the earlier-expiring leaf (`server`, at T+254s) failed for both probe pairs at the same second (T+256s) — not staggered, because all six lab proxies' final leaves clustered within 3 s of each other in this run, contrary to A2's staggering prediction. New pods created during the fault window never became `Ready`, because identity refused their proxies' CSRs from T+62s on.
- **What recovery took:** `linkerd upgrade --force` with a new anchor and issuer (which itself restarted identity, destination, and the proxy-injector), a 300 s no-restart canary window that proved new-anchor issuance in 25 s, no separate identity restart stage, then a gated `rollout restart` of every remaining workload, then `linkerd check` passing clean.
- **What `linkerd check` showed:** fatal (`×`, exit 1) on "trust anchors are within their validity period" once past T_mark, naming the exact expiry timestamp; clean (`√`, exit 0) after full recovery.

## What this means for the article

- A's design § 13 acceptance condition is **met**: per-proxy final-leaf timing, identity CSR evidence, before/after checks, and the named recovery stages (including whether an identity/control-plane restart was needed) all exist in this run, judged against control `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z` (same harness tree, `harness_tree_sha256=e86c787e...`). The control's own restart stages show zero probe failures throughout (`control-criteria.txt`: `ok: probe-http has no fail/closed lines between baseline and recover`, etc., and every stage `10/0 classified`), so the `a-stage4` restart's clean `10/0` result in this run reflects ordinary rollout behaviour, not a TLS-attributable failure — the TLS-attributable failures in this scenario are the ones recorded in A1-A3, all landing before recovery began.
- A1 (identity refuses every CSR from T_mark) is **confirmed**: 213 refusals, 0 issuances in the 1785 s gap between T_mark and the upgrade.
- A2 is **mixed**: "each pair works until its own final leaf expires" is confirmed; "failures are staggered across proxies" is falsified in this lab, because every workload was deployed at the same moment (an inference about the cause, not itself observed) and the six leaves clustered within 3 s. The article should not repeat the staggering claim as reproduced.
- A3 (new connections fail; new pods never Ready) is **confirmed**.
- A4 (`linkerd check` goes fatal on the anchor's validity) is **confirmed**, with the exact check wording quoted above.
- A5 is **inconclusive**, and the article should say so rather than treat "identity restart" as either proven necessary or proven unnecessary: in this run, the documented recovery procedure's own `--force` upgrade already restarted identity, so the run cannot show whether an explicit restart would be required if the upgrade rollout somehow left identity untouched. What is confirmed is only that Linkerd's recovery procedure, as documented, does restart identity as part of applying new credentials, and that identity issues valid new-anchor leaves promptly (25 s) once restarted.
- One run is one run: these are the observed behaviours of anchor expiry in this lab, with Linkerd `edge-26.9.1`, a 20-minute anchor, a 120-minute issuer, and 5-minute leaves — not a general claim about other lifetimes, other Linkerd versions, or deployments whose proxies were not all created at the same moment.
