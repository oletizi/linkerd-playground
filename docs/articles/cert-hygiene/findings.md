# What we found: Linkerd certificate expiry

This page sums up what we know about Linkerd certificate expiry, from two kinds of work: an experiment in which we let Linkerd's identity issuer expire on purpose in a throwaway test cluster and recorded what happened, and reading Linkerd's source code and documentation. It follows the order of the article outline.

Every statement says where it comes from:

- **Seen in the lab** — we made it happen and recorded it.
- **From Linkerd's code, not yet tested** — read in Linkerd's source or documentation, or in Kubernetes' documentation; we have not reproduced it. Where a conclusion is our own reasoning from the code rather than something the code states, it is marked **our inference**.
- **Still open** — we don't know yet.

**Scope, before you generalise anything.** The lab result comes from one experiment on Linkerd `edge-26.9.1` (released 2026-09-04), on a single-node test cluster. To make expiry happen in minutes instead of days, we shortened the lifetimes: the issuer lived 15 minutes and workload certificates 5 minutes (Linkerd's default for workload certificates is 24 hours). A matching run with long-lived certificates, where nothing expired, showed no failures at all, so the failures below come from the expiry and not from the test setup. Where a timing below says "seconds" or "minutes", expect the same shape stretched over hours with default settings.

---

## The short version

### What we reproduced

1. **When the identity issuer expires, every workload certificate in the mesh expires at the same moment.** Linkerd caps each workload certificate at the issuer's own expiry, so there's no gradual spread.
2. **Some traffic broke at once, and some kept working.** A client opening a fresh TCP connection for every request failed within seconds. An HTTP client, and one TCP connection that was already open, kept working for the roughly 10 minutes we recorded. New pods, and restarted copies of existing ones, never became ready. The mesh looked half-broken: some calls succeeded, some failed, and nothing new rolled out.
3. **Replacing the issuer isn't enough on its own.** Linkerd picked up the new issuer by itself within about 30 seconds, but workloads whose certificates had already expired stayed broken until they were restarted. Linkerd's own procedure says to restart every meshed workload after replacing the issuer.
4. **`linkerd check` catches an expired issuer, but it can't tell you that recovery finished.** It reported everything healthy while workloads were still running on expired certificates.

### What Linkerd's code says, not yet tested

5. **Linkerd's admission webhooks fail open by default.** Linkerd configures every webhook to ignore errors, so an expired webhook certificate should not make `kubectl` reject anything; injection or validation is skipped instead.
6. **Linkerd's proxies don't check the trust anchor's own expiry date; the identity service does.** Our inference: an expired trust anchor fails late, when each workload's current certificate runs out.

---

## Triage table

Two tables: what we reproduced, and what Linkerd's code predicts but we haven't tested. Each row links to its details.

### Reproduced in the lab

| What you're seeing | What to suspect | Why | Details |
| --- | --- | --- | --- |
| Some calls work and some fail. Fresh TCP connections fail, often as a plain "connection reset", while an already-open connection and an HTTP client keep working. | Identity issuer expired | Every workload certificate is capped at the issuer's expiry, so they all expire at once, and nothing can renew. | [Traffic partly broken](#issuer-expired-traffic-partly-broken) |
| A deployment won't finish rolling out. New pods sit in `Init` with `linkerd-proxy` failing its startup probe, while the old pods keep serving. | Identity issuer expired | The new pod's proxy can't get a certificate, so it never becomes ready. | [Rollout stuck](#issuer-expired-rollout-stuck-while-old-pods-keep-serving) |
| After the issuer was replaced, a proxy is still on an expired certificate. | Proxies that expired before the fix don't renew by themselves; restart the workload | In our lab, such proxies stayed expired for the 10 minutes we watched, and restarting the lab workloads restored them. | [Proxy still expired](#a-proxy-is-still-on-an-expired-certificate-after-an-issuer-fix) |
| After an issuer fix, `linkerd check` passes but traffic is still failing. | Workloads not yet restarted, still on expired certificates | `linkerd check` reported healthy while proxies still held expired certificates. | [check passes, traffic fails](#linkerd-check-passes-but-traffic-still-fails) |

### Expected from Linkerd's code, not yet tested

| What you'd see | What to suspect | Why (from the code) | Details |
| --- | --- | --- | --- |
| New pods run normally, with no errors, but have no `linkerd-proxy` container. | Proxy-injector webhook certificate expired | The webhook is configured to fail open, so pods are admitted without being injected. | [Pods without a proxy](#new-pods-run-without-a-proxy) |
| Linkerd policy or ServiceProfile resources apply without complaint but aren't validated. | Policy-validator or ServiceProfile-validator webhook certificate expired | Same fail-open setting: validation is skipped, not enforced. | [Validation skipped](#policy-and-serviceprofile-resources-arent-validated) |
| After the identity service has been down for a while, meshed traffic starts failing. | Proxies' certificates ran out while they couldn't renew | A proxy that can't reach the identity service keeps its current certificate until it expires. | [Identity outage](#a-proxy-cant-renew-during-an-identity-service-outage) |
| Traffic was fine, then starts failing although nothing changed; the identity service refuses to issue certificates. | Trust anchor expired | Proxies don't check the anchor's own date; the identity service does. When failures appear is our inference. | [Trust anchor](#trust-anchor-expired) |
| `linkerd viz tap` and other viz features stop working. | Viz tap API certificate expired | Tap is served through a Kubernetes aggregated API with its own certificate. What an expired one does is our inference. | [Tap and viz](#tap-and-other-viz-features-stopped-working) |

---

## Details: reproduced in the lab

### Issuer expired: traffic partly broken

- Every workload certificate, including the control plane's own, had the same expiry time as the issuer. All of them expired in the same second.
- A client that opens a fresh TCP connection for every request started failing within 2 seconds of the expiry. The application saw `Connection reset by peer`, not a TLS or certificate error.
- One TCP connection that was already open kept working for the whole 574 seconds (about 9.5 minutes) we recorded after the expiry. How much longer it would have lasted, and whether every open connection behaves the same, is *still open*.
- An HTTP client that starts a fresh `curl` for every request also kept working over those 574 seconds. Why is *still open*: one likely explanation, from Linkerd's code, is that the proxies kept reusing a connection between them that was opened before the expiry, but we didn't record that.
- So "new connections fail first" is too broad. What failed in our lab was a fresh TCP connection through the mesh.
- Pods that started after the expiry never became ready (see [Rollout stuck](#issuer-expired-rollout-stuck-while-old-pods-keep-serving)).
- **Suggested wording:** "Once the issuer expires, Linkerd can't sign new workload certificates. In current Linkerd, every workload certificate is also capped at the issuer's expiry, so they all expire at the same moment. In our testing, some traffic failed immediately, often as a plain 'connection reset' rather than a certificate error, while other traffic, including a connection that was already open, kept working for as long as we watched. That's why the mesh looks partly broken rather than down, and why anything that restarts gets worse."
- To confirm it, see [Diagnosis](#diagnosis-how-to-tell-its-the-issuer). To fix it, see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid).

[Back to the triage table](#triage-table)

### Issuer expired: rollout stuck while old pods keep serving

- The new pod has a `linkerd-proxy` container, but it never starts.
- The pod sits in `Init`, and its events show the `linkerd-proxy` startup probe failing (HTTP 503).
- Kubernetes keeps killing and restarting the proxy (three times in about 8 minutes in our run).
- The old pod keeps serving, and the rollout waits.
- The old pod stayed "Ready" in Kubernetes the whole time, even though its own certificate had expired. Pod readiness tells you nothing about certificate health.
- New pods that are running but have no `linkerd-proxy` container at all are a different problem; see [New pods run without a proxy](#new-pods-run-without-a-proxy) (not yet tested).

[Back to the triage table](#triage-table)

### A proxy is still on an expired certificate after an issuer fix

- After the expired issuer was replaced, proxies whose certificates had already expired did not get new ones on their own. They were still on their expired certificates about 10 minutes later, when we restarted them.
- Proxies that had never had a certificate (the stuck new pods) did get one, within about a minute.
- Restarting every lab workload restored them. The run didn't show which of those restarts were strictly necessary.
- **Suggested wording:** "If you've just replaced the issuer and a proxy is still on an expired certificate, restart its workload. In our testing, proxies that had already expired didn't renew by themselves, and restarting the workloads restored them."
- Why those proxies didn't renew, and whether they would have recovered eventually, is *still open*. So is whether other causes can leave a proxy in the same state.

[Back to the triage table](#triage-table)

### `linkerd check` passes but traffic still fails

- After the issuer was replaced, `linkerd check` and `linkerd check --proxy` reported everything healthy (`Status check results are √`) at every point we sampled, while four proxies were still running on expired certificates and new connections through them were failing.
- *From Linkerd's code:* `linkerd check` doesn't look at workload certificates. Under `--proxy`, the check "data plane proxies certificate match CA" only compares each pod's copy of the trust anchor with the cluster's.
- **What to do:** restart the workloads (see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid)), and confirm with the proxies' own certificate metric (see [Best practices](#best-practices-prevention-and-monitoring)).

[Back to the triage table](#triage-table)

---

## Details: expected from Linkerd's code, not yet tested

None of these have been reproduced. Each says what the code or documentation states, what is our own inference, and what experiment would confirm it. The detail behind each is in [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md).

### New pods run without a proxy

- **What the code says:** Linkerd's Helm chart gives the proxy-injector webhook `failurePolicy: Ignore` by default (the value `webhookFailurePolicy`). Kubernetes documents that with `Ignore`, an error calling the webhook, a TLS error included, is ignored and the request proceeds.
- **So:** with an expired proxy-injector certificate, pods should be created without a proxy, and nothing should report an error.
- `linkerd check` has a check for it, "proxy-injector webhook has valid cert", which only helps if someone runs it.
- **What would confirm it:** expire the proxy-injector's serving certificate in the lab and create a pod.

[Back to the triage table](#triage-table)

### Policy and ServiceProfile resources aren't validated

- **What the code says:** the policy-validator and ServiceProfile-validator webhooks get the same `failurePolicy: Ignore` default.
- **So:** with an expired validator certificate, `kubectl apply` of a policy or ServiceProfile should succeed without validation. An x509 rejection should appear only if an installation has changed the policy to `Fail`.
- **What would confirm it:** expire the policy-validator's serving certificate in the lab and apply an invalid policy resource.

[Back to the triage table](#triage-table)

### A proxy can't renew during an identity-service outage

- **What the code says:** a proxy renews its certificate at 70% of the remaining lifetime, never more often than every 10 seconds, and keeps its current certificate when a renewal fails. We did see this renewal timing in the lab.
- **So:** if the identity service is unreachable for longer than a proxy's certificate has left, that certificate expires, and new connections through the proxy fail. With the default 24-hour certificates, the tolerance is at most about a day.
- **A real-world report** describes this: after a long control-plane outage, proxies' certificates expired and pods had to be restarted ([linkerd2 #13136](https://github.com/linkerd/linkerd2/issues/13136)).
- **What would confirm it:** stop the identity service in the lab for longer than the workload certificate lifetime.

[Back to the triage table](#triage-table)

### Trust anchor expired

- **What the code says:**
  - Proxies load the trust anchor without checking its own validity dates.
  - The identity service checks the issuer against the trust anchor on every certificate request, using a check that also enforces the anchor's dates. So it should refuse to issue certificates once the anchor expires. That reading is marked as an inference in our source notes.
- **Our inference:** nothing visible should happen at the moment the anchor expires. Connections should start failing later, as each workload's current certificate runs out and can't be renewed: up to a day later with default settings.
- **What would confirm it:** let a short-lived trust anchor expire in the lab, with the same recording as the issuer experiment.

[Back to the triage table](#triage-table)

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

- **Application errors:** fresh TCP connections fail with `Connection reset by peer`. The message doesn't mention certificates. Other traffic may keep working (see [Traffic partly broken](#issuer-expired-traffic-partly-broken)).
- **`linkerd check`:**
  - Before expiry: `‼ issuer cert is valid for at least 60 days`, with the exact expiry time in the detail line.
  - Afterwards: `× issuer cert is within its validity period`, with `issuer certificate is not valid anymore. Expired on <time>`.
- **Identity service log:** `could not process CSR because of CA cert validation failure: x509: certificate has expired or is not yet valid`.
- **Kubernetes events** on `deployment/linkerd-identity`: `IssuerValidationFailed`. Kubernetes folds repeats into one event with a count, so look at the count, not the number of lines.
- **Metric:** the identity service's `issuer_cert_ttl_seconds` goes negative.
- **New pods:** stuck in `Init`, with the `linkerd-proxy` startup probe failing (see [Rollout stuck](#issuer-expired-rollout-stuck-while-old-pods-keep-serving)).
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
- Pods whose certificates had already expired did not recover. They were still broken about 10 minutes later (see [A proxy is still on an expired certificate](#a-proxy-is-still-on-an-expired-certificate-after-an-issuer-fix)).
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

### From what we saw in the lab

- **Watch the issuer directly.** The identity service exposes `issuer_cert_ttl_seconds`, a live countdown of the issuer's remaining life that goes negative once it expires.
- **Metric names are as of Linkerd `edge-26.9.1`,** the version we tested; check them against your version.
- **Watch workload certificates too.** Each proxy exposes `control_identity_cert_expiration_timestamp_seconds`, its certificate's expiry time. After any rotation, check that this value moved on every proxy. `linkerd check` passed while it hadn't moved on four proxies (see [`linkerd check` passes but traffic still fails](#linkerd-check-passes-but-traffic-still-fails)).
- **Don't rely on the `linkerd check` warning headline.** From the start of the run, the headline read `‼ issuer cert is valid for at least 60 days` for an issuer with 15 minutes to live, and it stayed unchanged until the issuer expired. Only the date in the detail line showed how close expiry was. Alert on that date, or on the metric, instead.
- **After replacing the issuer, restart every meshed workload** (see [Fixing it](#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid)).

### From Linkerd's code, not yet tested

- **The 60-day warning threshold is fixed** and can't be configured. So the headline would look the same with 59 days left as with 15 minutes left; we didn't run a 59-day case.
- **Treat webhook certificates as first-class.** Because Linkerd's webhooks fail open by default, an expired webhook certificate should be silent (see [New pods run without a proxy](#new-pods-run-without-a-proxy) and [Policy and ServiceProfile resources aren't validated](#policy-and-serviceprofile-resources-arent-validated)). `linkerd check` warns about the proxy-injector, ServiceProfile-validator and policy-validator certificates at 60 days, and nothing checks the viz tap-injector's certificate.
- **Workload certificate lifetime is your tolerance for an identity-service outage** (see [A proxy can't renew during an identity-service outage](#a-proxy-cant-renew-during-an-identity-service-outage)).
- **Trust-anchor rotation needs restarts.** Each proxy reads the trust anchor once, when its pod starts, so a new anchor only takes effect as pods restart. That's why Linkerd's staged rotation (old + new anchor, then new issuer, then remove the old anchor) involves restarting workloads.

---

## Still open

- Why proxies with expired certificates didn't renew after the issuer was replaced, and whether they would have recovered eventually.
- Which side rejects the connection when both proxies' certificates have expired.
- Why the HTTP client kept working, and how long already-open connections keep working. We recorded about 10 minutes.
- How any of this plays out with the default 24-hour workload certificates.
- Everything in the [not-yet-tested table](#expected-from-linkerds-code-not-yet-tested): the webhook, identity-outage, trust-anchor and viz scenarios haven't been run in the lab.

A repeat of the issuer experiment, run twice with fuller logging, is pending. It should answer the first two questions. The findings above rest on a single run until then.

---

## Where the details are

- [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) — the full lab record, quoting the raw logs, metrics and `linkerd check` output behind every "seen in the lab" statement above.
- [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md) — the source reading behind every "from Linkerd's code" statement, with links to the exact lines of code.
- [sources.md](sources.md) — what to cite for each claim, and which claims need careful wording.
