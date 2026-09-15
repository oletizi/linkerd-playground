# Evidence: two failures that are not expiry

Every failure this lab has reproduced so far turned on a `notAfter` passing. These two do not. **N** takes a webhook whose certificate is perfectly healthy and removes the pods behind it. **G** leaves the pods alone and gives one webhook a certificate that is time-valid and correctly chained but signed with an algorithm the API server refuses. They are written up together because they make one argument: a symptom does not identify a cause, and the article's triage table has to say what does.

- **Runs:** `demos/cert-hygiene/runs/40-webhook-unavailable-ignore/20260914T231908Z` (**NI**, `failurePolicy=Ignore`), `demos/cert-hygiene/runs/40-webhook-unavailable-fail/20260914T233902Z` (**NF**, `failurePolicy=Fail`), `demos/cert-hygiene/runs/41-webhook-algorithm/20260914T235908Z` (**G**) — all three `evidence_valid=yes`.
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/20260914T221528Z` (`evidence_valid=yes`). All four `git-state.txt` files carry `harness_tree_sha256=342ddd8a34619d5c54db11c93c26d0dec905e1ec6b0f459c5ef2754906e5de8e` and `demo_repo_dirty=false`.
- **Versions** (`versions.txt`, all three runs): `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`, `kubernetes_version=v1.36.4+k3s1`, `k3s version v1.36.4+k3s1 (4dedb15b)`.
- **Credentials, all three runs:** lab-supplied static webhook serving certificates — `config_WEBHOOK_CERT_LIFETIMES=proxyInjector=24h policyValidator=24h profileValidator=24h` — not how Linkerd normally runs. *Source-derived, not observed here:* [`linkerd-source-notes.md`](linkerd-source-notes.md) § 5 records (**VERIFIED**) that Linkerd's chart self-generates these certificates hard-coded to **365 days** via `genSelfSignedCert`, with no value to change it, and (**INFERRED**) that because the templates use no `lookup`, every re-render issues brand-new webhook certificates and caBundles — an implicit rotation. No rotation controller for these Secrets is recorded anywhere in the source notes, and this lab has never tested the default path. `config_ANCHOR_LIFETIME=87600h`, `config_ISSUER_LIFETIME=8760h`, `config_LEAF_LIFETIME=5m`. Nothing expires in any of the three runs. G's refused certificate additionally comes from tooling the lab otherwise avoids; see "How the refused certificate was made" below. **Both caveats attach to every claim on this page.**
- **Failure policies:** NI `config_EXTRA_INSTALL_FLAGS=` (empty — the install passes no policy flag), and `webhooks/<tick>.txt` records `failurePolicy=Ignore` on all three webhooks. NF and G `config_EXTRA_INSTALL_FLAGS=--set webhookFailurePolicy=Fail`, recorded as `failurePolicy=Fail` on all three. *Source-derived, not observed here:* [`linkerd-source-notes.md`](linkerd-source-notes.md) § 6 records `webhookFailurePolicy: Ignore` as the chart's own default (**VERIFIED**, `values.yaml` L415-416), which is what NI's empty flag leaves in place.

**N and G did not test the same component.** N scales the **proxy injector** to zero. G refuses the **ServiceProfile validator**'s certificate. That was a deliberate ruling, recorded in `lab/scenario-g.sh`: a refused proxy-injector certificate under `failurePolicy=Fail` would fail every pod creation in injected namespaces, and a run that cannot recover is a lost run. So nothing below compares three causes on one component; where a comparison crosses components, it says so.

**Scale of the evidence.** N ran twice, once per policy. G ran once. Everything here is what happened in those runs, on this Linkerd and k3s version, at these lifetimes — not what always happens. Paths are relative to each run directory unless prefixed `demos/`. `T+N` means N seconds after that run's own `t_mark` line in `timeline.log`.

## Phases

| Run | T_mark | Fault | Fault-phase probe sets (`admission/fault-NNNN`) | Recovery issued | Settled | `done` |
| --- | --- | --- | --- | --- | --- | --- |
| NI | `2026-09-14T23:31:13Z` | `scale-down linkerd-proxy-injector -> 0` at `23:31:14Z` (T+1) | T+31, +60, +81, +112, +142, +172 | `scale-up` `23:34:11Z` (T+178) | `settled proxy-injector serving: yes` `23:34:16Z` (T+183) | `23:34:29Z` |
| NF | `2026-09-14T23:51:18Z` | `scale-down` at `23:51:18Z` (T+0) | T+33, +60, +81, +112, +142, +172 | `scale-up` `23:54:15Z` (T+177) | `settled … serving: yes` `23:54:19Z` (T+181) | `23:54:31Z` |
| G | `2026-09-15T00:11:24Z` | `fault-cert-built` / `swap-restart linkerd-destination` at `00:11:25Z` (T+1) | T+11, +60, +65, +93, +124, +153 | `swap-restore` `00:14:01Z` (T+157) | `settled sp-validator restore: serving` `00:14:08Z` (T+164) | `00:14:21Z` |

Intervals, subtracted from the two `timeline.log` timestamps each derives from:

- **NI's injector was scaled to zero for 177 s** — `23:31:14Z` to `23:34:11Z` (`23:31:14` + 60 = `23:32:14`, + 60 = `23:33:14`, + 57 = `23:34:11`). **NF's, also 177 s** — `23:51:18Z` to `23:54:15Z`. Both are 3 s short of `config_N_FAULT_WINDOW_S=180`, because `recover` fires at the post-window boundary tick rather than exactly 180 s after T_mark.
- **NI's observed fault span is 141 s** — its six `dispatcher.go:210]` *failing-open* journal entries, first `Sep 14 16:31:44` (`23:31:44Z`) to last `Sep 14 16:34:05` (`23:34:05Z`), quoted under N2. **NF's is 139 s** — its six `dispatcher.go:225]` *failing-closed* entries, `Sep 14 16:51:51` (`23:51:51Z`) to `Sep 14 16:54:10` (`23:54:10Z`), quoted under N1. The two runs' entries come from different call sites and say different things; they are not the same lines and this note does not treat them as such. Both are converted from the VM's local `-07:00` offset, checked against each run's own records as the [reading guide](lab-evidence-reading-guide.md) requires: NI's `Sep 14 16:31:44` against `admission/fault-0031/inject-probe-fault-plus10.observed.yaml`'s `creationTimestamp: "2026-09-14T23:31:44Z"`; NF's `Sep 14 16:51:51` against `admission/fault-0033/policy-valid-fault-plus10.observed.yaml`'s `creationTimestamp: "2026-09-14T23:51:51Z"`; G's `Sep 14 17:11:32` against `swap/settle-fault.txt`'s `2026-09-15T00:11:32Z state=refused`.
- **G's sp-validator was observably refusing for 156 s** — `swap/settle-fault.txt` `2026-09-15T00:11:32Z state=refused` to `swap/settle-restore.txt` `2026-09-15T00:14:08Z state=serving` (`00:11:32` + 60 = `00:12:32`, + 60 = `00:13:32`, + 36 = `00:14:08`). From the restart that installed it (`swap-restart`, `00:11:25Z`) to the same instant is 163 s.
- Recovery was quick in all three: NI settled 5 s after `scale-up`, NF 4 s after, G 6 s after `swap-restart-restore` (`00:14:02Z` to `00:14:08Z`).

## Acceptance conditions (design § 5)

| Scenario | Condition | Verdict | Where |
| --- | --- | --- | --- |
| N | Both policies recorded, each with a healthy baseline proving its probe | met | Two runs, both `evidence_valid=yes`; `admission-baseline.txt` `result=ok` with five `ok:` lines in each |
| N | The webhook's certificate shown valid at every tick | met | `webhook-cert-state/`, 27 files per run, one distinct line each (N3 below) |
| N | The exact API error preserved for `Fail` | met | Six `admission/fault-*/inject-probe-*.response.txt` in NF (N1 below) |
| N | The admitted object preserved for `Ignore` | met | Six `admission/fault-*/inject-probe-*.observed.yaml` in NI (N2 below) |
| N | Replicas shown restored and the probe working again | met | `scale/scale-up.txt`, `scale/rollout-up.txt` (both `[exit 0]`), `scale/settle.txt` `state=yes`, `admission-restored.txt` `result=ok` |
| G | The refused certificate's `notAfter` recorded at every tick and in the future at all of them | met **on the implementation's reading**; not meetable as literally written — see below | `timevalidity/`, 27 files |
| G | The exact API-server error preserved verbatim | met | Twelve `admission/fault-*/serviceprofile-*.response.txt` (G1 below) |
| G | `linkerd check`'s certificate row for that webhook recorded before and during | met | `checks/baseline-check.txt` and five fault-tick transcripts (G3 below); also after, `checks/verify-check.txt` |
| G | A normally-signed certificate shown working in the same run, before the swap | met | `admission-baseline.txt` `result=ok`; `certs/webhook-profileValidator.txt` `Signature Algorithm: SHA256-RSA`; 22 pre-swap and post-restore ticks recording that certificate live |

**Why G's first condition cannot be met as written, and what was done instead.** The condition asks for "the refused certificate's `notAfter` recorded at every tick". The refused certificate did not exist at every tick: it was built at `00:11:25Z` and replaced at `00:14:01Z`, so it was installed at five of the run's 27 ticks. What `timevalidity/<tick>.txt` records instead is whichever certificate the Secret actually held at that tick, read live from the Secret — the refused one at five ticks, the original SHA-256 one at the other 22. That reading is at least as strong as the literal one. The literal condition constrains only one certificate; this record constrains *every* certificate the webhook served during the run, and all 27 ticks show `openssl_x509_checkend_0_exit=0` with a positive `seconds_until_notAfter`. There is therefore no tick at which any expired certificate was in place, which is the thing the condition exists to establish — G cannot be confused with an expiry run. Meeting it literally would have required reading the refused certificate's `notAfter` from somewhere other than the live Secret at ticks where it was not installed, which is a weaker record, not a stronger one.

---

# Scenario N — the webhook is unavailable

`lab/scenario-n.sh` scales the Deployment behind the proxy-injector Service to zero, waits for its pods to actually be gone, probes the admission path six times, then scales back and proves the webhook serving again. `scale/backing.txt` in both runs: `component=proxyInjector service=linkerd-proxy-injector deployment=linkerd-proxy-injector`. `scale/pods-gone.txt` shows the wait succeeding — NI `pod/linkerd-proxy-injector-785cbd5c79-qzcsk condition met`, NF `pod/linkerd-proxy-injector-68c68c9fb6-2ddw2 condition met` — before any fault probe ran. In both runs, `controlplane/fault-after.txt` and all five fault-window ticks (`fault-plus10`, `post-1` … `post-4`) list **no** `pod linkerd/linkerd-proxy-injector-…` line at all, and record `deploy linkerd/linkerd-proxy-injector … replicas=0 readyReplicas=0`.

## N1 — with `Fail`, the request is rejected with a connection-level error naming the service, and no X.509 or time-validity language

**Verdict: confirmed, in the one `Fail` run.**

All six fault-window `inject-probe-*.response.txt` files in NF carry the same text, differing only in the request path each embeds:

> `Error from server (InternalError): error when creating "runs/40-webhook-unavailable-fail/20260914T233902Z/admission/fault-0033/inject-probe-fault-plus10.request.yaml": Internal error occurred: failed calling webhook "linkerd-proxy-injector.linkerd.io": failed to call webhook: Post "https://linkerd-proxy-injector.linkerd.svc:443/?timeout=10s": no endpoints available for service "linkerd-proxy-injector"` `[exit 1]`

- The six files are `admission/fault-0033`, `-0060`, `-0081`, `-0112`, `-0142`, `-0172`, each holding `inject-probe-<tick>.response.txt`; all six end `[exit 1]` and all six contain `no endpoints available for service "linkerd-proxy-injector"`.
- `grep -Ei 'x509|certificat|[^a-z]tls[^a-z]|expire|not yet valid|notAfter'` across those six files returns **nothing**. The error names the webhook (`linkerd-proxy-injector.linkerd.io`), the Service (`linkerd-proxy-injector.linkerd.svc` / `"linkerd-proxy-injector"`) and a connection-level cause.
- The object was never created: each matching `inject-probe-*.observed.yaml` reads `Error from server (NotFound): pods "inject-probe-<tick>" not found` `[exit 1]`. Consequently those six directories hold 17 files where the baseline holds 18 — the missing one is `inject-probe-*.delete.txt`, since the harness only deletes what it created. That is the expected shape of a rejected create, not a gap in the record.
- The k3s journal agrees, with six entries — one per fault-phase probe set, and the *only* six `failed calling webhook` lines in NF's whole journal:

  > `Sep 14 16:51:51 cert-hygiene-lab k3s[427649]: W0914 16:51:51.556165  427649 dispatcher.go:225] Failed calling webhook, failing closed linkerd-proxy-injector.linkerd.io: failed calling webhook "linkerd-proxy-injector.linkerd.io": failed to call webhook: Post "https://linkerd-proxy-injector.linkerd.svc:443/?timeout=10s": no endpoints available for service "linkerd-proxy-injector"`

  `grep -c x509 logs/final/k3s-journal.txt` = **0** for the whole run. NI's corresponding entries are a different line, from a different call site — see N2.
- **Scope.** The four other probe kinds were untouched: at all six fault ticks `policy-valid` and `serviceprofile-valid` were created (`[exit 0]`) and `policy-invalid` and `serviceprofile-invalid` were denied with their ordinary validation text (`data did not match any variant of untagged enum Cidr`; `RetryBudget: time: invalid duration "not-a-duration"`), exactly as at baseline. N1 speaks only of requests matching the unavailable webhook's rules, and only those failed.

## N2 — with `Ignore`, the pod is admitted without a proxy, exactly as an expired certificate produced

**Verdict: confirmed — and the two admitted objects are, for practical purposes, the same object.** This is the hypothesis the scenario exists to answer, so it gets the detail.

**What NI recorded.** All six fault-window `inject-probe-*.response.txt` read `pod/inject-probe-<tick> created` `[exit 0]`. All six `inject-probe-*.observed.yaml` contain **zero** occurrences of `name: linkerd-proxy` and **no `initContainers` key at all**; `spec.containers` holds one container, `idle`. Outside the fault window the same probe always got a proxy: the baseline, all 20 pre-fault ticks (`pre-1`…`pre-18`, `fault-minus60`, `fault-minus10`) and the `verify` tick each show three `name: linkerd-proxy` lines and an `initContainers` key.

**The one recorded signal in N that differs by failure policy is the API server's own log, and under `Ignore` it is the only place the skipped call appears at all.** The client sees `[exit 0]` and a created pod; nothing in the response says a webhook was skipped. (`linkerd check` reports the underlying outage in both runs, byte-identically — see N4 — so it does not distinguish the policies.) What the API server records is this, six times, once per fault-phase probe set, at a call site NF never reaches:

> `Sep 14 16:31:44 cert-hygiene-lab k3s[364038]: W0914 16:31:44.497061  364038 dispatcher.go:210] Failed calling webhook, failing open linkerd-proxy-injector.linkerd.io: failed calling webhook "linkerd-proxy-injector.linkerd.io": failed to call webhook: Post "https://linkerd-proxy-injector.linkerd.svc:443/?timeout=10s": no endpoints available for service "linkerd-proxy-injector"`

Each is immediately followed, at the same millisecond, by an `E… dispatcher.go:214] "Unhandled Error" err="failed calling webhook …" logger="UnhandledError"` line carrying the same text escaped — so NI's journal holds **12** `failed calling webhook` lines for 6 failed calls, where NF holds **6** for its 6. `grep -o 'dispatcher.go:[0-9]*\] Failed calling webhook, failing [a-z]*'` over each journal returns exactly one shape per run: `dispatcher.go:210] … failing open` six times in NI, `dispatcher.go:225] … failing closed` six times in NF. The failure policy is legible in the log line itself, in a word, from a different call site — and under `Ignore` that log line is the whole of the evidence that anything went wrong.

**The comparison with expiry.** Take the equivalent artifact from the webhook-expiry experiment: `demos/cert-hygiene/runs/02-webhook-expiry-ignore/20260912T095814Z` (`evidence_valid=yes`, `harness_tree_sha256=e86c787ea2317ecdbc45e607681b83bba0f9e94b48f7f87aed3d95f0d274e7c8` — a different harness tree, so this is a comparison across trees, not a controlled pair), file `admission/reconnect-0000/inject-probe-reconnect-0.observed.yaml`. Both files are **124 lines**. Removing the harness's `$ kubectl` header line, every line naming the object (`inject-probe-…`), and the lines carrying `uid:`, `resourceVersion`, `creationTimestamp` and the per-pod `kube-api-access-…` token volume name, the two files differ in **six lines**: five `lastTransitionTime` values and one `startTime`. Everything else — the single `idle` container, its image digest, the absent `initContainers`, the volumes, the conditions, the status shape — is identical, character for character.

**What a reader can conclude.** Under `failurePolicy=Ignore`, the object a reader would find when investigating — a pod running without its sidecar — does not tell them whether the injector was *down* or whether its certificate had *expired*. Inspecting the admitted pod is a dead end for distinguishing these two causes.

**What a reader cannot conclude.**

- Not that the two causes are hard to tell apart generally. They separate immediately on three other signals, all recorded here: `linkerd check` (a readiness failure for N, a certificate failure for expiry — see the table at the end), the API server's own log line (`no endpoints available for service` versus `x509: certificate has expired`), and a plain `kubectl -n linkerd get pods` for the webhook's Deployment, which in N has nothing to show and in the expiry runs shows a healthy, running pod.
- Not that the *timing* is the same. In NI the proxy-less pod appeared at the **first** probe after the fault (T+31). In the expiry run it did not appear until the API server was forced to reconnect: at `admission/post-0012/inject-probe-fault-plus10.observed.yaml`, twelve seconds after the injector's certificate expired, the pod still has `initContainers` and `name: linkerd-proxy`. An unavailable webhook has no connection to reuse; an expired certificate on a running webhook does. That difference is the subject of [`lab-evidence-webhook-expiry.md`](lab-evidence-webhook-expiry.md) and it is why "pods are coming up without proxies" arrives at a very different moment in the two cases.
- Not that this generalises past one `Ignore` run of N compared against one `Ignore` run of W, on this Linkerd version, with these lifetimes.

## N3 — the webhook's serving certificate is valid for the whole run

**Verdict: confirmed, in both runs, at every recorded tick.**

`webhook-cert-state/` holds **27** files in each run, one per tick — listed by name: `baseline` (1), `pre-1` … `pre-18` (18), `fault-minus60`, `fault-minus10`, `fault-plus10` (3), `post-1` … `post-4` (4), `verify` (1); 1 + 18 + 3 + 4 + 1 = 27. In each run all 27 files hold a single distinct line:

- **NI:** `component=proxyInjector secret_sha256=5d0a3d15… supplied_sha256=5d0a3d15… equals_supplied=yes not_after_epoch=1789514454 valid_now=yes cabundle_verifies=yes`
- **NF:** `component=proxyInjector secret_sha256=aaf872d8… supplied_sha256=aaf872d8… equals_supplied=yes not_after_epoch=1789515644 valid_now=yes cabundle_verifies=yes`

`grep -L` for each of `equals_supplied=yes`, `valid_now=yes` and `cabundle_verifies=yes` returns no files in either run. `not_after_epoch=1789514454` is `2026-09-15T23:20:54Z` (NI) and `1789515644` is `2026-09-15T23:40:44Z` (NF). Remaining validity at each run's last fault-window tick, subtracted from the epochs themselves:

- NI, tick `post-4` at `23:33:44Z` (T+151, epoch 1789428673 + 151 = 1789428824): 1789514454 − 1789428824 = **85 630 s = 23 h 47 m 10 s**.
- NF, tick `post-4` at `23:53:49Z` (T+151, epoch 1789429878 + 151 = 1789430029): 1789515644 − 1789430029 = **85 615 s = 23 h 46 m 55 s**.

An independent cross-check inside NI: `checks/baseline-check.txt` prints `‼ proxy-injector cert is valid for at least 60 days` / `certificate will expire on 2026-09-15T23:20:54Z` — `linkerd check`'s own reading of the same certificate, agreeing to the second with `not_after_epoch`.

**How the second clause is read.** N3 as written asks for "the same fingerprint as the configured `caBundle`", which is not a well-formed property of a leaf certificate and is not what the run records. What `w_fact_line` (`lab/lib-evidence-scenarios.sh`) records is two things that are better formed and together stronger: `cabundle_verifies` is the result of `openssl verify -partial_chain -CAfile <the live webhook configuration's caBundle> <the live Secret's certificate>`, and `equals_supplied` compares the live Secret's certificate fingerprint with the lab-supplied one. Both are `yes` at all 27 ticks in both runs: the certificate the webhook served still chained to the bundle the API server was configured to trust, and it was still the certificate the run installed.

## N4 — `linkerd check` reports the problem as a readiness failure, and no certificate row goes fatal

**Verdict: confirmed on its first clause. Its second clause is true, but only because `linkerd check` never evaluates a certificate row at all while the fault is present.**

Every fault-window transcript in both runs (`checks/fault-plus10-check.txt`, `post-1` … `post-4`) is **26 lines and 4 sections**, ends `[exit 1]`, and is byte-identical to the others — within each run, and *between* the runs (NI's `fault-plus10-check.txt` and NF's are byte-identical, since the transcript carries no run-specific text). It ends:

> `linkerd-existence`
> `-----------------`
> `√ 'linkerd-config' config map exists`
> `√ heartbeat ServiceAccount exist`
> `√ control plane replica sets are ready`
> `√ no unschedulable pods`
> `× control plane pods are ready`
> `    No running pods for "linkerd-proxy-injector"`
> `    see https://linkerd.io/2/checks/#l5d-api-control-ready for hints`
>
> `Status check results are ×`
> `[exit 1]`

The baseline, all 18 pre-fault ticks, both `fault-minus` ticks and the `verify` tick are **85 lines and 11 sections**, ending `Status check results are √` `[exit 0]`.

- **First clause: confirmed.** The problem is reported, and reported as a readiness problem — `control plane pods are ready` / `No running pods for "linkerd-proxy-injector"` — with no certificate language anywhere in the output.
- **Second clause: vacuously true.** Seven of the eleven sections are absent from the fault transcripts, `linkerd-webhooks-and-apisvc-tls` among them, and three further rows inside `linkerd-existence` itself (`cluster networks contains all node podCIDRs`, `… all pods`, `… all services`) are never printed either. No certificate row goes fatal because no certificate row runs. The run therefore cannot show that the certificate rows *would* have stayed green; N3 shows the certificate was in fact fine, but `linkerd check` did not say so.
- `linkerd check --proxy` adds nothing: at every checked fault tick in both runs its transcript differs from the plain one only on line 1 (the recorded command).
- `linkerd viz check` does not appear in this scenario at all. N's `lab/collect.sh` captures only `linkerd check --wait 20s` and `linkerd check --proxy --wait 20s`; there is no viz output for N to quote.

## N5 — mesh traffic between already-running workloads is unaffected

**Verdict: confirmed, in both runs, for the whole run.**

Four long-lived probes per run (`probe-http`, `probe-tcp-new`, `probe-tcp-new-b`, `probe-tcp-stream`). `probes/final/pods.txt` shows all four `2/2 Running`, `RESTARTS 0`, in each run. Reading every line of each `probes/final/<pod>.log`: apart from the `$ kubectl … logs` header, the `[exit 0]` footer and the stream probe's single `seq=0 … connect target=server.lab.svc.cluster.local:9000` line, **every** line's outcome field is `ok`.

| Run | `probe-http` | `probe-tcp-new` | `probe-tcp-new-b` | `probe-tcp-stream` | `ok` lines inside the injector's down window, per probe |
| --- | --- | --- | --- | --- | --- |
| NI | 395 | 396 | 396 | 397 (+1 connect) | 91 of 91 |
| NF | 394 | 394 | 394 | 396 (+1 connect) | 91 of 91 |

The `seq=` counters run without a gap from first to last in all eight logs (NI 1–395 / 1–396 / 1–396 / 0–397; NF 1–394 / 1–394 / 1–394 / 0–396). The down windows used above are `23:31:14Z`–`23:34:16Z` (NI) and `23:51:18Z`–`23:54:19Z` (NF), each from the scale-down command to the `settled` marker. The four `probes/final/*-previous.log` files in each run are three lines each — the `$ kubectl -n lab logs <pod> -c probe --previous` header, then `Error from server (BadRequest): previous terminated container "probe" in pod "<pod>" not found`, then `[exit 1]`. That `[exit 1]` is the one place in these probe records where the footer is not `[exit 0]`, and it is not a probe failure: it is `kubectl` reporting that there is no previous container to read, which is what `RESTARTS 0` implies.

## Why `failurePolicy=Fail` did not deadlock the cluster

This is not one of N1–N5, but it is the first thing a reader will ask, and NF answers part of it.

Under `Fail`, a pod CREATE that the injector's webhook matches is rejected while the Service has no endpoints — that is N1, six times over, in namespace `lab`. Restoring the injector requires creating a pod. NF recovered anyway, in 4 s.

**What the run shows.** `controlplane/recover-scaled-up.txt` and `controlplane/verify.txt` both record `pod linkerd/linkerd-proxy-injector-68c68c9fb6-q6z2s uid=aab14fa4-109b-408c-8a37-1887b35e8cc2 start=2026-09-14T23:54:15Z phase=Running ready=True restarts=0 trust=21a3391657024676dfcdee32f0ad818f6019618c24a366a1a0dcd4404311f357` — the replacement pod's `.status.startTime` is `23:54:15Z`, the same second `scale/scale-up.txt` was issued, and 4 s **before** `scale/settle.txt` records `2026-09-14T23:54:19Z state=yes` (the injector serving again). `events/final.txt` records `linkerd … Normal SuccessfulCreate replicaset/linkerd-proxy-injector-68c68c9fb6 … Created pod: linkerd-proxy-injector-68c68c9fb6-q6z2s` and `linkerd … Normal Scheduled pod/linkerd-proxy-injector-68c68c9fb6-q6z2s`. `grep -c FailedCreate events/final.txt` returns 3, and all three are `FailedCreatePodSandBox` events in `kube-system` from node startup roughly fourteen minutes earlier (flannel `subnet.env` races); there are **zero** `FailedCreate` events in the `linkerd` namespace. The k3s journal's last `no endpoints available` webhook line is at `23:54:10Z`, with none at or after the replacement pod's creation. So a pod CREATE in the `linkerd` namespace was admitted while the proxy-injector Service had no ready endpoints and `failurePolicy=Fail` was set — the exact condition that rejected all six probes in `lab`.

**What the run cannot show: why.** Of each webhook configuration, `webhooks/<tick>.txt` records the object name, the webhook name, `failurePolicy` and `caBundle_sha256` — and, per component, the serving Secret's `sha256`, `serial`, `not_after_epoch`, `not_after` and `sans`, under a `sampled_at_epoch` header. What it does not record is any selector or any rule: `grep -rl 'namespaceSelector'` and `grep -rl 'objectSelector'` over the whole run return no files. The run never read the live webhook configuration's selectors or rules, so it cannot say what exempted that pod — only that something did.

One half of the explanation *is* observed here: the injector's own pods carry the label `linkerd.io/control-plane-component=proxy-injector`. `scale/pods-gone.txt` ran `kubectl -n linkerd wait --for=delete pod -l linkerd.io/control-plane-component=proxy-injector` (the selector derived from the Deployment itself) and it matched `pod/linkerd-proxy-injector-68c68c9fb6-2ddw2`.

***Source-derived, not observed here:*** [`linkerd-source-notes.md`](linkerd-source-notes.md) § 6 records, marked **VERIFIED** against `charts/linkerd-control-plane/templates/proxy-injector-rbac.yaml` L80-120, that `linkerd-proxy-injector-webhook-config`'s `objectSelector` is `linkerd.io/control-plane-component DoesNotExist` together with `linkerd.io/cni-resource DoesNotExist`. An object carrying that label does not match the webhook, so the API server never calls it for that object, whatever the failure policy says. That is a reading of Linkerd's chart, not of this cluster: the run never read the live configuration back, so "the chart default was in force here" is inference, not observation. Settling it would take a run that records each webhook's `namespaceSelector`, `objectSelector` and `rules` per tick.

---

# Scenario G — the certificate is refused for its algorithm

`lab/scenario-g.sh` builds a leaf for `linkerd-sp-validator.linkerd.svc`, signed by the same lab webhook CA the working certificate uses, with the same subject, the same SAN and the same key usage, but a different signature algorithm — and, as the table below shows, two further differences the harness's own comment ("everything about it correct except the thing under test") does not account for; patches it into the live Secret; restarts the backing Deployment so it is actually served; probes; then patches the original back and restarts again. `swap/backing.txt`: `component=profileValidator service=linkerd-sp-validator deployment=linkerd-destination`. Both patches, both restarts, both rollouts and both `wait --for=delete` captures end `[exit 0]`.

**The two certificates, from the run's own `certs/` records:**

| | `webhook-profileValidator.txt` (working) | `webhook-profileValidator-algorithm.txt` (refused) |
| --- | --- | --- |
| Signature Algorithm | `SHA256-RSA` | `SHA1-RSA` (both the TBS block and the outer signature) |
| Public key | RSA, 2048 bit | RSA, 2048 bit |
| Issuer | `CN=lab-webhook-ca` | `CN=lab-webhook-ca` |
| Subject | `CN=linkerd-sp-validator.linkerd.svc` | `CN=linkerd-sp-validator.linkerd.svc` |
| Serial | `0xd50e3f7ea48b4da3c2bfa7e3760a5dc0` | `0x8ee7f22f466d78094538a08378ee3359` |
| X509v3 Key Usage (critical) | `Digital Signature, Key Encipherment` | `Digital Signature, Key Encipherment` |
| X509v3 Extended Key Usage | `Server Authentication, Client Authentication` | **`Server Authentication`** only |
| X509v3 Subject Alternative Name | `DNS:linkerd-sp-validator.linkerd.svc` | `DNS:linkerd-sp-validator.linkerd.svc` |
| Not Before / Not After | `Sep 15 00:01:03 2026 UTC` / `Sep 16 00:01:03 2026 UTC` (24 h) | `Sep 15 00:11:25 2026 UTC` / `Sep 12 00:11:25 2036 UTC` (87 600 h) |

**Two rows differ besides the signature algorithm, and both are artefacts of how the credential is built rather than part of the fault.** `_SHA1_LEAF_TEMPLATE` in `lab/lib-webhook.sh` names `"extKeyUsage": ["serverAuth"]` explicitly, where the working certificate comes from `step`'s own leaf profile and gets client authentication as well; and the refused leaf was given `config_G_ALGORITHM_CERT_LIFETIME=87600h` rather than the profile's 24 h, which is what makes G2 provable. Neither is implicated by anything the run recorded: the role under test is the webhook's *server* side, and `Server Authentication` is present in both; every recorded error — the twelve client responses, the thirteen journal entries and the `linkerd check` row — names the signature algorithm, and none of them mentions key usage or a date. That is an argument from what the run recorded, not a proof: a run that varied the signature algorithm alone, holding the extended key usage and the lifetime fixed, would settle it and this one does not.

`webhooks/<tick>.txt` corroborates the swap from a second direction and shows how narrowly it was scoped — one Secret, nothing else. `caBundle_sha256=36a7e8e5a549365965ae698ac146860af3a4ec65cf11322a5dc0847662457f90` on all three webhook configurations at `baseline`, `fault-plus10`, `post-4` **and** `verify` — the configured bundle was never touched. `secret_profileValidator_sha256` goes `0f432af5…` → `13cecb1d…` → back to `0f432af5…`, with the serials following (`D50E3F7E…` → `8EE7F22F…` → `D50E3F7E…`). `secret_proxyInjector_sha256=3d6a0798…` and `secret_policyValidator_sha256=9a07814a…` are unchanged at all four. `credential-plan.txt` reads `ok: 3 observed states walk the declared plan: A/I1/W1 A/I1/W2 A/I1/W1`, with the first and third webhook-state hashes identical (`f34599a9…`).

**How the refused certificate was made, and why that is itself worth recording.** The design expected `openssl` would be needed because `step` "will not emit a deprecated signature algorithm". It did not turn out that way. `lab/lib-webhook.sh`'s `make_webhook_cert_sha1` produces it with `step certificate create … --template <tpl>`, where the template names `"signatureAlgorithm": "SHA1-RSA"` directly. Its comment records what was found: `step certificate create` has no `-signature-algorithm` flag at all, and an undersized RSA key is refused by Go before `step` gets to sign anything — but a template is not a flag, and `step` honours whatever `signatureAlgorithm` a template names, without complaint. So `step`'s flags are not a safeguard against emitting an insecure certificate. That is a fact about the tool, recorded because the design predicted the opposite; it is not one of G1–G4.

## G1 — the API server's error names the algorithm and contains no time-validity language

**Verdict: confirmed, in the one run.**

Twelve response files — two ServiceProfile probes at each of the six fault-phase probe sets (`admission/fault-0011`, `-0060`, `-0065`, `-0093`, `-0124`, `-0153`; `serviceprofile-valid-<tick>.response.txt` and `serviceprofile-invalid-<tick>.response.txt`) — all end `[exit 1]` and all carry the identical text apart from the request path each embeds:

> `Error from server (InternalError): error when creating "runs/41-webhook-algorithm/20260914T235908Z/admission/fault-0011/serviceprofile-valid-fault-plus10.request.yaml": Internal error occurred: failed calling webhook "linkerd-sp-validator.linkerd.io": failed to call webhook: Post "https://linkerd-sp-validator.linkerd.svc:443/?timeout=10s": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "x509: cannot verify signature: insecure algorithm SHA1-RSA" while trying to verify candidate authority certificate "lab-webhook-ca")` `[exit 1]`

- `grep -Ei 'expire|not yet valid|notAfter|notBefore|validity period'` across all twelve returns **nothing**. `grep -L 'insecure algorithm SHA1-RSA'` returns no files: every one names the algorithm.
- The **valid** ServiceProfile probe is what makes this unambiguous. At baseline and at `verify` it reads `serviceprofile.linkerd.io/serviceprofile-valid-<tick> created` `[exit 0]`; during the fault it carries the error above. The failure is the webhook call itself, not a validation verdict.
- The k3s journal carries the same text verbatim from `tls: failed to verify certificate:` to the closing parenthesis, at `dispatcher.go:217]` `Failed calling webhook, failing closed linkerd-sp-validator.linkerd.io`, and adds one thing the client never sees — a named Kubernetes deprecation code, immediately above each one:

  > `I… server_cert_deprecations.go:68] insecure-sha1.invalid-cert.kubernetes.io: invalid certificate detected connecting to "linkerd-sp-validator.linkerd.svc": uses an insecure SHA-1 signature`

  There are **13** of each line, paired one to one: the twelve probe calls plus the one server-side dry-run `swap/settle-fault.txt` made at `00:11:32Z`. The first is at `00:11:32Z` and the last at `00:13:58Z`, 146 s apart. No SHA-1 or `x509` line appears at or after `00:14:00Z`; instead the ordinary `dispatcher.go:225] rejected by webhook "linkerd-sp-validator.linkerd.io"` pattern — the deliberately invalid test object being correctly rejected by a webhook the API server can reach — resumes at `00:14:08Z`, the same second as `swap/settle-restore.txt`.
- **Not settled by this run:** whether a refused certificate would be noticed *without* a reconnect. G's fault necessarily restarts `linkerd-destination` to make the new certificate be served, which forces the API server to open a new connection. The failure was therefore immediate by construction, and this run says nothing about what a refused certificate does on a connection opened before the swap.
- **Scope.** Only the sp-validator's calls failed. Under the same `failurePolicy=Fail`, `inject-probe` was created with three `name: linkerd-proxy` lines at all six fault ticks, and `policy-valid` was created and `policy-invalid` denied with its normal text at all six — so neither the proxy injector nor the policy validator was disturbed, even though the fault restarted `linkerd-destination`, the Deployment `swap/backing.txt` names as backing `linkerd-sp-validator`. (This run does not record which Deployment backs the policy-validator Service, so it cannot say whether that webhook was served from the restarted pod too.)

## G2 — the certificate is time-valid for the whole run

**Verdict: confirmed, at every one of the 27 recorded ticks.**

`timevalidity/` holds **27** files, the same 27 tick names as N's record. `signature_algorithm` is `sha1WithRSAEncryption` at exactly **five** ticks — `fault-plus10`, `post-1`, `post-2`, `post-3`, `post-4` — and `sha256WithRSAEncryption` at the other **22**: `baseline`, `pre-1` … `pre-18`, `fault-minus60`, `fault-minus10`, `verify` (1 + 18 + 2 + 1 = 22; 5 + 22 = 27). All 27 record `openssl_x509_checkend_0_exit=0`.

The five ticks where the refused certificate was installed:

| Tick | `observed_utc` | `notAfter` | `notAfter_epoch` − `observed_epoch` |
| --- | --- | --- | --- |
| `fault-plus10` | `2026-09-15T00:11:36Z` | `Sep 12 00:11:25 2036 GMT` | 2104791085 − 1789431096 = **315 359 989** |
| `post-1` | `2026-09-15T00:12:29Z` | same | 2104791085 − 1789431149 = **315 359 936** |
| `post-2` | `2026-09-15T00:12:58Z` | same | 2104791085 − 1789431178 = **315 359 907** |
| `post-3` | `2026-09-15T00:13:29Z` | same | 2104791085 − 1789431209 = **315 359 876** |
| `post-4` | `2026-09-15T00:13:58Z` | same | 2104791085 − 1789431238 = **315 359 847** |

Each subtraction was done by hand from the two epochs in the file and agrees with that file's own `seconds_until_notAfter`. 315 359 989 s is 3 649 days 23 h 59 m 49 s — a shade under ten years of remaining validity, and the smallest of the five is 142 s less. At the 22 other ticks the original certificate is recorded with between 86 373 s (`baseline`) and 85 609 s (`verify`) remaining.

**Say it precisely.** The certificate installed at each tick was time-valid at every tick, and the refused certificate was time-valid at each of the five ticks where it was installed. It is *not* true, and this note does not claim, that the refused certificate was recorded at all 27 ticks: it did not exist for 22 of them. What matters for the contrast with the expiry runs is the first half — at no point in this run was the webhook serving an expired certificate, so nothing in the failure is attributable to expiry.

## G3 — `linkerd check`'s certificate row for that webhook passes

**Verdict: falsified. The prediction was wrong.** `linkerd check`'s `sp-validator webhook has valid cert` row does not pass while the API server is refusing that certificate. It goes fatal, at the first observation after the swap, and it names the algorithm in its own output.

The design's reasoning was that the check "checks dates and chaining rather than whether the platform will accept the signature". The run shows that is not a separation that exists here. This is the hypothesis the scenario exists to answer, so it gets the detail.

**Before the fault** (`checks/baseline-check.txt`, and byte-identically `checks/verify-check.txt` after the restore):

> `√ sp-validator webhook has valid cert`
> `‼ sp-validator cert is valid for at least 60 days`
> `    certificate will expire on 2026-09-16T00:01:03Z`

(The `‼` is the lab's short certificate lifetimes, not this fault.) The transcript is 85 lines, 11 sections, `Status check results are √`, `[exit 0]`.

**During the fault**, identically at `fault-plus10`, `post-1`, `post-2`, `post-3` and `post-4` — the five transcripts are byte-identical to one another:

> `× sp-validator webhook has valid cert`
> `    cert is not issued by the trust anchor: x509: certificate signed by unknown authority (possibly because of "x509: cannot verify signature: insecure algorithm SHA1-RSA" while trying to verify candidate authority certificate "lab-webhook-ca")`
> `    see https://linkerd.io/2/checks/#l5d-sp-validator-webhook-cert-valid for hints`
>
> `Status check results are ×`
> `[exit 1]`

`linkerd check --proxy` behaves the same: 59 lines, 7 sections, `[exit 1]`, differing from the plain transcript only on line 1.

**What a reader can conclude.** The lab's recurring finding — a signal that looks authoritative going green while something is broken — does **not** extend to this cause. Here `linkerd check` told the truth, immediately, with no reconnect needed and no waiting: it failed the command, and its message named both the mechanism (`certificate signed by unknown authority`) and the actual reason (`insecure algorithm SHA1-RSA`). A reader who runs `linkerd check` against this failure gets a usable answer.

**Why, as far as this evidence goes.** The run's own error text is the evidence: the row failed on the *chaining* test (`cert is not issued by the trust anchor`), and the reason the chaining test failed was the algorithm. The design treated "checks chaining" and "will the platform accept the signature" as different questions; in this run they are the same question, because the verification that answers the first is the one that refuses SHA-1. ***Source-derived, not observed here:*** [`linkerd-source-notes.md`](linkerd-source-notes.md) § 7 records, marked **VERIFIED**, that this fatal row is `CheckCertAndAnchors` (`pkg/healthcheck/healthcheck.go` L1496-1519), which treats the webhook configuration's `caBundle` as the anchors and verifies the Secret's certificate against them for `<svc>.<ns>.svc`. Nothing in this run inspected the CLI's binary or its Go version, so "the CLI and the API server refuse SHA-1 for the same reason" is inference from matching error strings, not something the run established.

**What a reader cannot conclude.**

- Not that `linkerd check` catches every platform-level refusal. This is one algorithm, one Kubernetes and Go version, one webhook, one run. A refusal applied by the API server that ordinary certificate-chain verification does not apply — a policy the platform enforces outside `crypto/x509` chain building — would not necessarily surface in this row at all, and this run does not test that case.
- Not that a green `sp-validator webhook has valid cert` row means the API server will accept the certificate. That direction was never tested here.
- Not that the check being right is the end of the reader's problem: because the row is fatal, it truncates the rest of the output. See the next section.

## G4 — mesh traffic between already-running workloads is unaffected

**Verdict: confirmed, for the whole run — including across two rolling restarts of `linkerd-destination`.**

`probes/final/pods.txt` shows all four probe pods `2/2 Running`, `RESTARTS 0`. Reading every line of the four logs: apart from each file's `$ kubectl … logs` header, its `[exit 0]` footer and the stream probe's single `connect` line, every outcome field is `ok` — `probe-http` 386, `probe-tcp-new` 386, `probe-tcp-new-b` 386, `probe-tcp-stream` 388. `seq=` runs unbroken (1–386 for the first three, 0–388 for the stream). Inside the fault window as the run's own markers bound it — `swap-restart` `00:11:25Z` to `settled … restore: serving` `00:14:08Z` — each of the four logs carries exactly **82** lines, and every one reads `ok`. The four `*-previous.log` files are three lines each, ending `[exit 1]` on `kubectl`'s "previous terminated container … not found" — consistent with `RESTARTS 0`, and the one footer in these records that is not `[exit 0]`.

This is worth one sentence more than the verdict: G restarted `linkerd-destination` twice, and the mesh data path did not notice. The failure was confined to the admission path.

---

# `linkerd check` halts at the first failing section, and that changes what a green row means

Both scenarios show the same behaviour, and it matters more than either verdict.

`linkerd check` stops after the first failing check in a category and does not run the categories after it. The consequence is that **a row's absence is not a pass, and a green row only means the check got that far.**

| Transcript | Lines | Sections | Sections absent | Exit |
| --- | --- | --- | --- | --- |
| Healthy (any of the three runs' baseline and verify ticks) | 85 | 11 | — | 0 |
| N, every fault tick, both runs | 26 | 4 | 7 | 1 |
| G, every fault tick | 59 | 7 | 4 | 1 |

- In **N**, the failure is in `linkerd-existence`, the fourth section. Three further rows in that same section and all seven later sections vanish — including `linkerd-identity` and `linkerd-webhooks-and-apisvc-tls`, the two places a reader would look for a certificate problem. An operator reading this output learns nothing at all about any certificate in the cluster.
- In **G**, the failure is in `linkerd-webhooks-and-apisvc-tls`, the seventh section, and the effect is sharper because it is *inside* the certificate section. The eleven sections of the healthy transcript are `kubernetes-api`, `kubernetes-version`, `gateway-api-crd`, `linkerd-existence`, `linkerd-config`, `linkerd-identity`, `linkerd-webhooks-and-apisvc-tls`, `linkerd-version`, `control-plane-version`, `linkerd-control-plane-proxy`, `linkerd-extension-checks`; the fault transcripts hold the first seven and the last four are absent entirely, not empty and not failing. Within the last section, `× sp-validator webhook has valid cert` is the **last row printed**. The three rows that follow it in the healthy transcript — `sp-validator cert is valid for at least 60 days`, `policy-validator webhook has valid cert`, `policy-validator cert is valid for at least 60 days` — never appear. The policy validator's certificate was never evaluated during the fault, in any transcript, with or without `--proxy`.
- And the row that comes *before* the failure keeps printing green: `√ proxy-injector webhook has valid cert`, with its `‼ … valid for at least 60 days` advisory, appears unchanged in every G fault transcript. It is a true statement about a certificate this fault did not touch — and it sits four lines above a certificate the API server is refusing, in output that then stops.

This is the same masking effect the lab already recorded twice: for `linkerd viz check` in [`lab-evidence-tap-expiry.md`](lab-evidence-tap-expiry.md), where one expired tap certificate blanked the rest of the `linkerd-viz` section, and for `linkerd check` in [`lab-evidence-webhook-expiry.md`](lab-evidence-webhook-expiry.md), where the first expired webhook's fatal row hid the other two webhooks' rows for the rest of the run. **Four experiments now** — tap expiry, webhook expiry, N and G — **four causes, three different sections** (`linkerd-viz`, `linkerd-webhooks-and-apisvc-tls` for both webhook-expiry and G, `linkerd-existence` for N), **one behaviour.** Any advice that tells a reader to "run `linkerd check` and look at the certificate rows" has to tell them that rows they cannot see have not passed.

---

# The three causes side by side

The lab has now produced three causes of a broken Linkerd admission path. This is what each looked like.

| | **Expired** webhook certificate | **Unavailable** webhook (N) | **Refused for its algorithm** (G) |
| --- | --- | --- | --- |
| Component | proxy injector, policy validator, sp-validator | proxy injector | sp-validator |
| Runs | two (one per policy) | two (one per policy) | one |
| Operator-visible symptom, `Ignore` | pods admitted with no proxy; validation silently skipped | pods admitted with no proxy | not run under `Ignore` |
| Operator-visible symptom, `Fail` | matching API calls rejected | matching API calls rejected | matching API calls rejected |
| What the API server said | `tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time … is after 2026-09-12T11:12:12Z` | `no endpoints available for service "linkerd-proxy-injector"` | `tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "x509: cannot verify signature: insecure algorithm SHA1-RSA" …)` |
| What `linkerd check` said | `× proxy-injector webhook has valid cert` / `certificate is not valid anymore. Expired on …` | `× control plane pods are ready` / `No running pods for "linkerd-proxy-injector"`; certificate section never reached | `× sp-validator webhook has valid cert` / `cert is not issued by the trust anchor: x509: … insecure algorithm SHA1-RSA` |
| Did the webhook's pods exist and run? | yes | **no** | yes |
| Was the certificate time-valid? | **no** | yes, 23 h 47 m 10 s left at NI's last fault tick | yes, just under 3 650 days left at every tick it was installed |
| Needed the API server to reconnect before the failure showed? | **yes** for proxy-injector and sp-validator (≈ 30 min and ≈ 10 min of working on a reused connection); no for policy-validator | no — there is no endpoint to keep a connection to | not answerable: the fault itself restarts the webhook's pod |
| Mesh traffic between running workloads | unaffected | unaffected | unaffected |

Quotations in the expiry column are from `demos/cert-hygiene/runs/02-webhook-expiry-fail/20260912T105527Z/admission/reconnect-0000/inject-probe-reconnect-0.response.txt` and `demos/cert-hygiene/runs/02-webhook-expiry-ignore/20260912T095814Z/checks/fault-plus10-check.txt`; the reconnect timings are the subject of [`lab-evidence-webhook-expiry.md`](lab-evidence-webhook-expiry.md) and are not re-derived here. Both W runs are `evidence_valid=yes` at `harness_tree_sha256=e86c787ea2317ecdbc45e607681b83bba0f9e94b48f7f87aed3d95f0d274e7c8` — a different harness tree from N's and G's, so every comparison in this table crosses trees.

**Where two causes are genuinely indistinguishable, and where they are not.**

- **Indistinguishable from the admitted object alone: expired and unavailable, under `Ignore`.** The pod a reader finds is the same object; see N2. If the triage table's entry point is "pods are coming up without proxies", the table must send the reader somewhere else to decide which cause it is.
- **Indistinguishable from the exit code alone: all three, under `Fail`.** Every rejected create is `[exit 1]`, and every one opens `Error from server (InternalError): error when creating "…": Internal error occurred: failed calling webhook "<name>": failed to call webhook: Post "https://<svc>:443/?timeout=10s":`. That prefix is identical across all three causes up to the webhook's own name and Service — and those vary here because N and W tested the proxy injector while G tested the sp-validator, not because the cause differs. The cause appears only in the clause after that final colon.
- **Distinguishable by the API server's message, in all three.** `no endpoints available for service` is not a certificate problem. `x509: certificate has expired or is not yet valid` names a date. `x509: cannot verify signature: insecure algorithm SHA1-RSA` names an algorithm. A reader who reads to the end of the error has their answer, and this is the single most reliable discriminator the lab has produced.
- **Distinguishable by `linkerd check`, in all three — but only if the reader knows how to read a truncated transcript.** N stops in `linkerd-existence` with a readiness failure and says nothing about certificates. Expiry and G both go fatal on a `webhook has valid cert` row, and their messages differ (`certificate is not valid anymore. Expired on …` versus `cert is not issued by the trust anchor: … insecure algorithm SHA1-RSA`). But in all three cases the output ends at the failure, so "the certificate rows looked fine" is only ever a claim about rows that actually printed.
- **Not distinguishable by the mesh data path, in any of the three.** All four probes stayed `ok` throughout all three runs in this note (N5, G4), and [`lab-evidence-webhook-expiry.md`](lab-evidence-webhook-expiry.md) reports the same for both webhook-expiry runs. "Is traffic still flowing?" is a useless triage question for this whole family of faults, and answering it "yes" must not be read as "nothing is wrong".

---

# What this means for the article

- **The triage table now has a tested negative control, and it changes what the table can promise.** An unavailable webhook and an expired webhook certificate produce the same admitted object under `Ignore` — not similar, the same, to within an object name and six timestamps. A table row keyed on the symptom "pods have no proxy" cannot resolve to a cause on its own. What resolves it, in this lab, is the API server's error text and whether the webhook's Deployment has running pods.
- **One prediction was wrong and it is the useful kind of wrong.** G3 predicted that `linkerd check` would call a refused certificate valid — the strongest possible form of "the check is not measuring what you think". It does not. The row goes fatal at the first observation and names the algorithm. The article should not carry a general claim that `linkerd check` is blind to certificate problems the platform sees; the lab's own evidence contradicts it for this cause. The narrower claims the lab *has* earned stand unchanged — the ones recorded in [`lab-evidence-issuer-expiry-rerun.md`](lab-evidence-issuer-expiry-rerun.md), [`lab-evidence-check-threshold.md`](lab-evidence-check-threshold.md) and [`lab-evidence-tap-expiry.md`](lab-evidence-tap-expiry.md), each about a different row and a different cause, with their own figures. Nothing here narrows or widens them; G3 simply does not join them.
- **The second prediction that bent is N4, and it bent in a way that matters more than the verdict.** `linkerd check` did report N's fault as a readiness failure, as predicted. But "no certificate row goes fatal" turned out to be true only because seven of eleven sections never ran. A reader-facing page must say that `linkerd check` halts at the first failing section, in plain words, wherever it advises running the check — the effect is now recorded in four separate experiments (tap expiry, webhook expiry, N and G), on three different sections.
- **`failurePolicy=Fail` did not deadlock the cluster, and the article should say why carefully.** NF recovered in 4 s because the injector's own replacement pod was admitted while the injector had no endpoints. The run proves that happened and cannot prove why; the explanation from Linkerd's chart — the proxy-injector webhook's `objectSelector` excludes objects labelled `linkerd.io/control-plane-component` — is source-derived and is labelled as such above. Anyone writing "`Fail` is safe because Linkerd exempts its own pods" is making a claim this lab has not tested on a live cluster.
- **Both credential caveats travel with every claim here.** These are lab-supplied static webhook serving certificates with 24-hour lifetimes, as every W run's were. What Linkerd does by default is not something this lab has tested; the source notes record it as self-generated 365-day certificates re-issued on every render, and that record is source-derived, labelled as such at the top of this page. And G's refused certificate was produced by asking `step` for an algorithm its own flags cannot request, through a template — which is a finding about the tool, and also a reminder that this certificate is not one any normal pipeline would emit.
- **Repetition still owed.** N ran twice, once per policy; G ran once. Nothing here about G — the error text, the fatal check row, the ten years of remaining validity — has been reproduced a second time. G also cannot say whether a refused certificate would be noticed on a connection opened before the swap, because its fault restarts the webhook's pod. And no run in this note tested a refused certificate on the proxy injector, deliberately: the blast radius under `Fail` was judged too large for a recoverable run.
