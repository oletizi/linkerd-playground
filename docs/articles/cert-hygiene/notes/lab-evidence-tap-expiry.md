# Evidence: the tap API server's serving certificate expiring

- **Run:** `demos/cert-hygiene/runs/30-tap-expiry/20260914T091635Z` (V) — `validity.txt` reads `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260914T071125Z` (C, `evidence_valid=yes`) — same harness tree as the run (`harness_tree_sha256=206cd4f55895d89011a65c131f03c09c911b06588547f3162a13bab440f7dfa3` in both `git-state.txt` files), which is what V's `control-at-tree` validity rule requires
- **Versions:** `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `kubernetes_version=v1.36.4+k3s1` (`versions.txt`). The viz image the run recorded is `cr.l5d.io/linkerd/tap:edge-26.9.1` (`image=` line, `versions.txt`).
- **Credentials — read this before any claim below.** The tap serving certificate here is **lab-supplied and static**, not how Linkerd normally runs: `linkerd viz install` normally issues and owns the tap certificate itself. This run installs viz with `--set-file tap.crtPEM=…,tap.keyPEM=…,tap.caBundle=…` from a lab CA (`demos/cert-hygiene/lab/lib-webhook.sh`, `tap_install_args`), so nothing in the cluster will ever rotate it. `config_PROFILE=tap-short`; anchor `config_ANCHOR_LIFETIME=87600h` and issuer `config_ISSUER_LIFETIME=8760h` are long-lived and neither expires in this run, and `config_WEBHOOK_CERT_LIFETIMES=` is empty — the three admission webhooks keep Linkerd's own certificates. **The tap certificate is the only credential that expires.**
- **The certificate (`certs/tap.txt`):** `subject=CN=tap.linkerd-viz.svc`, `issuer=CN=lab-webhook-ca`, `notBefore=Sep 14 09:18:36 2026 GMT`, `notAfter=Sep 14 09:33:36 2026 GMT` — a 900-second (15-minute) lifetime, matching `TAP_CERT_LIFETIME=15m` in `demos/cert-hygiene/lab/profiles/tap-short.env`.
- **T_mark** is that `notAfter`: `timeline.log` reads `t_mark epoch=1789378416 utc=2026-09-14T09:33:36Z`, and the `fault` marker fires at `2026-09-14T09:33:36Z` — the same second. `T+N` below means N seconds after that. The run's own `notBefore` is `T−900`.
- **Baseline proof (V's stop gate), `tap-baseline.txt`:** `result=ok`, with `ok: v1alpha1.tap.linkerd.io Available=True`, `ok: linkerd viz check passed (√ tap API server has valid cert)` and `ok: linkerd viz tap observed 15 event(s) against live traffic` — tap demonstrably worked while the certificate was valid.
- **Forced reconnect:** `reconnect-restart kubectl rollout restart: tap` at `10:03:26Z` (T+1790); `reconnect-rolled-out rollout.txt [exit 0]` at `10:03:30Z` (T+1794), four seconds later. No credential is replaced: V has no recovery branch, and `timeline.log` says so — `v-recover no recovery: the tap certificate is never replaced; only the forced-reconnect phase (above) ran`.

**V ran once.** Everything below is what happened in this one run, on this Linkerd version, with this lab-supplied certificate — not what always happens. Where a claim would need repetition, it says so. The scenario was launched twice; the earlier attempt, `runs/30-tap-expiry/20260914T081309Z`, is published but is **not evidence**. Its `validity.txt` reads `evidence_valid=no` and `reason=no valid 00-baseline-control run with harness tree 206cd4f55895d89011a65c131f03c09c911b06588547f3162a13bab440f7dfa3`. (As context, not as something that file carries: the control's local copy was absent from the workspace when that attempt ran, which is why the rule could not find it. The control itself is valid and at that tree.) No figure in this note comes from that run. Paths below are relative to the run directory unless prefixed `demos/`.

## Acceptance conditions (design § 13, V row)

| Condition | Status | Evidence |
| --- | --- | --- |
| The user has approved it | met | Scenario V is optional and "needed the user's confirmation, which it now has" — [slice 3 plan](../../../superpowers/plans/2026-09-13-cert-hygiene-lab-slice-3/README.md), approved 2026-09-13 |
| APIService status captured | met | `apiservices/<tick>.txt`, 93 files (`baseline`, `pre-1`…`pre-24`, `fault-minus60`, `fault-minus10`, `fault-plus10`, `post-1`…`post-58`, `reconnect-1`…`reconnect-6`, `verify`), each with `apiservice_available_status`/`_reason`/`_message`; plus three raw-JSON condition snapshots `apiservices/baseline-conditions.json`, `reconnect-0000-conditions.json`, `verify-conditions.json` |
| CLI output captured | met | `tap/<tick>.txt`, 68 files (`baseline`, `fault-plus10`, `post-1`…`post-58`, `reconnect-0000`, `reconnect-1`…`reconnect-6`, `verify`), each holding the command line, its whole output and its exit status |
| Certificate state captured | met | `certs/tap.txt` (and its PEM), `certs/webhook-ca.txt` — serial, SHA-256 fingerprint, `notBefore`/`notAfter`, subject, issuer |
| `linkerd viz check` captured | met | `viz-check/<tick>.txt`, 94 files (the 93 ticks above plus `reconnect-0000`) |

**V's § 13 condition is met, so V counts as reproduced by the design's own rule** — with the reconnect qualifier that the clause verdicts below carry, and which any reader-facing claim must keep.

## Phases

| Phase | Window (T+) | Ticks | APIService `Available` | `linkerd viz tap` | `linkerd viz check` |
| --- | --- | --- | --- | --- | --- |
| Before expiry | −790 … −10 | `baseline`, `pre-1`…`pre-24`, `fault-minus60`, `fault-minus10` | `True` / `Passed` | 15 events at `baseline` | `√` + `‼` 60-day warning, `[exit 0]` |
| Expiry | 0 | `fault` marker, `09:33:36Z` | — | — | — |
| After expiry, before reconnect | +10 … +1770 | `fault-plus10`, `post-1`…`post-58` | `True` / `Passed`, all 59 ticks | events at all 59 ticks | `×`, `[exit 1]`, all 59 ticks |
| Forced reconnect | +1789 … +1794 | `recover`, `reconnect-backing`, `reconnect-restart`, `reconnect-rolled-out` | flips to `False` at +1794 | — | — |
| After reconnect | +1794 … +1951 | `reconnect-0000`, `reconnect-1`…`reconnect-6`, `verify` | `False` / `FailedDiscoveryCheck` | `503`, 0 events, all 8 captures | `×`, `[exit 1]` |
| Recovery | none | — | — | — | — |

Boundary arithmetic, subtracted from `timeline.log`'s own UTC stamps against T_mark `09:33:36Z`: `post-58` tick `10:03:06Z` = T+1770 (29 min 30 s); `recover` `10:03:25Z` = T+1789; `reconnect-restart` `10:03:26Z` = T+1790; `reconnect-rolled-out` `10:03:30Z` = T+1794 (29 min 54 s); `reconnect-1` `10:03:31Z` = T+1795; `verify` `10:06:07Z` = T+1951; `done` `10:06:29Z` = T+1973.

## V1 — the verdict

> **V1 (design § 8):** "The tap APIService goes `Available=False`, `linkerd viz tap` fails, and `linkerd viz check` goes fatal on 'tap API server has valid cert'."

**Verdict: one hypothesis, three clauses, and this run does not treat them alike.**

- Clause 3 (`linkerd viz check` goes fatal) is **confirmed at the first tick after expiry** (`fault-plus10`, T+10), with no reconnect needed.
- Clauses 1 and 2 (APIService `Available=False`, `linkerd viz tap` fails) are **confirmed only after the forced reconnect**, and are **falsified as consequences of expiry alone** across this run's entire 1770-second (29 min 30 s) post-expiry observation window: through 59 consecutive ticks the APIService stayed `Available=True` / `Passed` and `linkerd viz tap` kept returning live events from an already-expired certificate.

So the plain reading of V1 — that these three things follow from the certificate expiring — holds for the check and not for the other two. This is the same reconnect-gating the webhook experiment found ([lab-evidence-webhook-expiry.md](lab-evidence-webhook-expiry.md), W7), in a different component, and it is the finding worth carrying into the article.

### V1(a) — the tap APIService goes `Available=False`

**Verdict: confirmed only after the forced reconnect. Falsified as a consequence of expiry alone, across the 59 post-expiry ticks that span T+10 to T+1770.**

- **Last tick before expiry.** `apiservices/fault-minus10.txt` (`sampled_at_epoch=1789378408` = `09:33:28Z`, T−8): `apiservice_available_status=True`, `apiservice_available_reason=Passed`, `apiservice_available_message=all checks passed`.
- **First tick after expiry.** `apiservices/fault-plus10.txt` (`sampled_at_epoch=1789378431` = `09:33:51Z`, T+15): byte-for-byte the same three values — `True` / `Passed` / `all checks passed`. Nothing changed at expiry.
- **Last tick before the reconnect.** `apiservices/post-58.txt` (`sampled_at_epoch=1789380188` = `10:03:08Z`, T+1772): still `True` / `Passed` / `all checks passed`, 1772 s (29 min 32 s) after the certificate's `notAfter`.
- **Every tick in between.** Of the 93 `apiservices/*.txt` files, 86 record `apiservice_available_status=True` and 7 record `False`; the seven are exactly `reconnect-1.txt` … `reconnect-6.txt` and `verify.txt`. Not one pre-reconnect tick is `False`.
- **The transition has a recorded time, and it is the reconnect.** `apiservices/reconnect-0000-conditions.json` — the raw `status.conditions` read straight from the API immediately after the rollout — gives `"lastTransitionTime": "2026-09-14T10:03:30Z"`, i.e. **T+1794, 4 seconds after the `rollout restart` command at `10:03:26Z` and the same second as `reconnect-rolled-out`**. `apiservices/verify-conditions.json`, taken 162 s later at the end of the run (its message's `current time` is `2026-09-14T03:06:13-07:00` = `10:06:13Z`, against `03:03:31-07:00` = `10:03:31Z` in the reconnect snapshot), still reports the same `lastTransitionTime`. `lastTransitionTime` records only the most recent transition, so what the run establishes is narrower and enough: the recorded transition is stamped `10:03:30Z` and was unchanged 162 s later, and no sampled tick before the reconnect was `False`.
- **Each reconnect tick.** `reconnect-1` … `reconnect-6` and `verify` all read `apiservice_available_status=False`, `apiservice_available_reason=FailedDiscoveryCheck`, with the message (`apiservices/reconnect-1.txt`, `sampled_at_epoch=1789380214` = `10:03:34Z`, T+1798):

  > `failing or missing response from https://10.42.0.21:8089/apis/tap.linkerd.io/v1alpha1: Get "https://10.42.0.21:8089/apis/tap.linkerd.io/v1alpha1": tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time 2026-09-14T03:03:32-07:00 is after 2026-09-14T09:33:36Z`

  The later ticks carry the same message with later-or-equal `current time` values — `03:03:58`, `03:04:28`, `03:04:58`, `03:05:28`, `03:05:58` local for `reconnect-2` … `reconnect-6`, and `verify` repeats `reconnect-6`'s `03:05:58` rather than advancing.
- **The address in that message is the new pod.** `10.42.0.21` is the tap pod created by the restart (`pods/verify.txt`: `tap-58b5bbb494-6xwrk … 10.42.0.21`); the pod that served the whole pre-reconnect window was `tap-748d874d9b-rh7f9` at `10.42.0.9` (`pods/post-58.txt`). Every recorded discovery failure is against a connection the API server had to open fresh.
- **Nothing about the certificate changed.** `apiservice_cabundle_sha256=f4803af1f811b0b992e4e5fabd9a84e950df8defd2d1cfeeaa3fa868b6057b42` and `apiservice_backing_service=tap.linkerd-viz.svc` are identical in all 93 tick files: the same expired certificate and the same caBundle before and after. The flip is about the connection, not about the credential.

**Notes.** 1770 s is a *lower bound* on how long `Available=True` can outlive the certificate, not a measurement of it: the run forced the reconnect at a time the harness chose, and the APIService was still `True` at the last tick before that. Nothing here says whether the aggregator would have reopened the connection on its own, and when.

### V1(b) — `linkerd viz tap` fails

**Verdict: confirmed only after the forced reconnect. Falsified as a consequence of expiry alone, over 59 consecutive post-expiry captures.**

Each capture is `timeout 10s linkerd viz tap deploy/server -n lab -o json`. `[exit 124]` means `timeout` killed a stream that was still running and producing events; `[exit 1]` means the CLI itself failed. Counting the whole JSON objects in a capture is the harness's own measure (`_v_tap_events` in `demos/cert-hygiene/scenarios/30-tap-expiry.sh`); each observed request contributes three of them, which is why the baseline proof says 15 events for 5 requests.

- **Before expiry.** `tap/baseline.txt` (tick `09:20:26Z`, T−790): 15 objects (5 requests), `[exit 124]`.
- **First tick after expiry.** `tap/fault-plus10.txt` (tick `09:33:46Z`, T+10): 15 objects (5 requests), `[exit 124]` — tap was streaming live traffic 10 seconds after the certificate expired, exactly as before it.
- **Every post tick.** All 58 of `tap/post-1.txt` … `tap/post-58.txt` returned events and `[exit 124]`. Counting the set by listing its members: `post-1`, `post-20`, `post-23`, `post-24`, `post-25`, `post-28` and `post-31` returned 12 objects (4 requests) — that is **seven** ticks — and the other **51** returned 15 objects (5 requests). So the post-expiry range is 4–5 observed requests per 10-second window, not a flat 5; the variation is in how many probe requests fell inside the window, and no post tick returned zero.
- **Last capture before the reconnect.** `tap/post-58.txt` ran inside the tick that began `10:03:06Z` (T+1770) and after that tick's APIService read at `10:03:08Z`, and it ran its full 10-second window (`[exit 124]`) returning 15 objects. The k3s journal pins where it ended: the API server logs the aborted tap watch at `Sep 14 03:03:21` local = `10:03:21Z` = **T+1785**, five seconds before the `rollout restart` command.
- **Across the exit codes.** Of the 68 `tap/*.txt` captures, 60 end `[exit 124]` — `baseline`, `fault-plus10` and all 58 `post-N` — and 8 end `[exit 1]`: `reconnect-0000`, `reconnect-1` … `reconnect-6` and `verify`.
- **After the reconnect, the exact failure.** All eight `[exit 1]` captures are byte-identical (same MD5), and read in full:

  ```
  $ timeout 10s linkerd viz tap deploy/server -n lab -o json
  HTTP error, status Code [503] (unexpected API response: service unavailable
  )
  [exit 1]
  ```

  `tap/reconnect-0000.txt` is the first of them. It was taken between `reconnect-rolled-out` (`10:03:30Z`, T+1794) and the `reconnect-1` tick marker (`10:03:31Z`, T+1795) — the scenario records it immediately after the rollout, before the reconnect observation loop starts.

**Notes.** What the operator sees is a **503 from the aggregation layer, with no mention of a certificate**. The x509 text lives in the APIService condition and the API server's journal, not in the CLI's output. An article that tells a reader "tap will tell you the certificate expired" would be wrong for this version.

### V1(c) — `linkerd viz check` goes fatal on "tap API server has valid cert"

**Verdict: confirmed at the first tick after expiry (`fault-plus10`, T+10), with no reconnect needed.** Nothing was sampled between T+0 and T+10, so the run cannot place the transition more finely than that.

- **Last tick before expiry.** `viz-check/fault-minus10.txt` (tick `09:33:26Z`, T−10) ends `Status check results are √` `[exit 0]`, and its tap rows read:

  > `√ tap API server has valid cert`
  > `‼ tap API server cert is valid for at least 60 days`
  > `    certificate will expire on 2026-09-14T09:33:36Z`
  > `    see https://linkerd.io/2/checks/#l5d-tap-cert-not-expiring-soon for hints`

  So the 60-day warning was already firing throughout the pre-expiry window — the whole certificate is 15 minutes long.
- **First tick after expiry.** `viz-check/fault-plus10.txt` (tick `09:33:46Z`, T+10) is fatal:

  > `× tap API server has valid cert`
  > `    certificate is not valid anymore. Expired on 2026-09-14T09:33:36Z`
  > `    see https://linkerd.io/2/checks/#l5d-tap-cert-valid for hints`
  >
  > `Status check results are ×`
  > `[exit 1]`

  The `linkerd-viz` section stops there: the eight rows that followed the tap-certificate rows in the healthy transcript — `√ tap API service is running`, `√ linkerd-viz pods are injected`, `√ viz extension pods are running`, `√ viz extension proxies are healthy`, `√ viz extension proxies are up-to-date`, `√ viz extension proxies and cli versions match`, `√ prometheus is installed and configured correctly`, `√ viz extension self-check` — are never reached again. That is the same halt-at-first-fatal-row behaviour the webhook run recorded.
- **Every tick from then on.** The 94 `viz-check/*.txt` transcripts fall into exactly two byte-identical groups: **27** files (`baseline`, `pre-1`…`pre-24`, `fault-minus60`, `fault-minus10`) identical to the healthy transcript, and **67** files (`fault-plus10`, `post-1`…`post-58`, `reconnect-0000`, `reconnect-1`…`reconnect-6`, `verify`) identical to the fatal one. What this run shows is that the check output is the same before and after the reconnect — it never distinguishes them. *Source-derived, not observed here:* [`linkerd-source-notes.md`](linkerd-source-notes.md) § 7 records `tap API server has valid cert` as a **VERIFIED** fatal *certificate-validity* check in `viz/pkg/healthcheck/healthcheck.go` L156-192 — it inspects the certificate rather than calling the tap API, which is why a reconnect makes no difference to it.
- **Plain `linkerd check` goes fatal too.** The 93 `checks/<tick>-check.txt` transcripts split the same way — 27 healthy, 66 fatal (`fault-plus10` onward; plain `linkerd check` is not run at `reconnect-0000`) — because `linkerd check` runs the installed extension's checks as well. `checks/fault-plus10-check.txt` ends with the identical `× tap API server has valid cert` block and `[exit 1]`.

**Notes.** What the run shows: this clause needed no reconnect — the check was already fatal at the first tick after expiry and its transcript never changed afterwards. *Source-derived, not observed here:* [`linkerd-source-notes.md`](linkerd-source-notes.md) § 7 marks this row **VERIFIED** in `viz/pkg/healthcheck/healthcheck.go` L156-192 as a fatal certificate-validity check, which is why nothing has to be dialled for it to fire. It is the one signal in this run that told the truth at the first tick after the certificate expired — and it is fatal, so it also masks everything after it in the `linkerd-viz` section.

## The forced reconnect

- **What forced it.** `reconnect/backing.txt` reads `component=tap service=tap deployment=tap` — the Deployment behind the Service the tap APIService itself points at, derived from the live APIService rather than hardcoded. `reconnect/restart.txt`: `kubectl -n linkerd-viz rollout restart deploy/tap` → `deployment.apps/tap restarted` `[exit 0]`, at `10:03:26Z` (T+1790). `reconnect/rollout.txt` records the harness's wrapper verbatim — its header is `$ bash -c ns="$1"; shift` … `for d in "$@"; do kubectl -n "$ns" rollout status "deploy/$d" --timeout=300s || exit 1; done capture_rollouts linkerd-viz tap` — then three `Waiting for deployment "tap" rollout to finish: …` lines, then `deployment "tap" successfully rolled out` `[exit 0]`, at `10:03:30Z` (T+1794).
- **The pod really cycled.** `viz/reconnect-before.txt` (`sampled_at_epoch=1789380205` = `10:03:25Z`, T+1789) lists the five `linkerd-viz` pods, of which the only `tap` Deployment pod is `tap-748d874d9b-rh7f9 uid=b185223b-87ea-4046-b7be-443103b4072b`, alongside `deploy linkerd-viz/tap generation=1`. `viz/reconnect-after.txt` (`1789380210` = `10:03:30Z`, T+1794) lists two tap pods for a moment — the old one, and the new `tap-58b5bbb494-6xwrk uid=a0f11ae6-84cc-475c-8ecf-efa87f7d0008 start=2026-09-14T10:03:27Z`, with `deploy linkerd-viz/tap generation=2` and a different `template_sha256`. From `viz/reconnect-1.txt` through `viz/verify.txt` the only `tap` Deployment pod listed is the new UID, `ready=True` throughout. The four-second rollout is this single-replica Deployment genuinely completing that fast, not `rollout status` returning early.
- **What each clause did after it.** APIService: `True` → `False`/`FailedDiscoveryCheck`, transition stamped `10:03:30Z` (T+1794), 4 s after the restart command — V1(a). `linkerd viz tap`: `503`, zero events, from `reconnect-0000` onward — V1(b). `linkerd viz check`: unchanged, already fatal since T+10 — V1(c).
- **The qualifier, stated once and meant everywhere.** Every claim in this note about *when* tap or the APIService started failing names whether the API server had reconnected, because the answer is always "only after". After the expiry and before the reconnect: 59 consecutive ticks of `Available=True` and, at those same 59 ticks, 59 consecutive tap captures returning events, from a certificate that had already expired. This is the same rule and the same reason as the webhook note's W7.
- **No recovery.** V replaces nothing: `timeline.log` records `v-recover no recovery: the tap certificate is never replaced; only the forced-reconnect phase (above) ran`, and the run ends `reconnect-end after 180s of reconnect probes; V has no recovery to follow`. So this run says nothing about how tap recovers.

## Mesh traffic

**The meshed data plane was untouched, for the whole run.** Across the four probe logs in `probes/final/`, there are **5490** outcome lines and **5489** of them end `ok`; the single line that does not is `probe-tcp-stream`'s own `connect` line at `09:20:22Z` that opens its long-lived connection, not a failure. Individually: `probe-http` 1371 `ok`, `probe-tcp-new` 1371 `ok`, `probe-tcp-new-b` 1371 `ok`, `probe-tcp-stream` 1376 `ok` after one `connect` — with no `closed` line, so the single held-open TCP connection survived from `09:20:22Z` to the last line at `10:06:20Z`, straight through both the expiry and the tap restart. The four `-previous.log` files hold three lines each — the `$ kubectl -n lab logs <pod> -c probe --previous` command line, `Error from server (BadRequest): previous terminated container "probe" in pod "<pod>" not found`, and `[exit 1]`. That is `kubectl`'s answer when a pod was never restarted, not a traffic failure.

There is nothing to label restart-adjacent here, because nothing failed: the tap Deployment restart at T+1790 is in the `linkerd-viz` namespace and disturbed no lab probe. The post-expiry workload actions also succeeded: `post-actions/probe-new.txt` created a new Deployment at T+60 and `post-actions/restart-target.txt` restarted an existing one, and at `verify` both are `2/2 Running` (`pods/verify.txt`) — the proxy injector kept injecting, since its own certificate is Linkerd's and never expired in this run.

## Supplementary: the k3s journal

`logs/final/k3s-journal.txt` covers the whole run: its first line is `$ sudo journalctl -u k3s --since @1789377395 --no-pager`, and epoch `1789377395` is `09:16:35Z` — the `reset` marker, T−1021. Its timestamps carry the VM's local `-07:00` offset; checked against a recorded UTC value before converting, as the reading guide requires — the new tap pod's volume-attach lines are stamped `Sep 14 03:03:27` for UID `a0f11ae6-84cc-475c-8ecf-efa87f7d0008`, whose `start=2026-09-14T10:03:27Z` is recorded in `viz/reconnect-after.txt`.

- **Zero expired-certificate entries before the reconnect.** `v1alpha1.tap.linkerd.io` appears on **104** lines (**135** occurrences); **37** of those 104 lines carry `x509: certificate has expired`, and **none** of the 37 is earlier than `03:03:30` local. The first is `Sep 14 03:03:30.509549` = `10:03:30.509Z` = **T+1794**, from `remote_available_controller.go:471` — the aggregator's own availability controller, logging the same failure the APIService condition records, in the same second as the transition.
- **Tap was demonstrably reaching the tap API server until then.** The journal holds exactly **60** `wrap.go:53` "Timeout or abort while handling" lines for `URI="/apis/tap.linkerd.io/v1alpha1/watch/namespaces/lab/deployments/server/tap"` — one per bounded tap capture: `baseline`, `fault-plus10` and the 58 `post-N` ticks, the same 60 captures that ended `[exit 124]`. The first is `Sep 14 02:20:46` = `09:20:46Z` (the baseline probe's own timeout, T−770) and the last is `Sep 14 03:03:21` = `10:03:21Z` (T+1785). Requests were being served through the aggregated API, over an expired certificate, right up to the restart.

This is supplementary evidence only, but it agrees exactly with the per-tick records: **nothing on the aggregated-API path failed at the certificate's expiry** — the APIService stayed `Available=True` and tap kept streaming — **and that path failed four seconds after the API server was made to open a new connection.** `linkerd viz check` is the exception, and it is the one clause of V1 that needs no reconnect: fatal from `fault-plus10`, T+10.

## What this means for the article

- **This moves the last untested triage row.** "`linkerd viz tap` and other viz features stop working / Viz tap API certificate expired" is currently in the *predicted, not tested* half of [findings.md](../findings.md)'s triage table, sourced to inference from Linkerd's code. This run tests it. The row can move — provided it moves with its qualifier, not without it. Artifacts a reader can check: `apiservices/*.txt` and the three `*-conditions.json` snapshots, `tap/*.txt`, `viz-check/*.txt`, `certs/tap.txt`, `reconnect/`, and `logs/final/k3s-journal.txt`, all under `demos/cert-hygiene/runs/30-tap-expiry/20260914T091635Z` (read them with `tools/evidence.sh cat` or `fetch`).
- **The headline is not "tap breaks when the certificate expires." It is "tap kept working for half an hour after the certificate expired, and broke four seconds after the tap pod was restarted."** In this run the tap APIService stayed `Available=True` and `linkerd viz tap` kept streaming live events through 1770 seconds and 59 ticks of an expired certificate; both failed only once a `rollout restart` forced the API server to open a fresh connection to a new tap pod. That is the same reconnect-gating the webhook experiment found for two of its three webhooks — a second component, reached over a different path (the artifacts here are an `APIService` condition and `remote_available_controller` journal entries, not admission responses), the same operational trap.
- **The 29½ minutes is a lower bound, not a measurement, and it is one run.** The reconnect was forced at a moment the harness chose, while the APIService was still `True`; nothing here says how long it would have lasted otherwise, or whether a real cluster's aggregator would reopen the connection sooner. Do not quote it as a duration tap survives.
- **`linkerd viz check` is the one signal that fired at the expiry — and it is also the one that hides things.** It went fatal on `tap API server has valid cert` at the first tick after expiry (`fault-plus10`, T+10; nothing was sampled in between), with no reconnect needed, and stayed fatal and byte-identical for the rest of the run; plain `linkerd check` did the same, since it runs the extension's checks. But being fatal, it truncates the `linkerd-viz` section at that row — every later viz row (`tap API service is running`, the extension's pods and proxies, prometheus, self-check) disappears from the output. A reader debugging a viz problem should know that one expired tap certificate blanks the rest of the section.
- **What an operator actually sees from the CLI is a 503, with no mention of certificates.** `HTTP error, status Code [503] (unexpected API response: service unavailable)`. The x509 explanation is in `kubectl get apiservice v1alpha1.tap.linkerd.io -o yaml` (the `Available` condition's message) and in the API server's log — not in tap's output. That is worth saying plainly in the article's triage guidance.
- **Mesh traffic is unaffected, and this run says so cleanly.** 5489 of 5490 probe outcomes `ok`, the one exception being a `connect` line; the held-open TCP stream never broke; new workloads were still injected and became Ready during the post-expiry window. An expired tap certificate is an observability outage, not a data-plane one — in this run.
- **Credential-model caveat, on everything above.** The tap certificate here is lab-supplied, static and never rotated, so that it could be made to expire on schedule. Real installations let `linkerd viz install` issue it. Nothing in this run says how or whether that certificate is rotated in a default installation, or what recovery looks like — V replaces no credential and has no recovery phase, by design.
