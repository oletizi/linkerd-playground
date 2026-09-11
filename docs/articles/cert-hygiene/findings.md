# What we found: Linkerd certificate expiry

This page sums up what we learned in two ways: by reading Linkerd's source code and documentation, and by letting Linkerd's identity issuer expire on purpose in a throwaway test cluster and recording what happened. It follows the order of the article outline, so you can lift findings section by section.

Every finding says how sure we are:

- **Seen in the lab** — we made it happen and recorded it.
- **From Linkerd's source** — read in Linkerd's code or docs, not yet tested in the lab.
- **Still open** — we don't know yet.

**Scope, before you generalise anything.** The lab result comes from one experiment on Linkerd `edge-26.9.1` (released 2026-09-04), on a single-node test cluster. To make expiry happen in minutes instead of days, we shortened the lifetimes: the issuer lived 15 minutes and workload certificates 5 minutes (Linkerd's default for workload certificates is 24 hours). A matching run with long-lived certificates, where nothing expired, showed no failures at all, so the failures below come from the expiry and not from the test setup. Where a timing below says "seconds" or "minutes", expect the same shape stretched over hours with default settings.

---

## The short version

1. **When the identity issuer expires, every workload certificate in the mesh expires at the same moment.** Linkerd caps each workload certificate at the issuer's own expiry, so there's no gradual spread. *Seen in the lab.*
2. **New connections break first; connections that are already open keep working.** New pods, and restarted copies of existing ones, never become ready. The mesh looks half-broken: some calls succeed, some fail, and nothing new rolls out. *Seen in the lab.*
3. **Replacing the issuer isn't enough on its own.** Linkerd picked up the new issuer by itself within about 30 seconds, but workloads whose certificates had already expired stayed broken until they were restarted. Linkerd's own procedure says to restart every meshed workload after replacing the issuer. Do that. *Seen in the lab.*
4. **`linkerd check` catches an expired issuer, but it can't tell you that recovery finished.** It reported everything healthy while workloads were still running on expired certificates. *Seen in the lab.*
5. **Linkerd's admission webhooks fail open by default.** An expired webhook certificate doesn't make `kubectl` reject anything; injection or validation is silently skipped. *From Linkerd's source.*
6. **An expired trust anchor fails late.** Traffic keeps flowing until each workload's current certificate runs out. *From Linkerd's source.*

---

## Triage table

This is the article's triage table, updated with what we found. Each row links to the details below.

| What you're seeing | What to suspect | Why | How sure | Details |
| --- | --- | --- | --- | --- |
| Some calls work and some fail. New connections fail, often as a plain "connection reset", while connections that were already open keep working. | Identity issuer expired | Every workload certificate is capped at the issuer's expiry, so they all expire at once, and nothing can renew. | Seen in the lab | [Issuer expired](#issuer-expired-traffic-partly-broken) |
| A deployment won't finish rolling out. New pods sit in `Init` with `linkerd-proxy` failing its startup probe, while the old pods keep serving. | Identity issuer expired | The new pod's proxy can't get a certificate, so it never becomes ready. | Seen in the lab | [Stuck rollout](#rollout-stuck-while-old-pods-keep-serving) |
| New pods come up healthy, with no errors, but have no `linkerd-proxy` container. | Proxy-injector webhook certificate expired | The webhook fails open, so pods are admitted without being injected. | From Linkerd's source | [Unmeshed pods](#new-pods-run-without-a-proxy) |
| Traffic was fine, then starts failing later, although nothing was changed. The identity service is refusing to issue certificates. | Trust anchor expired | Proxies don't check the anchor's own date, but the identity service does. Failures appear only as each workload's current certificate runs out. | From Linkerd's source | [Trust anchor expired](#trust-anchor-expired) |
| One proxy is still on an expired certificate. | The issuer was replaced but this workload wasn't restarted; or the identity service was unreachable for longer than the certificate had left | Proxies whose certificates had already expired didn't renew on their own after the issuer was replaced. | Seen in the lab (first cause); from Linkerd's source (second) | [One expired proxy](#one-proxy-has-an-expired-certificate) |
| `linkerd check` passes, but traffic is still failing after an issuer fix. | Workloads not yet restarted, still on expired certificates | `linkerd check` doesn't look at workload certificates. | Seen in the lab | [check passes, traffic fails](#linkerd-check-passes-but-traffic-still-fails) |
| Linkerd policy or ServiceProfile resources apply without complaint but aren't validated. Only with a `Fail` policy: `kubectl apply` rejected with an x509 error. | Policy-validator (or ServiceProfile-validator) webhook certificate expired | The webhooks fail open by default, so validation is skipped rather than enforced. | From Linkerd's source | [Validator webhooks](#policy-validator-webhook-certificate-expired) |
| `linkerd viz tap` and other viz features stop working. | Viz tap certificate expired, or the Kubernetes API server's CA was rotated | Tap is served through a Kubernetes aggregated API with its own certificate. | From Linkerd's source | [Tap and viz](#tap-and-other-viz-features-stopped-working) |

The draft had one ambiguous row: "a deployment fails to roll out while existing workloads keep running" could be either an expired issuer or an expired proxy-injector certificate. With Linkerd's default settings, the two look different. The issuer case leaves pods stuck with a proxy that can't start; the injector case produces running pods with no proxy at all. That's why they are separate rows above.

---

## The rows in detail

### Issuer expired: traffic partly broken

- **Your draft's row:** "Mesh traffic becomes increasingly unreliable; restarted/new workloads are especially affected" → identity issuer expired, because "existing short-lived leaf certs keep working until they can't be renewed, so failure spreads gradually".
- **What we found:** the cause is right, but "gradually" is wrong for current Linkerd. *Seen in the lab:*
  - Every workload certificate, including the control plane's own, had the same expiry time as the issuer. All of them expired in the same second.
  - New connections started failing within 2 seconds of the expiry. The application saw `Connection reset by peer`, not a TLS or certificate error.
  - A TCP connection that was already open kept working for the roughly 10 minutes we recorded after the expiry.
  - An HTTP client kept working over the same roughly 10 minutes. The likely reason is that its requests kept reusing a connection opened before the expiry; that explanation is *from Linkerd's source*, not something we recorded.
  - Pods that started after the expiry never became ready (see [Rollout stuck](#rollout-stuck-while-old-pods-keep-serving)).
- **Suggested wording:** "Once the issuer expires, Linkerd can't sign new workload certificates. Current Linkerd also caps every workload certificate at the issuer's expiry, so they all expire at the same moment. New connections start failing immediately, often as a plain 'connection reset' rather than a certificate error, while connections that were already open can keep working. That's why the mesh looks partly broken rather than down, and why anything that restarts gets worse."
- To confirm it, see [Diagnosis](#diagnosis-how-to-tell-its-the-issuer). To fix it, see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid).

[Back to the triage table](#triage-table)

### Rollout stuck while old pods keep serving

- **Your draft's row:** "A deployment fails to roll out while existing workloads keep running" → ambiguous: issuer expired, or proxy-injector certificate expired.
- **What we found:** with default settings this symptom points to the issuer. *Seen in the lab:*
  - The new pod has a `linkerd-proxy` container, but it never starts.
  - The pod sits in `Init`, and its events show the `linkerd-proxy` startup probe failing (HTTP 503).
  - Kubernetes keeps killing and restarting the proxy (three times in about 8 minutes in our run).
  - The old pod keeps serving, and the rollout waits.
  - An expired proxy-injector certificate looks different: see [New pods run without a proxy](#new-pods-run-without-a-proxy).
- **The discriminator:**
  - If the stuck pod has a `linkerd-proxy` that fails to start, suspect the issuer.
  - If the new pod is running but has no `linkerd-proxy` container, suspect the proxy-injector's webhook certificate.
- **Also worth saying:** the old pod stayed "Ready" in Kubernetes the whole time, even though its own certificate had expired. Pod readiness tells you nothing about certificate health. *Seen in the lab.*

[Back to the triage table](#triage-table)

### New pods run without a proxy

- **Your draft's row:** "New pods come up healthy but unmeshed, with no error anywhere" → proxy-injector webhook certificate expired.
- **What we found:** *From Linkerd's source:* confirmed as the default behaviour. The proxy-injector webhook fails open, so pods are admitted without a proxy and nothing reports an error.
- `linkerd check` does flag it, under "proxy-injector webhook has valid cert", but only when someone runs it.

[Back to the triage table](#triage-table)

### Trust anchor expired

- **Your draft's row:** "Otherwise healthy workloads suddenly can't establish trusted mTLS communication" → trust anchor expired, because every workload certificate chains to it.
- **What we found:** *From Linkerd's source, not yet tested; the delay is an inference from how the code checks certificates:* the failure is delayed.
  - Linkerd's proxies don't check the trust anchor's own expiry date.
  - The identity service does check it, and it stops issuing certificates immediately.
  - So nothing visible happens when the anchor expires. Connections start failing later, as each workload's current certificate runs out and can't be renewed. With default settings that can be up to a day later.
- **Suggested wording:** "An expired trust anchor doesn't break traffic the moment it expires. Linkerd's identity service stops issuing certificates right away, and connections fail as each workload's current certificate runs out, up to a day later with default settings. The delay makes the cause easy to miss."

[Back to the triage table](#triage-table)

### One proxy has an expired certificate

- **Your draft's row:** "An individual proxy has an expired identity certificate" → workload identity renewal failed for that proxy.
- **What we found:** add a common cause. *Seen in the lab:*
  - After the expired issuer was replaced, proxies whose certificates had already expired did not get new ones on their own. They were still on their expired certificates about 10 minutes later, when we restarted them.
  - So a proxy with an expired certificate right after an issuer fix usually means "not restarted yet".
- *From Linkerd's source:* a proxy also can't renew if the identity service is down for longer than its certificate has left to live. See [linkerd2 #13136](https://github.com/linkerd/linkerd2/issues/13136).
- **Suggested addition:** "If you've just replaced the issuer, a proxy still holding an expired certificate probably hasn't been restarted. Restart its workload before you go looking for anything else."

[Back to the triage table](#triage-table)

### `linkerd check` passes but traffic still fails

- **Not in your draft; a new row.**
- **What we found:** *Seen in the lab:* after the issuer was replaced, `linkerd check` and `linkerd check --proxy` reported everything healthy (`Status check results are √`) at every point we sampled, while four proxies were still running on expired certificates and new connections through them were failing.
- *From Linkerd's source:* `linkerd check` doesn't look at workload certificates. Under `--proxy`, the check "data plane proxies certificate match CA" only compares each pod's copy of the trust anchor with the cluster's.
- **What to do:** restart the workloads (see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid)), and confirm with the proxies' own certificate metric (see [Best practices](#best-practices-prevention-and-monitoring)).

[Back to the triage table](#triage-table)

### Policy-validator webhook certificate expired

- **Your draft's row:** "`kubectl apply` of a Server/AuthorizationPolicy/etc. is rejected with an x509/webhook error" → policy-validator webhook certificate expired, because "a Fail policy turns an expired cert into a hard admission rejection".
- **What we found:** *From Linkerd's source, not yet tested:* by default there is no rejection.
  - Every Linkerd admission webhook ships with `failurePolicy: Ignore`. The control plane's webhooks take it from the Helm value `webhookFailurePolicy`; the viz tap-injector has its own setting.
  - With the default, an expired policy-validator certificate means the `kubectl apply` succeeds and the policy is never validated. The ServiceProfile validator behaves the same way.
  - You only get the rejection the draft describes if an operator has changed the policy to `Fail`.
- **Suggested wording:** "By default, Linkerd's webhooks fail open. An expired policy-validator certificate doesn't reject your policy; it lets unvalidated policy through without a word. You'd only see an x509 rejection if your installation sets the webhook failure policy to Fail."

[Back to the triage table](#triage-table)

### Tap and other viz features stopped working

- **Your draft's row:** "Tap (and other linkerd viz features) stopped working" → linkerd-viz / tap certificate expired.
- **What we found:** *From Linkerd's source, not yet tested:*
  - Tap is served through a Kubernetes aggregated API with its own serving certificate. When that certificate expires, the API goes unavailable.
  - `linkerd viz check` checks the tap API server's certificate. Nothing checks the tap-injector's certificate.
  - A related real-world report: after the Kubernetes API server's CA rotated, tap stopped working until its pod was restarted ([linkerd2 #13196](https://github.com/linkerd/linkerd2/issues/13196)).

[Back to the triage table](#triage-table)

---

## Diagnosis: how to tell it's the issuer

These are the signals, in roughly the order an operator runs into them. All of them were *seen in the lab* unless marked otherwise. They apply to the first two [triage rows](#triage-table).

- **Application errors:** new connections fail with `Connection reset by peer`. The message doesn't mention certificates.
- **`linkerd check`:**
  - Before expiry: `‼ issuer cert is valid for at least 60 days`, with the exact expiry time in the detail line.
  - Afterwards: `× issuer cert is within its validity period`, with `issuer certificate is not valid anymore. Expired on <time>`.
- **Identity service log:** `could not process CSR because of CA cert validation failure: x509: certificate has expired or is not yet valid`.
- **Kubernetes events** on `deployment/linkerd-identity`: `IssuerValidationFailed`. Kubernetes folds repeats into one event with a count, so look at the count, not the number of lines.
- **Metric:** the identity service's `issuer_cert_ttl_seconds` goes negative.
- **New pods:** stuck in `Init`, with the `linkerd-proxy` startup probe failing (see [Rollout stuck](#rollout-stuck-while-old-pods-keep-serving)).
- **Don't be misled:**
  - The identity pod itself stays Running and Ready throughout.
  - The identity log only showed rejections for the identity service's own sidecar. The other proxies' renewal attempts never showed up there, so "no errors about my workload in the identity log" doesn't mean the workload is fine. *Why* their attempts never arrived is *still open*.

---

## Fixing it: replacing an expired issuer while the trust anchor is still valid

**What we did:** we followed Linkerd's documented procedure.

1. Sign a new issuer certificate from the existing trust anchor.
2. Apply it with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… | kubectl apply -f -`. There's no trust-anchor flag, and the trust anchor stays untouched.

Linkerd's "Replacing expired certificates" page sends you to the [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/) for this case. That guide also says to restart the proxies of all injected workloads afterwards.

**What happened.** *Seen in the lab:*

- The identity service picked up the new issuer by itself about 30 seconds after we applied it, without being restarted. You'll see an `IssuerUpdated` event.
- `linkerd upgrade` also restarted the destination and proxy-injector pods. It did not restart the identity service.
- Pods that had never received a certificate, the stuck new ones, became ready by themselves within a minute or so.
- Pods whose certificates had already expired did not recover. They were still broken about 10 minutes later (see [One proxy has an expired certificate](#one-proxy-has-an-expired-certificate)).
  - Restarting just the stuck new pods didn't help.
  - Restarting every meshed deployment fixed everything within about a minute. New connections worked again within seconds of the restart.
- During all of this, `linkerd check` reported everything healthy (see [`linkerd check` passes but traffic still fails](#linkerd-check-passes-but-traffic-still-fails)).

**Suggested advice:** "After you replace the issuer, restart every meshed workload, as Linkerd's guide says; for example, `kubectl rollout restart deploy -n <namespace>` for each meshed namespace. Don't wait for proxies to recover on their own. In testing, they didn't. Then confirm the fix by checking that proxies hold new certificates (see [Best practices](#best-practices-prevention-and-monitoring)), not just that `linkerd check` passes."

**Caveats:**

- We restarted everything at once, so we can't say which restarts were strictly necessary.
- Whether stuck proxies would eventually recover on their own is *still open*.
- The advice above follows Linkerd's documentation, so it holds either way.

---

## Best practices: prevention and monitoring

- **Watch the issuer directly.** The identity service exposes `issuer_cert_ttl_seconds`, a live countdown of the issuer's remaining life that goes negative once it expires. *Seen in the lab.*
- **Watch workload certificates too.** Each proxy exposes `control_identity_cert_expiration_timestamp_seconds`, its certificate's expiry time. After any rotation, check that this value moved on every proxy. *Seen in the lab:* `linkerd check` passed while it hadn't moved on four proxies (see [`linkerd check` passes but traffic still fails](#linkerd-check-passes-but-traffic-still-fails)).
- **Don't rely on the `linkerd check` warning headline.** It warns at 60 days, a fixed threshold per Linkerd's source. The headline read exactly the same with 15 minutes left as it would with 59 days left. Only the date in the detail line differs. Alert on the date or the metric instead.
  - *Seen in the lab:* the headline stayed unchanged until the issuer expired.
  - *From Linkerd's source:* the 60-day threshold and what it prints at 59 days. We didn't run a 59-day case.
- **Treat webhook certificates as first-class.** Because Linkerd's webhooks fail open by default, an expired webhook certificate is silent (see [New pods run without a proxy](#new-pods-run-without-a-proxy) and [Policy-validator webhook certificate expired](#policy-validator-webhook-certificate-expired)). `linkerd check` warns about the proxy-injector, ServiceProfile-validator and policy-validator certificates at 60 days, but nothing checks the viz tap-injector's certificate. *From Linkerd's source.*
- **Workload certificate lifetime is your tolerance for an identity-service outage.** Proxies renew at 70% of a certificate's remaining life, never more often than every 10 seconds. If the identity service is down longer than a certificate has left, that proxy's certificate expires. *From Linkerd's source.*
  - *Seen in the lab:* renewals got closer and closer together as the issuer's expiry approached, down to the 10-second floor.
- **Trust-anchor rotation needs restarts.** Each proxy reads the trust anchor once, when its pod starts, so a new anchor only takes effect as pods restart. *From Linkerd's source.* That's why Linkerd's staged rotation (old + new anchor, then new issuer, then remove the old anchor) involves restarting workloads. See also [Trust anchor expired](#trust-anchor-expired).

---

## Claims in the draft to handle carefully

These come from [sources.md](sources.md), which has the full reasoning:

- "Hard trust-anchor replacement is the most common self-inflicted outage": no source supports the "most common" part. Say instead: "A one-step root replacement can break validation mesh-wide."
- The 90/60/30/7-day escalation windows are an editorial policy, not a Linkerd recommendation. Linkerd itself warns at 60 days.
- "Losing the trust-anchor key isn't immediately an outage": true, but say it means you can no longer sign a new issuer under that root, so plan a migration.
- "A single-proxy renewal failure usually isn't a certificate problem" is a useful rule of thumb, not an established fact. Present it as such.

---

## Still open

- Why proxies with expired certificates didn't renew after the issuer was replaced, and whether they would have recovered eventually.
- Which side rejects the connection when both proxies' certificates have expired.
- How long already-open connections keep working. We recorded about 10 minutes.
- How any of this plays out with the default 24-hour workload certificates.
- The trust-anchor, webhook and viz scenarios haven't been run in the lab yet. Their [triage rows](#triage-table) rest on Linkerd's source only.

A repeat of the issuer experiment, with fuller logging, is pending. It should answer the first two questions.

---

## Where the details are

- [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) — the full lab record, quoting the raw logs, metrics and `linkerd check` output behind every "seen in the lab" statement above.
- [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md) — the source reading behind every "from Linkerd's source" statement, with links to the exact lines of code.
- [sources.md](sources.md) — what to cite for each claim.
