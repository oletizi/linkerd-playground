# What we found: Linkerd certificate expiry

This page sums up what we know about Linkerd certificate expiry, from two kinds of work: a series of experiments in a throwaway test cluster, in which we made certificates expire on purpose and recorded what happened, and reading Linkerd's source code and documentation. It follows the order of the article outline.

Every statement says where it comes from:

- **Seen in the lab** — we made it happen and recorded it.
- **From Linkerd's code, not yet tested** — read in Linkerd's source or documentation, or in Kubernetes' documentation; we have not reproduced it. Where a conclusion is our own reasoning from the code rather than something the code states, it is marked **our inference**.
- **Still open** — we don't know yet.

**Scope, before you generalise anything.** This page now rests on several experiments, including a repeat of the issuer experiment, all on Linkerd `edge-26.9.1` (released 2026-09-04) on a single-node test cluster. To make expiry happen in minutes instead of days, we shortened the lifetimes in each one:

- **Identity issuer expiry**, run twice: a 15-minute issuer, 5-minute workload certificates, a 30-day trust anchor.
- **Webhook serving certificates**, run twice, once for each of the two failure policies: three webhook certificates expiring 10 minutes apart (15, 25 and 35 minutes), with a long-lived anchor and issuer that never expired.
- **An identity-service outage**: the identity service taken down for 15 minutes, with 5-minute workload certificates and a long-lived anchor and issuer.
- **The `linkerd check` warning threshold**: two issuers, one 10 minutes short of 60 days and one 10 minutes past it.
- **Trust-anchor expiry**: a 20-minute anchor, a 2-hour issuer that outlived it, and 5-minute workload certificates.
- **Trust-anchor rotation**, run twice: once by Linkerd's staged procedure and once as a one-step replacement, both with long-lived anchors and issuers and 5-minute workload certificates.

Linkerd's default for workload certificates is 24 hours. Each experiment is compared against a run of the same steps on long-lived certificates, where nothing expired and nothing failed, so the failures below come from the expiry and not from the test setup or from the restarts themselves. Where a timing below says "seconds" or "minutes", expect the same shape stretched over hours with default settings. One or two runs of a thing is one or two runs: these are the behaviours we recorded, not laws.

---

## The short version

### What we reproduced

1. **When the identity issuer expires, every workload certificate in the mesh expires at the same moment.** Linkerd caps each workload certificate at the issuer's own expiry, so there's no gradual spread.
2. **Some traffic broke at once, and some kept working.** A client opening a fresh connection for every request failed within seconds. An HTTP client, and one TCP connection that was already open, kept working for about 37 minutes, until the pod at the other end of that connection was restarted. New pods, and restarted copies of existing ones, never became ready.
3. **Replacing the issuer isn't enough on its own.** Linkerd picked up the new issuer by itself within 20 to 30 seconds, but workloads whose certificates had already expired stayed broken until they were restarted — and a connection only worked once *both* ends had been restarted.
4. **`linkerd check` catches an expired issuer, but it can't tell you that recovery finished.** It reported everything healthy while workloads were still running on expired certificates and every fresh connection between them was failing.
5. **An expired webhook certificate can stay silent for a long time, and then bite all at once.** In our lab two of the three webhooks kept working for tens of minutes past their own expiry, on connections the API server had already opened; they failed only once their pods were restarted and the API server had to reconnect.
6. **If the identity service is unreachable for longer than a workload certificate has left, that workload's traffic fails** — and the proxy does not recover by itself when the service comes back. Only a restart got it a new certificate.
7. **An expired trust anchor is silent until each proxy's current certificate runs out.** In our lab that was about four minutes after the anchor expired, and every proxy failed at almost the same moment rather than one by one.
8. **Rotating a trust anchor in Linkerd's staged way caused no failed connections; replacing it in one step broke the mesh.** After a one-step replacement, proxies that hadn't been restarted could no longer reach the identity service at all, kept their existing certificates until those expired, and then failed.
9. **`linkerd check`'s 60-day issuer warning is not a precise 60-day line.** It fired for an issuer with 15 minutes left, for one about 10 minutes short of 60 days, and also for one with about nine minutes *more* than 60 days of life left.

### What Linkerd's code says, not yet tested

10. **`linkerd viz tap` is served through a Kubernetes aggregated API with its own certificate,** and nothing checks the viz tap-injector's certificate. Our inference: when the tap API's certificate expires, that API goes unavailable and tap stops working. We have not run this experiment.

---

## Triage table

Two tables: what we reproduced, and what Linkerd's code predicts but we haven't tested. Each row links to its details.

### Reproduced in the lab

| What you're seeing | What to suspect | Why | Details |
| --- | --- | --- | --- |
| Some calls work and some fail. Fresh connections fail, often as a plain "connection reset", while an already-open connection and an HTTP client keep working. | Identity issuer expired | Every workload certificate is capped at the issuer's expiry, so they all expire at once, and nothing can renew. | [Traffic partly broken](#issuer-expired-traffic-partly-broken) |
| A deployment won't finish rolling out. New pods sit in `Init` with `linkerd-proxy` failing its startup probe, while the old pods keep serving. | Identity issuer expired | The new pod's proxy can't get a certificate, so it never becomes ready. | [Rollout stuck](#issuer-expired-rollout-stuck-while-old-pods-keep-serving) |
| After the issuer was replaced, a proxy is still on an expired certificate, and calls to it still fail even though the caller was restarted. | Proxies that expired before the fix don't renew by themselves; restart both workloads | In our lab, such proxies never renewed while we watched, and a connection worked again only once the pods at both ends had been restarted. | [Proxy still expired](#a-proxy-is-still-on-an-expired-certificate-after-an-issuer-fix) |
| After an issuer fix, `linkerd check` passes but traffic is still failing. | Workloads not yet restarted, still on expired certificates | In both of our runs `linkerd check` reported healthy while proxies still held expired certificates and every fresh connection failed. | [check passes, traffic fails](#linkerd-check-passes-but-traffic-still-fails) |
| New pods run normally, with no errors, but have no `linkerd-proxy` container — or, on a cluster configured to fail closed, `kubectl` refuses to create pods with an x509 "certificate has expired" error. | Proxy-injector webhook certificate expired | The webhook is configured to fail open by default, so pods are admitted without being injected. In our lab this only began once the API server had to open a new connection to the webhook. | [Pods without a proxy](#new-pods-run-without-a-proxy) |
| Linkerd policy or ServiceProfile resources apply without complaint but aren't validated — or, on a cluster configured to fail closed, are refused with an x509 error. | Policy-validator or ServiceProfile-validator webhook certificate expired | Same fail-open default. In our lab the policy validator started failing at its own expiry, while the ServiceProfile validator kept validating until the API server had to reconnect. | [Validation skipped](#policy-and-serviceprofile-resources-arent-validated) |
| The identity service has been down for a while, and meshed traffic starts failing — first as connection resets, and new pods never become ready. | Proxies' certificates ran out while they couldn't renew | A proxy that can't reach the identity service keeps its current certificate until it expires, and does not renew by itself afterwards. | [Identity outage](#a-proxy-cant-renew-during-an-identity-service-outage) |
| Traffic was fine, then starts failing a few minutes later although nothing changed. The identity service is up but refuses every certificate request, and new pods never become ready. | Trust anchor expired | Proxies don't check the anchor's own date; the identity service does. Failures appear when each proxy's current certificate runs out. | [Trust anchor](#trust-anchor-expired) |

### Expected from Linkerd's code, not yet tested

| What you'd see | What to suspect | Why (from the code) | Details |
| --- | --- | --- | --- |
| `linkerd viz tap` and other viz features stop working. | Viz tap API certificate expired | Tap is served through a Kubernetes aggregated API with its own certificate. What an expired one does is our inference. | [Tap and viz](#tap-and-other-viz-features-stopped-working) |

---

## Details: reproduced in the lab

### Issuer expired: traffic partly broken

- Every workload certificate, including the control plane's own, had the same expiry time as the issuer. All of them expired in the same second.
- A client that opens a fresh connection for every request started failing within 2 seconds of the expiry. The application saw `Connection reset by peer`, not a TLS or certificate error.
- One TCP connection that was already open kept working for about 37 minutes past the expiry, in both runs, and then ended — not from any certificate failure, but because we restarted the pod at the other end of it. Our comparison run, where nothing expired, lost its own long-lived connection at the same point for the same reason. How long such a connection lasts if nothing restarts is *still open*.
- An HTTP client that starts a fresh request for every call also kept working over that whole window, with every one of its thousand-odd attempts succeeding in each run. *From Linkerd's code:* the likely explanation is that the two proxies kept reusing a connection opened before the expiry. In our lab the proxies' connection counter to that destination never moved, which is what that explanation predicts, but we did not observe the reuse itself.
- So "new connections fail first" is too broad. What failed in our lab was a fresh connection through the mesh, whenever either end held an expired certificate.
- The failure happened at the TLS handshake, not at certificate validation inside the workload: in every pre-existing workload's own proxy log, the workload's proxy recorded receiving a fatal `CertificateExpired` alert from the identity service's endpoint. That is a proxy failing to reach *the identity service*, which is a different thing from two workload proxies failing to reach *each other*; our runs measured the first directly, and saw the second only as failed connections.
- Pods that started after the expiry never became ready (see [Rollout stuck](#issuer-expired-rollout-stuck-while-old-pods-keep-serving)).
- **Suggested wording:** "Once the issuer expires, Linkerd can't sign new workload certificates. In current Linkerd, every workload certificate is also capped at the issuer's expiry, so they all expire at the same moment. In our testing, some traffic failed immediately, often as a plain 'connection reset' rather than a certificate error, while other traffic, including a connection that was already open, kept working for more than half an hour. That's why the mesh looks partly broken rather than down, and why anything that restarts gets worse."
- To confirm it, see [Diagnosis](#diagnosis-how-to-tell-its-the-issuer). To fix it, see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid). The full record is in [notes/lab-evidence-issuer-expiry-rerun.md](notes/lab-evidence-issuer-expiry-rerun.md).

[Back to the triage table](#triage-table)

### Issuer expired: rollout stuck while old pods keep serving

- The new pod has a `linkerd-proxy` container, but it never starts.
- The pod sits in `Init`, and its events show the `linkerd-proxy` startup probe failing (HTTP 503).
- Kubernetes keeps killing and restarting the proxy (three times in about 8 minutes in our first run).
- The old pod keeps serving, and the rollout waits.
- The old pod stayed "Ready" in Kubernetes the whole time, even though its own certificate had expired. Pod readiness tells you nothing about certificate health.
- New pods that are running but have no `linkerd-proxy` container at all are a different problem; see [New pods run without a proxy](#new-pods-run-without-a-proxy).

[Back to the triage table](#triage-table)

### A proxy is still on an expired certificate after an issuer fix

- After the expired issuer was replaced, proxies whose certificates had already expired did not get new ones on their own, in either run. They kept failing the same handshake to the identity service for as long as we left them alone, because each still had to present its own expired certificate to ask for a new one.
- Proxies that had never had a certificate (the stuck new pods) did get one, within about a minute.
- **Which restarts were needed, measured directly.** In both runs we restarted one end at a time and sampled fresh connections after each step. With neither end restarted, all ten attempts failed. With only the client restarted, all ten still failed. Only once the pod at the *other* end had also been restarted did connections succeed, ten out of ten — and a second client that had not yet been restarted still failed against that same restarted server. In our lab, a connection worked again only when both of its ends held fresh certificates.
- **Suggested wording:** "If you've just replaced the issuer and a proxy is still on an expired certificate, restart its workload — and remember that restarting only one side of a call isn't enough. In our testing, proxies that had already expired never renewed by themselves, and a call succeeded only once the workloads at both ends had been restarted."
- Whether such a proxy would ever have recovered on its own is *still open*: both runs moved from the waiting window straight into restarts.

[Back to the triage table](#triage-table)

### `linkerd check` passes but traffic still fails

- In both issuer runs, `linkerd check` and `linkerd check --proxy` reported everything healthy (`Status check results are √`) — including the row "data plane proxies certificate match CA" — six seconds before a sample of fresh connections through those same proxies failed ten out of ten, on both client pairs.
- The issuer rows went green as soon as the replacement issuer loaded, and stayed green while workloads were still broken.
- *From Linkerd's code:* `linkerd check` doesn't look at workload certificates. Under `--proxy`, the check "data plane proxies certificate match CA" only compares each pod's copy of the trust anchor with the cluster's.
- **What to do:** restart the workloads (see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid)), and confirm with the proxies' own certificate metric (see [Best practices](#best-practices-prevention-and-monitoring)).

[Back to the triage table](#triage-table)

### New pods run without a proxy

- **Seen in the lab, with an important qualification: it didn't start when the certificate expired. It started when the API server had to open a new connection.** With the proxy-injector's serving certificate expired, every pod we created still came out fully injected — for about 29.6 minutes past the expiry, right up to the moment we restarted the webhook's backing pods. From the first attempt after that restart, pods were created with no `linkerd-proxy` container at all and no error reported, exactly as the fail-open setting predicts.
- On a cluster configured to fail closed, the same restart turned pod creation into an outright rejection: `failed calling webhook "linkerd-proxy-injector.linkerd.io" … x509: certificate has expired or is not yet valid`, and the pod was never created. Before that restart, pods were still being injected normally.
- *From Linkerd's code:* Linkerd's Helm chart gives the proxy-injector webhook `failurePolicy: Ignore` by default. Kubernetes documents that with `Ignore`, an error calling the webhook, a TLS error included, is ignored and the request proceeds.
- **Our inference** for the delay: the API server kept using a connection it had opened before the certificate expired, and only validates the certificate when it opens a new one. The cluster's own logs show no failed call to this webhook until seconds after the restart, which fits, but we did not instrument the API server's connection handling.
- `linkerd check` did flag it at the moment of expiry, without waiting for any reconnect: `× proxy-injector webhook has valid cert`. It stops at the first failing row in that category, though, so the other two webhooks' rows never appeared again in the same run.
- **Suggested wording:** "An expired webhook certificate is not necessarily a loud failure. In our testing, the proxy injector kept injecting proxies for about half an hour after its certificate expired, on a connection the API server had already opened, and only started silently skipping injection once its pods were restarted and the API server had to reconnect. Whether an expired webhook bites now or later depends on that reconnect."
- **Caveat:** our lab supplied its own static webhook serving certificates, which is not how Linkerd normally runs — Linkerd's own controller rotates these. That matters most for recovery (see [Best practices](#best-practices-prevention-and-monitoring)). The full record is in [notes/lab-evidence-webhook-expiry.md](notes/lab-evidence-webhook-expiry.md).

[Back to the triage table](#triage-table)

### Policy and ServiceProfile resources aren't validated

- **The two validators did not behave alike, and that difference is the finding.** With the ServiceProfile validator's certificate expired, invalid ServiceProfiles were still correctly rejected for about 9.6 minutes past its expiry — and then, from the first attempt after we restarted the webhooks' backing pods, an invalid ServiceProfile was accepted without complaint.
- The policy validator was different: its calls started failing at its own expiry, with no reconnect needed. Under the fail-open default an invalid policy resource was accepted from that moment on; on a cluster configured to fail closed, even a *valid* policy resource was refused from that moment, with an x509 "certificate has expired" error rather than a validation message.
- Why those two webhooks differed is *still open*. Our runs show the split — the cluster's own logs record the policy validator failing 5 seconds after its expiry, and no failures for the other two until seconds after the restart — but nothing we recorded explains it.
- *From Linkerd's code:* the policy-validator and ServiceProfile-validator webhooks get the same `failurePolicy: Ignore` default; an x509 rejection appears only where an installation has changed the policy to `Fail`.
- **Suggested wording:** "With an expired validator certificate and Linkerd's default fail-open policy, `kubectl apply` of a policy or ServiceProfile succeeds without being validated. In our testing that silence began at different times for different webhooks — immediately for the policy validator, and only after the API server reconnected for the ServiceProfile validator."
- Meshed traffic was unaffected throughout both runs: every probe succeeded, before and after each webhook expired. An expired webhook certificate is an admission problem, not an mTLS problem.
- The same credential caveat applies as above: these were lab-supplied static webhook certificates. The full record is in [notes/lab-evidence-webhook-expiry.md](notes/lab-evidence-webhook-expiry.md).

[Back to the triage table](#triage-table)

### A proxy can't renew during an identity-service outage

- **Seen in the lab.** We scaled the identity service to zero for about 15 minutes, with 5-minute workload certificates and a long-lived anchor and issuer — no credential changed at any point.
- Existing proxies kept serving normally until their own certificates expired, about 2 minutes 40 seconds into the outage. The first failed connection landed 1 second after the expiry of the earlier-expiring end of each pair, as a `Connection reset by peer` — a hard reset, not a hang.
- Pods created during the outage never became ready. Their `linkerd-proxy` container failed its startup probe over and over, logging that it could not resolve the identity service's address — the service had no endpoints at all. Both such pods became ready within 16 seconds of the identity service coming back.
- **The proxy that was never restarted did not re-certify on its own.** This answers a question our earlier round left open. For the five minutes after the identity service returned, during which we deliberately restarted nothing, every expired proxy's renewal timestamp and renewal counter sat exactly where they had been before the outage, and fresh connections failed ten out of ten on both pairs. Only a pod restart got a proxy a new certificate.
- **Something we saw but cannot explain.** After we restarted every meshed workload, so that both ends of each pair held fresh certificates, our probes still failed — no longer as a reset, but as a connection accepted with no reply. The control plane's own proxies were never restarted in this run and their logs were not captured, so we can't say what caused this. We are recording it as an open question, not as a finding, and the article should not assert a cause.
- *From Linkerd's code:* a proxy renews its certificate at 70% of the remaining lifetime, never more often than every 10 seconds, and keeps its current certificate when a renewal fails. So the workload certificate lifetime is your tolerance for an outage: at most about a day with the default 24-hour certificates.
- **A real-world report** describes the same shape: after a long control-plane outage, proxies' certificates expired and pods had to be restarted ([linkerd2 #13136](https://github.com/linkerd/linkerd2/issues/13136)).
- **Suggested wording:** "A proxy rides out an identity-service outage on the certificate it already has. In our testing, once that certificate expired, new connections through the proxy failed with a connection reset, and the proxy did *not* pick up a new certificate when the identity service came back — it took a restart."
- The full record is in [notes/lab-evidence-identity-outage.md](notes/lab-evidence-identity-outage.md).

[Back to the triage table](#triage-table)

### Trust anchor expired

- **Seen in the lab.** With a 20-minute trust anchor, a 2-hour issuer that outlived it, and 5-minute workload certificates, nothing visible happened at the moment the anchor expired.
- From the first certificate request after the anchor's expiry, the identity service refused every one, naming the anchor's own expiry date in the error. In the roughly 30 minutes between the expiry and our recovery it refused 213 requests and issued none. The identity service stayed up and reachable throughout — this is a validation refusal, not an outage.
- **When failures appeared: about four minutes after the anchor expired, and all at once.** Each proxy kept working on its current certificate until that certificate ran out, 254 to 257 seconds after the anchor's expiry. All six meshed proxies' final certificates expired within 3 seconds of each other, and both of our client pairs failed in the same second, 2 seconds after the earlier-expiring end of each pair ran out.
- **We expected failures to stagger across proxies. In our lab they did not.** *Our inference* about why: every workload in the lab was deployed at the same moment, so their renewal cycles ran in lockstep rather than drifting apart. We did not measure that, and a fleet whose pods started at different times might well spread out. Don't repeat "failures stagger" as something we reproduced.
- New pods created after the anchor expired never became ready — their proxies asked for a certificate and were refused.
- Connections that were already open were never seen to fail: an HTTP client and a held-open TCP connection both kept working right through the fault, until their pods were restarted during recovery for unrelated reasons. That is not evidence that an open connection survives indefinitely; only that these didn't fail before we tore them down.
- `linkerd check` went fatal, naming the exact expiry: `× trust anchors are within their validity period`, with `… not valid anymore. Expired on <time>`.
- **Suggested wording:** "An expired trust anchor doesn't announce itself. The identity service starts refusing every certificate request, but nothing breaks until each workload's current certificate runs out — up to a day later with Linkerd's default 24-hour certificates. In our lab, with 5-minute certificates, traffic failed about four minutes after the anchor expired, and because every workload had been started at the same moment, they all failed together rather than one at a time."
- To fix it, see [Fixing an expired trust anchor](#fixing-it-replacing-an-expired-trust-anchor). The full record is in [notes/lab-evidence-anchor-expiry.md](notes/lab-evidence-anchor-expiry.md).

[Back to the triage table](#triage-table)

---

## Three failures that look alike: issuer expired, identity service down, trust anchor expired

All three leave you with a mesh where some calls fail, new pods won't start, and nothing in the application's own errors mentions certificates. Here is what separated them in our lab.

| | Identity issuer expired | Identity service down | Trust anchor expired |
| --- | --- | --- | --- |
| **What went wrong** | The issuer's own signing certificate reached its expiry. Nothing was taken down and no configuration changed. | We scaled the identity service to zero replicas for about 15 minutes. No credential changed. | The trust anchor reached its expiry. Nothing was taken down and no configuration changed. |
| **Was the signing certificate still valid?** | No — the issuer is the thing that expired. | Yes, throughout. What was missing was the service that signs requests, not the signer's validity. | The issuer was still within its own dates, but every request is checked against the anchor, and the anchor had expired. |
| **Could workloads reach the identity service?** | Yes at the network level — it stayed up and ready — but no pre-existing proxy could complete a request: each one's own handshake to the identity service was aborted with a `CertificateExpired` alert. | No. The service had no endpoints for the whole outage; new pods' proxies couldn't even resolve its address. | Yes, and it kept receiving requests. It refused all 213 requests recorded and issued nothing. |
| **How failure spread** | Simultaneously at the certificate level: every workload certificate carried the issuer's own expiry, so all expired in the same second. At the traffic level it split by connection: fresh connections failed at once, while an already-open connection and a reused HTTP path kept working for about 37 minutes. | Bounded by each proxy's own remaining certificate life: proxies kept working until their current certificate expired, about 2 minutes 40 seconds into the outage, then failed with a connection reset. Pods created during the outage never became ready. | Nothing at the moment of expiry; failures arrived when each proxy's current certificate ran out, about four minutes later. All six proxies' certificates expired within 3 seconds of each other, so they failed together rather than staggering. |
| **What recovery took** | Replacing the issuer, which the identity service loaded by itself in 20 to 30 seconds without being restarted — and then a restart of every meshed workload. Proxies holding expired certificates never recovered on their own, and a call worked only once both of its ends had been restarted. | The identity service coming back (a new pod, the same credentials). Pods waiting on it became ready in 16 seconds. A proxy whose certificate had already expired did *not* recover on its own in the five minutes we watched; only a restart got it a new certificate. After every workload was restarted our probes still failed, for reasons this run can't explain. | Linkerd's documented replacement of the anchor and issuer together, which restarted the control plane as part of applying them; the identity service issued certificates under the new anchor about 25 seconds later; then a restart of every meshed workload. Whether a separate identity restart is needed is unresolved — see [Fixing an expired trust anchor](#fixing-it-replacing-an-expired-trust-anchor). |
| **What `linkerd check` showed** | `× issuer cert is within its validity period` after the expiry; all issuer rows green again the moment the new issuer loaded — while fresh connections were still failing ten out of ten. | Not measured: we did not run `linkerd check` during this experiment. | `× trust anchors are within their validity period`, naming the exact expiry, and a non-zero exit; clean again after the full recovery. |

**Telling them apart.** Run `linkerd check` first: it names an expired issuer and an expired anchor directly, in different rows, and quotes the date. If both rows are fine, look at the identity service itself — during an outage it has no running pods and no endpoints, and new pods' proxies log a name-resolution failure for the identity service's address rather than a certificate error. The identity service's own log separates the first two as well: with an expired issuer it reports a CA validation failure quoting the *issuer's* expiry date; with an expired anchor it reports one quoting the *anchor's* date, alongside `IssuerValidationFailed` events on the identity deployment. And note which direction is failing: an expired issuer or anchor stops proxies from getting certificates *from the identity service*, while what an application sees is two proxies failing to reach *each other*. The second follows from the first, and only the first tells you which credential is at fault.

---

## Details: expected from Linkerd's code, not yet tested

This has not been reproduced. It says what the code or documentation states, what is our own inference, and what experiment would confirm it. The detail behind it is in [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md).

### Tap and other viz features stopped working

- **What the code says:**
  - `linkerd viz tap` is served through a Kubernetes aggregated API with its own serving certificate.
  - `linkerd viz check` checks that certificate. No check covers the viz tap-injector's certificate.
- **Our inference:** when the tap API's certificate expires, Kubernetes marks that aggregated API unavailable, and tap stops working.
- **A related real-world report** has a different cause: tap stopped working after the Kubernetes API server's request-header client CA, which it uses for aggregated APIs, was rotated, until the tap pod was restarted ([linkerd2 #13196](https://github.com/linkerd/linkerd2/issues/13196)).
- **What would confirm it:** install viz in the lab and expire the tap API certificate.

[Back to the triage table](#triage-table)

---

## Diagnosis: how to tell it's the issuer

These signals were all *seen in the lab*, in roughly the order an operator runs into them. They go with the first two rows of the [triage table](#triage-table).

- **Application errors:** fresh connections fail with `Connection reset by peer`. The message doesn't mention certificates. Other traffic may keep working (see [Traffic partly broken](#issuer-expired-traffic-partly-broken)).
- **`linkerd check`:**
  - Before expiry: `‼ issuer cert is valid for at least 60 days`, with the exact expiry time in the detail line.
  - Afterwards: `× issuer cert is within its validity period`, with `issuer certificate is not valid anymore. Expired on <time>`.
- **Identity service log:** `could not process CSR because of CA cert validation failure: x509: certificate has expired or is not yet valid`.
- **Workload proxy logs:** in our repeat runs, every pre-existing workload's own proxy log carried `Failed to obtain identity` lines, recording a fatal `CertificateExpired` alert received from the identity service's endpoint. No x509 validation error appears in the workload's own log — the rejection happens at the handshake.
- **Kubernetes events** on `deployment/linkerd-identity`: `IssuerValidationFailed`. Kubernetes folds repeats into one event with a count, so look at the count, not the number of lines.
- **Metric:** the identity service's `issuer_cert_ttl_seconds` goes negative.
- **New pods:** stuck in `Init`, with the `linkerd-proxy` startup probe failing (see [Rollout stuck](#issuer-expired-rollout-stuck-while-old-pods-keep-serving)).
- **Don't be misled:**
  - The identity pod itself stays Running and Ready throughout.
  - `linkerd check` can be entirely green while traffic is broken (see [`linkerd check` passes but traffic still fails](#linkerd-check-passes-but-traffic-still-fails)).

### Signals for the other causes

- **Expired trust anchor:** `linkerd check` reports `× trust anchors are within their validity period` and names the expiry. The identity service's log shows the same CA validation failure as for an expired issuer, but the date it quotes is the anchor's, and `IssuerValidationFailed` events appear on the identity deployment. Traffic is still fine at that point; it fails when each workload's certificate runs out.
- **Identity service down:** the identity deployment has no ready pods and its service has no endpoints. New pods stay `Pending` with their `linkerd-proxy` container restarting and logging that it cannot resolve `linkerd-identity-headless`. Existing traffic keeps working until certificates expire.
- **Expired webhook certificate:** `linkerd check` reports `× <name> webhook has valid cert` with the expiry date — at the moment of expiry, whether or not anything has started failing yet. It stops at the first failing row in that category, so if more than one webhook certificate has expired you will only be shown the first; check the others' certificates directly. On the cluster side, the API server's log records `failed calling webhook … x509: certificate has expired`, and the timing of those entries is the clue to whether it has reconnected yet.

---

## Fixing it: replacing an expired issuer while the trust anchor is still valid

**What we did:** we followed Linkerd's documented procedure.

1. Sign a new issuer certificate from the existing trust anchor.
2. Apply it with `linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=… | kubectl apply -f -`. There's no trust-anchor flag, and the trust anchor stays untouched.

Linkerd's "Replacing expired certificates" page sends you to the [manual rotation guide](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/) for this case. That guide also says to restart the proxies of all injected workloads afterwards.

**What happened.** *Seen in the lab, in both repeat runs:*

- The identity service picked up the new issuer by itself, 20 seconds after we applied it in one run and 30 seconds in the other, without being restarted. You'll see an `IssuerUpdated` event.
- `linkerd upgrade` also restarted the destination and proxy-injector pods. It did not restart the identity service.
- Pods that had never received a certificate, the stuck new ones, became ready by themselves within a minute or so.
- Pods whose certificates had already expired did not recover, and kept failing the same handshake to the identity service for as long as we left them (see [A proxy is still on an expired certificate](#a-proxy-is-still-on-an-expired-certificate-after-an-issuer-fix)).
  - Restarting only the client end of a call didn't help: fresh connections still failed ten out of ten.
  - Once the pods at both ends had been restarted, connections succeeded ten out of ten, within about a minute of the restart.
- During all of this, `linkerd check` reported everything healthy (see [`linkerd check` passes but traffic still fails](#linkerd-check-passes-but-traffic-still-fails)).

**Suggested advice:** "After you replace the issuer, restart every meshed workload, as Linkerd's guide says; for example, `kubectl rollout restart deploy -n <namespace>` for each meshed namespace. Restarting only the workload you noticed isn't enough — in our testing a call recovered only once the pods at both ends had been restarted. Don't wait for proxies to recover on their own. In testing, they didn't. Then confirm the fix by checking that proxies hold new certificates (see [Best practices](#best-practices-prevention-and-monitoring)), not just that `linkerd check` passes."

**Caveats:**

- Whether stuck proxies would eventually recover on their own is *still open*.
- The advice above follows Linkerd's documentation, so it holds either way.

---

## Fixing it: replacing an expired trust anchor

Linkerd's ["Replacing expired certificates"](https://linkerd.io/docs/tasks/replacing_expired_certificates/) guide is the authority here: when the anchor itself has expired, the anchor and issuer are replaced together. Our lab followed it once, and this is what we saw.

**What we did:** created a new anchor and a new issuer signed by it, and applied both in one `linkerd upgrade --identity-trust-anchors-file=… --identity-issuer-certificate-file=… --identity-issuer-key-file=… --force | kubectl apply -f -`.

**What happened.** *Seen in the lab:*

- The upgrade's own rollout restarted all three control-plane deployments — identity, destination and proxy-injector — as part of applying the new credentials. The identity pod came back as a new pod carrying the new trust bundle.
- A canary workload created immediately afterwards was injected normally and received a certificate chained to the new anchor about 25 seconds later, with a matching issuance in the identity service's log.
- Restarting every remaining meshed workload then restored traffic: fresh connections succeeded ten out of ten on both client pairs, with certificates issued under the new anchor.
- `linkerd check` was clean afterwards.

**What this run does *not* settle.** Whether the identity service needs an explicit, separate restart is unresolved. The documented procedure restarted the control plane itself, as a side effect of applying the new credentials, so our run never saw the case where it doesn't. Don't present a separate identity restart as necessary, and don't present it as unnecessary either.

**Before that, during the fault:** the identity service refused every certificate request from the moment the anchor expired, and traffic kept working until each workload's current certificate ran out (see [Trust anchor expired](#trust-anchor-expired)). With Linkerd's default 24-hour workload certificates, that grace period is far longer than our lab's — which means you may have most of a day's warning, if you are watching.

---

## Best practices: prevention and monitoring

### From what we saw in the lab

- **Watch the issuer directly.** The identity service exposes `issuer_cert_ttl_seconds`, a live countdown of the issuer's remaining life that goes negative once it expires.
- **Metric names are as of Linkerd `edge-26.9.1`,** the version we tested; check them against your version.
- **Watch workload certificates too.** Each proxy exposes `control_identity_cert_expiration_timestamp_seconds`, its certificate's expiry time. After any rotation, check that this value moved on every proxy. In our lab `linkerd check` passed while it hadn't moved on the proxies that were still broken (see [`linkerd check` passes but traffic still fails](#linkerd-check-passes-but-traffic-still-fails)).
- **After replacing the issuer, restart every meshed workload** — both ends of every call (see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid)).
- **Workload certificate lifetime is your tolerance for an identity-service outage,** and recovery is not automatic. In our lab a proxy whose certificate expired during a 15-minute outage did not renew when the service came back; it took a restart (see [A proxy can't renew during an identity-service outage](#a-proxy-cant-renew-during-an-identity-service-outage)).

#### Don't treat the 60-day warning as a 60-day line

- *From Linkerd's code:* the warning threshold is 60 days, and it can't be configured.
- *Seen in the lab:* the headline `‼ issuer cert is valid for at least 60 days` looked exactly the same for an issuer with about 15 minutes to live (in two runs) as for one about 10 minutes short of 60 days. Only the date in the detail line showed how close expiry was.
- *Also seen in the lab, and worth knowing:* an issuer with about **nine minutes more** than 60 days of life left still got that same warning, in all four checks we recorded in that run (with and without `--proxy`). So this row is not a precise 60-day boundary, and the check wants more margin than a plain countdown would suggest. Exactly where above 60 days it clears is *still open* — our evidence run never saw it clear, and we won't quote a figure we didn't establish.
- **So:** alert on the issuer's expiry date, or on the metric, not on whether this row is green, and don't read a warning as proof that you have less than 60 days. The measurements are in [notes/lab-evidence-check-threshold.md](notes/lab-evidence-check-threshold.md).

#### Treat webhook certificates as first-class

- Webhook serving certificates are separate credentials with their own trust chain; Linkerd's documentation is explicit that they are not part of proxy-to-proxy TLS.
- *Seen in the lab:* an expired webhook certificate was silent for a long time. The proxy injector kept injecting for about 29.6 minutes past its own expiry and the ServiceProfile validator kept validating for about 9.6 minutes past its, both on connections the API server had already opened; the policy validator failed at its own expiry. All three failed once their pods were restarted and the API server had to reconnect. So an expired webhook certificate can sit unnoticed until the next restart of anything in that path — and then fail everywhere at once.
- *Seen in the lab:* `linkerd check` warns about the proxy-injector, ServiceProfile-validator and policy-validator certificates at 60 days, and reports the first expired one as fatal straight away — but it stops at that row, so a second expired webhook certificate stays hidden. Nothing checks the viz tap-injector's certificate.
- *Seen in the lab, with a caveat that matters:* recovery took more than a plain `linkerd upgrade`. In both of our runs, re-running `linkerd upgrade` re-rendered the same, still-expired certificates; the webhooks only recovered once we supplied freshly generated credentials explicitly. **That is a fact about our setup, not about default Linkerd:** our lab supplied its own static webhook serving certificates, whereas Linkerd normally rotates these itself. Treat it as a warning about externally supplied webhook credentials, not as a claim about a default installation.

#### Trust-anchor rotation needs restarts

*From Linkerd's code:* each proxy reads the trust anchor once, when its pod starts, so a new anchor only takes effect as pods restart. That is why Linkerd's rotation procedure is staged. We ran both the staged procedure and the shortcut, once each.

**The staged procedure, as we ran it,** following Linkerd's guide:

1. Create the new anchor, and apply a trust bundle containing **both** the old and the new anchor. Every proxy that restarts from here on will accept peers presenting either.
2. **Restart every meshed workload.** This is what makes the bundle real: right after the bundle was applied, `linkerd check --proxy` listed every meshed pod under "Some pods do not have the current trust bundle and must be restarted", and the warning was gone after the restart.
3. Apply a new issuer signed by the new anchor. Workloads now take certificates rooted in the new anchor, which every proxy already trusts.
4. **Restart every meshed workload again,** so they all hold certificates from the new issuer.
5. Apply the new anchor on its own, dropping the old one from the bundle.
6. **Restart every meshed workload a final time,** so nothing still trusts the old anchor.

*Seen in the lab:* across all three restart rounds, not one fresh connection failed — every sample succeeded on both client pairs — and no proxy log mentioned a certificate, trust or handshake problem at any point in the run. The only application-visible disruption was a held-open TCP connection dropping each time the pod at its other end was recycled, which our comparison run showed happening for an ordinary restart with no rotation involved. "Without downtime" means fresh connections and requests keep working; connections already open across a pod restart still break.

**Expect the "restart these pods" warning to come back between steps.** It is Linkerd telling you that some pods still hold an older trust bundle, so it legitimately reappears after the step that drops the old anchor, and clears once the final restart has gone through — our check after that last restart was clean. (*Our inference* on the middle occurrence: we recorded the warning after the bundle step and a clean check after each restart, but captured no check in the gap between dropping the old anchor and the final restart.)

**Never replace the anchor and issuer in one step against a live fleet.** *Seen in the lab:* when we swapped both at once, the identity service restarted onto the new credentials within a second — and from that moment a proxy that had not been restarted could no longer even complete a handshake with the identity service, because its own trust bundle couldn't validate the service's new certificate. None of them ever renewed anything. Each rode out the certificate it already held and then failed outright, about 2 minutes 40 seconds after the swap with our 5-minute certificates. Restarting the fleet piecemeal didn't help in between: a restarted client calling a not-yet-restarted server failed ten out of ten, and so did a not-yet-restarted client calling a restarted server. Only once both ends were restarted did traffic work.

The timing is the trap: with production certificate lifetimes, none of this appears at the moment of the swap. It appears when the fleet's oldest live certificate expires — potentially hours later, long after the change looked successful. The full record is in [notes/lab-evidence-anchor-rotation.md](notes/lab-evidence-anchor-rotation.md).

### From Linkerd's code, not yet tested

- **Nothing checks the viz tap-injector's certificate,** and we have not tested what an expired tap API certificate does (see [Tap and viz](#tap-and-other-viz-features-stopped-working)).

---

## Still open

- Whether a proxy stuck on an expired certificate would ever recover without a restart. In our runs we never left one alone long enough to find out.
- Which side rejects a connection when two *workload* proxies both hold expired certificates. We established the direction for a proxy talking to the identity service — the identity service's own proxy aborts the handshake — but not for two workloads talking to each other.
- Why the HTTP client kept working. Connection reuse is the explanation from Linkerd's code; we only recorded the outcome that explanation predicts. How long an already-open connection lasts if nothing restarts is also still open: ours survived about 37 minutes and then ended because we restarted the pod at its other end.
- How any of this plays out with the default 24-hour workload certificates. Every run used much shorter lifetimes.
- Why traffic stayed broken after our identity-service outage even once every meshed workload had been restarted and both ends held fresh certificates. The control plane's own proxies were never restarted in that run and their logs weren't captured, so we can't attribute it.
- Why the three webhooks behaved so differently — one failing at its own expiry, two carrying on for very different lengths of time until the API server reconnected.
- Whether the second and third expired webhook certificates independently go fatal in `linkerd check` at their own expiry. The check stops at the first failing row in that category, so our runs couldn't see.
- Where above 60 days the `linkerd check` issuer warning actually clears. Our evidence run showed it still warning at 60 days plus about nine minutes.
- Whether recovery from an expired trust anchor needs the identity service restarted separately. The documented procedure restarted it itself, so our run couldn't isolate the question.
- Whether trust-anchor expiry would stagger failures across a fleet whose pods were started at different times. In our lab every workload was deployed at the same moment, and they all failed together.
- The viz/tap scenario, which we have not run at all.

---

## Where the details are

- [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) — the first issuer-expiry experiment, quoting the raw logs, metrics and `linkerd check` output.
- [notes/lab-evidence-issuer-expiry-rerun.md](notes/lab-evidence-issuer-expiry-rerun.md) — two repeats of that experiment with fuller recording: which restarts are needed, how the handshake fails, and how long an open connection lasted.
- [notes/lab-evidence-webhook-expiry.md](notes/lab-evidence-webhook-expiry.md) — three webhook certificates expiring ten minutes apart, under each failure policy, and what recovery took.
- [notes/lab-evidence-identity-outage.md](notes/lab-evidence-identity-outage.md) — what happened while the identity service was down, and what did and didn't recover when it came back.
- [notes/lab-evidence-check-threshold.md](notes/lab-evidence-check-threshold.md) — what `linkerd check`'s 60-day issuer warning did just under, and just over, the boundary.
- [notes/lab-evidence-anchor-expiry.md](notes/lab-evidence-anchor-expiry.md) — a trust anchor expiring: when failures appeared, and what recovery took.
- [notes/lab-evidence-anchor-rotation.md](notes/lab-evidence-anchor-rotation.md) — rotating a trust anchor by Linkerd's staged procedure, and replacing it in one step.
- [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md) — the source reading behind every "from Linkerd's code" statement, with links to the exact lines of code.
- [sources.md](sources.md) — what to cite for each claim, and which claims need careful wording.
