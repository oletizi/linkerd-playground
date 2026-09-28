# Evidence: identity issuer expiry, re-run twice

- **Runs:** `demos/cert-hygiene/runs/05-issuer-expiry/20260912T075503Z` (RA) and `demos/cert-hygiene/runs/05-issuer-expiry/20260912T085431Z` (RB) — both `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z` (C) — `evidence_valid=yes`, same harness tree as both runs (`harness_tree_sha256=e86c787ea2317ecdbc45e607681b83bba0f9e94b48f7f87aed3d95f0d274e7c8` in all three `git-state.txt` files)
- **Versions:** `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `kubernetes_version=v1.36.4+k3s1` (`versions.txt`, both runs)
- **Lifetimes:** anchor 720h, issuer 15m, leaf 5m (`config_PROFILE=issuer-short`, `versions.txt`; `identity_args` carries `-identity-issuance-lifetime=5m0s -identity-clock-skew-allowance=20s`); replacement issuer 8760h (`config_REPLACEMENT_ISSUER_LIFETIME=8760h`); post-expiry window 1800s (`config_POST_EXPIRY_WINDOW_S=1800`); no-restart recovery window 300s (`config_RECOVER_WINDOW_S=300`). The control used `config_PROFILE=long` (anchor 87600h, issuer 8760h) so nothing in it expires.
- **T_mark (issuer notAfter):** RA `2026-09-12T08:11:54Z` (`timeline.log`: `t_mark epoch=1789200714 utc=2026-09-12T08:11:54Z`, and the `fault` marker itself lands at `08:11:54Z`); RB `2026-09-12T09:11:24Z` (`t_mark epoch=1789204284 utc=2026-09-12T09:11:24Z`, `fault` at `09:11:24Z`). Because R's fault is the issuer's own expiry, T_mark is exact in both runs — it is not the recorded time of an action, so the "tick can run late" caveat in the reading guide does not apply here.

This is two runs, on one Linkerd version, with these lifetimes. It shows what happened in these two runs, not what always happens. Anything marked **Source-derived** comes from [linkerd-source-notes.md](linkerd-source-notes.md) or the spec's design doc; it was not observed here. The first (pre-freeze) issuer run, `runs/05-issuer-expiry/20260911T021157Z`, is not used to judge anything below — it ran at a different, older harness tree and is described only in the "What the re-run answers" section, where it is named explicitly as the earlier run.

Paths below are relative to each run directory unless prefixed `demos/`. Times are UTC; `T+N` / `T-N` means N seconds after/before that run's own T_mark. Container-log `--timestamps` prefixes are the VM's local time, `-07:00`; one line in each run was checked against its own `timeline.log` marker before converting (for example RA's identity-controller CSR-refusal line at local `01:11:58.016` matches the UTC `08:11:58Z` inside the same log line, 4s after that run's T_mark).

## Acceptance conditions (design § 13)

| Condition | RA | RB | Evidence |
| --- | --- | --- | --- |
| Workload `linkerd-proxy` logs exist for every lab pod | met | met | `logs/pre-stage2/pods.txt` lists 7 lab pods, all `proxy=yes`; `ls logs/pre-stage2/ \| grep -c linkerd-proxy.txt$` = 7 in both runs |
| Per-pod continuous probe history spans before-baseline to after-verify | met | met | `probe-lines.sh <run> probe-tcp-new` first/last lines: RA `07:57:13Z seq=1 ok` … `08:52:33Z seq=153 ok` (baseline tick `07:57:16Z`, verify tick `08:52:24Z`); RB `08:56:56Z seq=1 ok` … `09:52:01Z seq=146 ok` (baseline tick `08:56:58Z`, verify tick `09:51:53Z`) |
| Gated recovery stages exist: stage1-norestart, stage2-client-a, stage3-server, stage4-all | met | met | `gate-table.sh <run>` lists all four stages for both runs, `gate=none/pass/pass/pass` |
| Any established-connection claim names protocol and measured duration | met | met | R4 below names opaque TCP and gives RA ≈2231s, RB ≈2240s |

Both runs meet R's § 13 condition. **R is written up as reproduced** by the design's own rule (§ 14): every condition holds, and each claim below links to the run artifact behind it.

## Timeline

### RA (`20260912T075503Z`)

| UTC | T+ | Marker |
| --- | --- | --- |
| 07:57:16 | −874 | `tick baseline` |
| 08:11:44 | −10 | `tick fault-minus10` |
| 08:11:54 | 0 | `fault` (T_mark) |
| 08:12:04 | +10 | `tick fault-plus10` |
| 08:12:54 | +60 | `applied probe-new`, `rolled restart-target`, `tick post-1` |
| 08:41:24 | +1770 | `tick post-58` (last pre-recover tick) |
| 08:41:39 | +1785 | `recover` |
| 08:41:40 | +1786 | `recover-apply linkerd upgrade with the replacement issuer; no trust-anchor flag` |
| 08:42:02 | +1808 | `issuer-updated IssuerUpdated event seen 20s after apply`; `stage stage1-norestart: no restarts for 300s` |
| 08:46:38 | +2084 | `stage stage1-norestart: samples, no restarts` |
| 08:47:25 | +2131 | `restart stage2-client-a: probe-tcp-new` |
| 08:48:04 | +2170 | `gate stage2-client-a pass` |
| 08:49:01 | +2227 | `restart stage3-server: server` |
| 08:49:39 | +2265 | `gate stage3-server pass` |
| 08:50:45 | +2331 | `restart stage4-all: probe-http probe-new probe-tcp-new-b probe-tcp-stream restart-target` |
| 08:51:36 | +2382 | `gate stage4-all pass` |
| 08:52:24 | +2430 | `tick verify` |
| 08:52:44 | +2450 | `done` |

### RB (`20260912T085431Z`)

| UTC | T+ | Marker |
| --- | --- | --- |
| 08:56:58 | −866 | `tick baseline` |
| 09:11:14 | −10 | `tick fault-minus10` |
| 09:11:24 | 0 | `fault` (T_mark) |
| 09:11:34 | +10 | `tick fault-plus10` |
| 09:12:24 | +60 | `applied probe-new`, `rolled restart-target`, `tick post-1` |
| 09:41:10 | +1786 | `recover`, `recover-apply linkerd upgrade with the replacement issuer; no trust-anchor flag` |
| 09:41:42 | +1818 | `issuer-updated IssuerUpdated event seen 30s after apply`; `stage stage1-norestart: no restarts for 300s` |
| 09:46:19 | +2095 | `stage stage1-norestart: samples, no restarts` |
| 09:47:06 | +2142 | `restart stage2-client-a: probe-tcp-new` |
| 09:47:45 | +2181 | `gate stage2-client-a pass` |
| 09:48:40 | +2236 | `restart stage3-server: server` |
| 09:49:21 | +2277 | `gate stage3-server pass` |
| 09:50:24 | +2340 | `restart stage4-all: probe-http probe-new probe-tcp-new-b probe-tcp-stream restart-target` |
| 09:51:03 | +2379 | `gate stage4-all pass` |
| 09:51:53 | +2429 | `tick verify` |
| 09:52:13 | +2449 | `done` |

The two runs' recovery cycles are within seconds of each other end to end (RA: T+1785 to T+2450, 665s; RB: T+1786 to T+2449, 663s), and the issuer reload lands at the same offset from apply both times (RA 20s, RB 30s).

## R1 — HTTP reuses a pre-expiry proxy connection

**Verdict: confirmed, in both runs.**

**Evidence:**
- `pod-series.sh <run> probe-http tcp_open_total`, filtered to `direction="outbound"` and `authority="server.lab.svc.cluster.local:8080"`. In RA the value is `1` at every tick from `pre-1` (`07:57:37Z`) through `post-58` (`08:41:24Z`, the tick immediately before `recover`) and stays `1` through `stage2-client-a` (`08:48:48Z`), all against the same destination label (`dst_pod="server-577d5dfdbd-rqwnl"`, `target_addr="10.42.0.8:8080"`) — the value at `fault-minus10` (`08:11:44Z`) is identical to the value at `post-58`, 1769s later. RB shows the same pattern: `1` at every tick from `pre-1` through `post-58` and `stage2-client-a`, same `dst_pod` label throughout.
- Outcome count: `probe-lines.sh <run> probe-http <t_mark> <stage2-restart-utc> | awk '{print $4}' | sort | uniq -c`. RA (`08:11:54Z` to `08:47:25Z`): `1057 ok`, zero `fail`. RB (`09:11:24Z` to `09:47:06Z`): `1063 ok`, zero `fail`.

The outbound TCP-open counter to `server` never rises across T_mark while `probe-http` keeps succeeding on every attempt, which is exactly R1's falsification test (a rising counter would falsify it). Both runs agree.

**Notes:**
- **Source-derived:** the explanation that HTTP requests are reusing a proxy-to-proxy connection opened before T_mark is from the spec, not from a captured proxy log; this run only shows the *outcome* (the counter not rising) predicted by that explanation, not the mechanism itself directly.
- At `stage3-server` (server restarted), both runs' `probe-http` metric snapshot still names the *old* `dst_pod` at value `1` — a stale label from a counter series that had not yet been superseded at the moment of that tick's scrape, not evidence the old connection was still open after the restart. It should not be read as contradicting R1.

## R2 — pre-existing proxies' TLS handshake to identity fails

**Verdict: confirmed, in both runs.**

**Evidence:**
- Counting error kinds in each pre-existing lab pod's own `linkerd-proxy` log (`logs/pre-stage2/<pod>-linkerd-proxy.txt`) shows a TLS handshake failure, not a certificate-validation failure, on every one of them:

  | Pod | RA: `CertificateExpired` / `fail-fast` / `BrokenPipe` | RB: same |
  | --- | --- | --- |
  | probe-http | 24 / 45 / 6 | 25 / 45 / 4 |
  | probe-tcp-new (pre-existing) | 21 / 45 / 5 | 24 / 46 / 4 |
  | probe-tcp-new-b | 28 / 45 / 2 | 27 / 46 / 2 |
  | probe-tcp-stream | 25 / 46 / 2 | 25 / 46 / 3 |
  | server | 24 / 46 / 4 | 27 / 45 / 4 |
  | probe-new (created after T_mark) | 0 / 0 / 0 | 0 / 0 / 0 |
  | restart-target (created after T_mark) | 0 / 0 / 0 | 0 / 0 / 0 |

  First `CertificateExpired` line, RA `server` pod (`logs/pre-stage2/server-577d5dfdbd-rqwnl-linkerd-proxy.txt`, local timestamp `2026-09-12T01:42:38.694745834-07:00` converts to `2026-09-12T08:42:38Z`, T+1844):

  `ERROR ... identity:identity{server.addr=linkerd-identity-headless.linkerd.svc.cluster.local:8080}: linkerd_proxy_identity_client::certify: Failed to obtain identity error=code: 'Unknown error', message: "controller linkerd-identity-headless.linkerd.svc.cluster.local:8080: endpoint 10.42.0.5:8080: connection error", source: ControlError { ... source: EndpointError { addr: 10.42.0.5:8080, source: hyper::Error(Io, Custom { kind: InvalidData, error: "received fatal alert: CertificateExpired" }) } } ...`

  This is a TLS alert *received* by the workload's own proxy from `linkerd-identity-headless:8080` — i.e. identity's own inbound proxy is the side that inspects the incoming certificate and aborts the handshake, and the workload proxy is the side that logs having received that abort. RB's `server` pod shows the identical error text at its own first occurrence.
- `grep -c x509 logs/pre-stage2/*-linkerd-proxy.txt` is `0` for every workload proxy log in both runs: no validation-style error (the kind R2 says would falsify it) appears anywhere in a workload proxy's own log. The only `x509`/CA-validation-style errors anywhere in either run are in `logs/pre-recover/identity.txt`, the identity *controller's* log, and they concern the identity pod's own CSR, not a workload's: `2026-09-12T08:11:58Z level=error msg="could not process CSR because of CA cert validation failure: x509: certificate has expired or is not yet valid: current time 2026-09-12T08:11:58Z is after 2026-09-12T08:11:54Z ... CSR Identity : linkerd-identity.linkerd.serviceaccount.identity.linkerd.cluster.local"` (RA; RB has the matching line at `09:11:27Z`, 3s after its own T_mark).
- Cross-check: `pod-series.sh <run> probe-tcp-new control_identity_cert_refreshes_total` across `stage1-1` through `stage1-10` (RA `08:42:02Z`–`08:46:32Z`, RB `09:41:43Z`–`09:46:13Z`, all well after `recover-apply`) shows `result="ok" 7` and `result="error" 0` unchanged at every one of the ten samples, in both runs. The proxy keeps trying and keeps failing at the handshake (the `CertificateExpired` lines continue past `recover-apply` with no change in kind — RA's `server` pod log's last entries before the pre-stage2 snapshot, at local `01:47:19` / UTC `08:47:19Z`, are still `CertificateExpired`/`BrokenPipe`), but none of those attempts registers as a counted "error" refresh; they never reach the point the counter measures.

**Notes:**
- This closes two of the first run's explicitly open questions (see below): which side rejects the handshake, and why replacing the issuer alone did not fix the pre-existing proxies. The mechanism observed here is a TLS-layer rejection (a `CertificateExpired` alert from identity's own inbound proxy), not a CA/issuer validation failure of the kind the controller logs for its own CSR. **Inference, not directly observed:** the specific field the receiving side inspected to produce that alert (most plausibly the client's own presented, already-expired leaf) is not shown in this log line; the log only shows that the workload's proxy received a `certificate_expired` alert from identity's endpoint.
- Replacing the issuer does not change this: a pre-existing proxy's own leaf is still expired regardless of which issuer produced it, so it keeps failing the identical handshake, in both runs, well past `recover-apply`.

## R3 — a new mTLS connection can't succeed while either endpoint holds an invalid certificate

**Verdict: confirmed, in both runs, matching the predicted matrix exactly.**

**Evidence:** `gate-table.sh <run>` per stage. "Fresh" means the endpoint's `leaf refresh=` timestamp is after `recover-apply` (RA epoch ≈1789202500, RB ≈1789206070); "stale" means its `expiry=` still equals the T_mark epoch (`1789200714.0` RA / `1789204284.0` RB).

| Stage | Pair A: client/server | Observed A | Pair B: client/server | Observed B |
| --- | --- | --- | --- | --- |
| 1. no restart | stale/stale | RA `ok=0 fail=10`; RB `ok=0 fail=10` | stale/stale | RA `ok=0 fail=10`; RB `ok=0 fail=10` |
| 2. client A restarted | fresh/stale | RA `ok=0 fail=10`; RB `ok=0 fail=10` | stale/stale | RA `ok=0 fail=10`; RB `ok=0 fail=10` |
| 3. server restarted | fresh/fresh | RA `ok=10 fail=0`; RB `ok=10 fail=0` | stale/fresh | RA `ok=0 fail=10`; RB `ok=0 fail=10` |
| 4. all restarted | fresh/fresh | RA `ok=10 fail=0`; RB `ok=10 fail=0` | fresh/fresh | RA `ok=10 fail=0`; RB `ok=10 fail=0` |

Every stage's gate is `pass` (or `none` for stage 1, which has no restart), so every cell above is classified, not timed out — no `unmet=` to quote in either run.

Leaf lines confirm the fresh/stale labels, for example RA stage 3: `leaf 2026-09-12T08:50:32Z role=clientA pod=probe-tcp-new-fdcc5c677-qgwn5 refresh=1789202846.9075008 expiry=1789203166.0` (fresh — refreshed after `recover-apply` at epoch ≈1789202500) beside `leaf 2026-09-12T08:50:33Z role=clientB pod=probe-tcp-new-b-64dbdd7f5c-6wl4q refresh=- expiry=- ok=- err=-` (still on the pre-existing, pre-recover leaf — no refresh recorded since T_mark).

Only the fresh/fresh cell succeeds in every stage in both runs; every cell with a stale endpoint fails 10/10. This is the exact matrix predicted in design § 2, reproduced twice.

**Control's cells for the same stages** (`gate-table.sh` on `demos/cert-hygiene/runs/00-baseline-control/20260912T065110Z`, where nothing expires): all four stages, both pairs, `ok=10 fail=0`. The restart-choreography control shows that restarting `probe-tcp-new`, then `server`, then everything else, causes zero probe failures on its own when certificates are healthy — so the fail cells above in RA/RB are attributable to the stale certificate state, not to restart disruption itself.

## R4 — the established stream survives the whole window

**Verdict: confirmed, in both runs, ending at the stage3-server restart as designed, not from any TLS failure.**

**Evidence:** `probe-lines.sh <run> probe-tcp-stream | grep -E ' (connect|closed) '`.

- RA: `2026-09-12T07:57:13Z probe-tcp-stream seq=0 conn=4d10b3af-1789199833 connect target=server.lab.svc.cluster.local:9000` (T−881, opened before `baseline`), then no `closed` line until `2026-09-12T08:49:05Z probe-tcp-stream seq=1552 conn=4d10b3af-1789199833 closed socat_rc=0 fail-closed, not reconnecting` (T+2231). The last `ok` before it: `2026-09-12T08:49:04Z probe-tcp-stream seq=1552 conn=4d10b3af-1789199833 ok` (T+2230).
- RB: connect `2026-09-12T08:56:56Z ... conn=cbe5bf56-1789203416 connect target=server.lab.svc.cluster.local:9000` (T−1108), last `ok` `2026-09-12T09:48:42Z ... ok` (T+2238), `closed` `2026-09-12T09:48:44Z ... closed socat_rc=0 fail-closed, not reconnecting` (T+2240).

The protocol is opaque TCP through the mesh (`target=server.lab.svc.cluster.local:9000`, the non-HTTP probe port). The measured duration held past T_mark before the close is **≈2231s (about 37m11s) in RA and ≈2240s (about 37m20s) in RB** — longer than the nominal 1800s post-expiry window, because the connection also survived `stage1-norestart` (300s) and `stage2-client-a` (which restarts only `probe-tcp-new`, not `server` or `probe-tcp-stream`) before ending.

Both closes land within seconds of that run's `restart stage3-server` marker (RA restart at T+2227, close at T+2231; RB restart at T+2236, close at T+2240), and both report `socat_rc=0` — a clean close, not a read error. **Control comparison:** the control's own long-lived stream connection (nothing ever expired) also closes at `07:44:29Z` with `socat_rc=0`, within 4s of its own `restart stage3-server` at `07:44:25Z`. The stream ends because `server` — its own connection endpoint — is restarted in stage 3, the same as it does in the control where there is no certificate fault at all. This is not a TLS-attributable failure; it is the ordinary effect of restarting the process at the other end of an open socket.

## Agreement between the two runs

RA and RB agree on every hypothesis verdict, on the exact shape of the R3 matrix (identical pass/fail pattern in every stage/pair cell), and on R4 ending at the stage3-server restart rather than earlier. The measured quantities differ only slightly: the issuer-reload delay after apply (20s RA, 30s RB) and the stream's post-T_mark survival (≈2231s RA, ≈2240s RB, a 9s difference explained by each run's own tick cadence, not by anything TLS-related). Two runs is two runs: this shows the pattern held twice at this harness tree, on this Linkerd version and these lifetimes — it does not establish that it holds in general.

## What the re-run answers from the first issuer run's open questions

The first issuer run's write-up (`lab-evidence-issuer-expiry.md`) named four things as open pending this re-run:

- **H3's mechanism (which side rejects the handshake, and how):** narrowed. RA and RB directly show a TLS alert, `received fatal alert: CertificateExpired`, in every pre-existing workload proxy's own log — a handshake-layer rejection, distinct from the CA-validation error the identity controller logs for its own CSR. It is still an inference, not a captured packet trace, that the alert concerns the workload's own presented (expired) leaf rather than something else; the log line names the alert kind but not which certificate field triggered it.
- **H4 for workload proxies (the `Failed to obtain identity` cadence):** answered. Every pre-existing lab pod's own `linkerd-proxy.txt` in `logs/pre-stage2/` (not just the identity pod's) now carries `Failed to obtain identity` lines, with the counts in the R2 table above.
- **Which side rejected the handshakes (H5's open question about new-connection failures):** narrowed by the same R2 evidence — identity's own inbound proxy is the side that aborts and sends the alert; this run does not show whether client-to-server (not client-to-identity) connections fail the same way, since R3's gate samples show only `ok`/`fail` counts, not the failing side.
- **Why H8's pre-existing proxies never re-certified:** answered, for the 605s-and-longer window this re-run covers with fuller logging: they keep failing the identical TLS handshake to identity, unchanged by the issuer replacement, because their own held leaf certificate is still expired and every certify attempt requires presenting it. Only a restart (issuing a brand-new leaf) recovers them — confirmed again directly by R3's matrix, where only the fresh/fresh cell ever succeeds.

The top-level `findings.md` "Still open" section listed these, in article-facing language, and this evidence bears on the first four of its five bullets:
- *"Why proxies with expired certificates didn't renew after the issuer was replaced, and whether they would have recovered eventually."* — the "why" is narrowed (see above); "whether they would have recovered eventually" is **still open**: both runs move straight from the no-restart window into restart stages, so neither run leaves a stale proxy running long enough, unrestarted, to show whether it would self-recover.
- *"Which side rejects the connection when both proxies' certificates have expired."* — narrowed: identity's own inbound proxy is the side that aborts the client-to-identity handshake and sends the alert (R2). This run does not test the peer-to-peer (workload-to-workload, not workload-to-identity) case R5's original wording implied.
- *"Why the HTTP client kept working, and how long already-open connections keep working."* — narrowed for the "how long": the stream held for ≈2231–2240s past T_mark in this run, ending only when its own destination pod restarted, not on its own. "Why HTTP kept working" is still **source-derived only** (R1's mechanism, connection reuse, was not directly observed — only its predicted outcome, a flat connection counter, was).
- *"How any of this plays out with the default 24-hour workload certificates."* — **still open**: both runs used the 5-minute leaf lifetime; nothing here bears on the 24-hour default.
- *"Everything in the not-yet-tested table"* (webhook, identity-outage, trust-anchor, viz) — out of scope for this write-up; those are Tasks 29, 31 and others.

## For the comparison with the identity outage and anchor expiry

- **Fault:** the identity issuer's own signing certificate reaches its `notAfter` (a scheduled expiry, not an externally injected outage or a trust-anchor swap). T_mark is exact in both runs (the `fault` marker's own timestamp equals the issuer's recorded `notAfter`).
- **Was the signer valid?** No — the issuer itself is the thing that expired. Every certify request after T_mark that reaches the controller is refused there for CA-validation failure (`could not process CSR because of CA cert validation failure: x509: certificate has expired...`, `logs/pre-recover/identity.txt`), but almost no workload request reaches that point: it is rejected earlier, at the TLS handshake to identity's inbound proxy (R2).
- **Could workloads reach the identity service?** Yes, at the network and pod level, in both runs themselves — `pods/post-58.txt` (the last pre-recover tick, T+1770) lists `linkerd-identity-669c86dffd-sjczq 2/2 Running 0 44m` in RA and `linkerd-identity-7f57868664-5qdmp 2/2 Running 0 44m` in RB, so identity was up and ready throughout the entire post-expiry window in both runs — but every pre-existing workload's TLS handshake to it failed with `received fatal alert: CertificateExpired` (R2), so in practice no pre-existing proxy could complete a certify call against a reachable, running identity service.
- **How failure spread:** simultaneously at the credential layer for the proxies checked here — each lab pod's `control_identity_cert_expiration_timestamp_seconds` at `fault-minus10` already equals that run's own T_mark epoch (RA `metrics/fault-minus10.txt`, `server` pod section: `control_identity_cert_expiration_timestamp_seconds 1789200714.0`, the same value as `t_mark epoch=1789200714`; RB's `server` pod section: `1789204284.0`, matching its own `t_mark epoch=1789204284`) — consistent with the first run's broader H2 finding that every mesh identity, control plane included, expires in the same instant, which this write-up did not re-derive across every control-plane proxy. Traffic did not fail simultaneously at the connection layer: new mTLS connections between pre-existing proxies failed from T_mark, while an already-open opaque-TCP stream and a reused HTTP path kept working for tens of minutes past T_mark (R1, R4), until something else — an unrelated restart, not the certificate fault — tore them down.
- **What recovery took:** replacing the issuer via `linkerd upgrade` (no trust-anchor flag) reloaded identity by itself within 20–30s of apply in both runs (`issuer-updated` markers), but that alone recovered nothing for a proxy that already held an expired leaf (R2, R3). Recovery for those proxies required a restart to obtain a fresh leaf under the new issuer; R3's matrix shows the exact endpoint-pair combination needed (both sides fresh) before a new connection succeeds — confirmed in both runs at every stage.
- **What `linkerd check` showed:** grounded directly in RA's and RB's own `checks/` transcripts; RA and RB agree at every tick checked.
  - Before expiry, both runs' `checks/baseline-check-proxy.txt` line 47 reads `√ issuer cert is within its validity period`, with the 60-day warning on line 48 (`‼ issuer cert is valid for at least 60 days`) and the exact expiry on line 49 (`issuer certificate will expire on 2026-09-12T08:11:54Z` in RA, `...09:11:24Z` in RB) — expected for a 15-minute issuer.
  - After T_mark, both runs' `checks/post-14-check.txt` line 47 reads `× issuer cert is within its validity period`, with `issuer certificate is not valid anymore. Expired on 2026-09-12T08:11:54Z` (RA) / `...09:11:24Z` (RB) on line 48.
  - After the replacement issuer is applied, both runs' `checks/stage1-1-check.txt` — the first check transcript taken after `recover-apply`/`issuer-updated` — already show all three issuer rows green (lines 46-49: `√ issuer cert is using supported crypto algorithm`, `√ issuer cert is within its validity period`, `√ issuer cert is valid for at least 60 days`, `√ issuer cert is issued by the trust anchor`), and stay green through `checks/stage1-10-check.txt` and `checks/verify-check.txt` at the end of each run.
  - **The operational combination holds in both runs, cited at the same point in each.** RA's `checks/stage1-10-check.txt` and `checks/stage1-10-check-proxy.txt` (tick `stage1-10`, `08:46:32Z`, T+2078) are fully green — `Status check results are √`, `[exit 0]`, and line 62 of the `--proxy` transcript reads `√ data plane proxies certificate match CA` — six seconds before `gates/stage1-norestart.txt` began sampling (`started_at=2026-09-12T08:46:38Z`), where the same stage records `cell pair=A ok=0 fail=10 status=classified` and `cell pair=B ok=0 fail=10 status=classified`. RB shows the identical gap: `checks/stage1-10-check.txt`/`-check-proxy.txt` (tick `stage1-10`, `09:46:13Z`, T+2089) are fully green, six seconds before `gates/stage1-norestart.txt`'s `started_at=2026-09-12T09:46:19Z`, where that stage also records `ok=0 fail=10` for both pairs. So in both runs, `linkerd check` (with and without `--proxy`) reports fully healthy at essentially the same moment the gated fresh-connection samples for that same stage are failing 10/10 on both pairs. This grounds "a passing check does not mean workloads recovered" in RA and RB directly, not only in the pre-freeze run.

## What this means for the article

- **"Failure spreads gradually" is not what happens; failure splits by connection state, and R's § 13 condition is now met.** Both runs' `logs/pre-stage2/*-linkerd-proxy.txt` (7 pods each) and `gates/*.txt` exist and are complete, so R can move from "expected from code" language to "reproduced" — supported, artifacts: `demos/cert-hygiene/runs/05-issuer-expiry/20260912T075503Z/logs/pre-stage2/`, `.../gates/`, `demos/cert-hygiene/runs/05-issuer-expiry/20260912T085431Z/logs/pre-stage2/`, `.../gates/`.
- **New mTLS connections fail at T_mark; already-open connections and reused HTTP paths keep working for tens of minutes.** Supported, both runs. Artifacts: R1/R4 evidence above, `.../probes/`, `.../metrics/`.
- **The mechanism is a TLS handshake failure at identity's own inbound proxy, not a certificate-validation failure logged by a workload.** Supported, narrowed from "inconclusive" in the first run. Artifacts: `.../logs/pre-stage2/*-linkerd-proxy.txt` (the `CertificateExpired` lines).
- **Replacing the issuer does not, by itself, fix a proxy that already holds an expired leaf; only fresh/fresh endpoint pairs pass, exactly as the design's matrix predicted.** Supported, reproduced identically in both runs. Artifacts: `.../gates/stage1-norestart.txt`, `.../gates/stage2-client-a.txt`, `.../gates/stage3-server.txt`, `.../gates/stage4-all.txt`, and the control's own `.../gates/*.txt` for comparison.
- **An open opaque-TCP stream survives well past the nominal post-expiry window and ends only when its own remote endpoint is restarted — the same as it does in a control run where nothing expired.** Supported. Artifacts: `.../probes/*/probe-tcp-stream*.log` via `probe-lines.sh`, and the control's own stream close at its stage3-server restart.
- **`linkerd check`'s issuer rows go green as soon as the replacement issuer loads, and stay green through a stage where gated fresh-connection samples are still failing 10/10 on both pairs — a passing check does not mean workloads recovered.** Supported in both runs, grounded here rather than carried forward from the pre-freeze run. Artifacts: `demos/cert-hygiene/runs/05-issuer-expiry/20260912T075503Z/checks/{baseline,post-14,stage1-1,stage1-10,verify}-check.txt`, `.../checks/stage1-10-check-proxy.txt`, `.../gates/stage1-norestart.txt`; the matching set under `demos/cert-hygiene/runs/05-issuer-expiry/20260912T085431Z/`.
- **Whether a stuck proxy would ever recover on its own, and how any of this plays out at the default 24-hour leaf lifetime, are not settled by this evidence.** Not supported either way — both runs move from the no-restart window straight into restart stages, and both used the lab's shortened 5-minute leaf.
