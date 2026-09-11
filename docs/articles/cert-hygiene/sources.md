# Sources: what to cite for each claim

**Purpose:** a maintained source and claim map for a blog post about recognizing, recovering from, and preventing certificate-expiry failures in Linkerd.

**Research rule:** Use the current Linkerd documentation as the normative source for operational procedures. Kubernetes, IETF, NIST, and cert-manager sources provide underlying mechanics and operational guidance. GitHub issues and discussions are historical, illustrative evidence—not universal behavior or current product guidance.

**Outline section key**

- **Intro** — the abstract, "The situation", and the TL;DR
- **Triage** — "Triage by what stopped working" and its table
- **Landscape** — "Why is this happening?": the PKI model and the webhook call path
- **Diagnosis** — "How to build a decision tree from the symptoms"
- **Recovery** — "How to fix": per-cause recovery
- **Hygiene** — "Best practices: how to make certificate expiration a non-event"

---

## Primary Linkerd sources

### Automatic mTLS

- **URL:** https://linkerd.io/docs/features/automatic-mtls/
- **Authority level:** Primary product documentation; normative for Linkerd behavior.
- **Claims supported:** Linkerd’s identity model; the identity issuer issues workload/proxy certificates; workload identities are tied to Kubernetes ServiceAccounts; workload certificates are short-lived (documented as 24 hours) and automatically rotate; the trust anchor and identity issuer are longer-lived credentials with different lifecycle responsibilities.
- **Outline mapping:** Intro, Landscape, Triage, Diagnosis, Hygiene.
- **Research notes:** Use to establish the mesh signing hierarchy: `trust anchor → identity issuer → workload/proxy certificate`. Do not use it to describe Kubernetes admission-webhook TLS; that is a separate relationship. It does not say that workload certificates are capped at the issuer's own expiry; that comes from Linkerd's source code and our lab (see "This project's own evidence" below).

### Automatically Rotating Control Plane TLS Credentials

- **URL:** https://linkerd.io/2-edge/tasks/automatically-rotating-control-plane-tls-credentials/
- **Authority level:** Primary product documentation; current edge task guide. Confirm the matching stable-version procedure before publishing commands.
- **Claims supported:** Linkerd rotates workload certificates but does not itself rotate the identity issuer or trust anchor; cert-manager can rotate the issuer; trust-manager can distribute a trust bundle; trust-anchor rotation requires a staged transition; Linkerd does not need access to the trust-anchor private key, while it does need the issuer private key.
- **Outline mapping:** Landscape, Recovery, Hygiene.
- **Research notes:** This is the main source for explaining why a root rotation is a bundle migration rather than a one-step replacement. Its procedure also documents the operational restarts involved in moving the mesh to a new trust configuration.

### Manually Rotating Control Plane TLS Credentials

- **URL:** https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/
- **Authority level:** Primary product documentation; current edge task guide. Confirm the matching stable-version procedure before publishing commands.
- **Claims supported:** Issuer and root rotation; the issuer-only procedure (`linkerd upgrade --identity-issuer-certificate-file=… --identity-issuer-key-file=…`, with no trust-anchor flag); the `IssuerUpdated` event as the sign that the new issuer was loaded; restarting the proxies of all injected workloads after applying a new issuer.
- **Outline mapping:** Diagnosis, Recovery, Hygiene.
- **Research notes:** Cite for the "rotate before expiry" path, and for recovering from an expired issuer: "Replacing expired certificates" points here for the issuer-only case. In our lab this procedure recovered an expired issuer, but only once every meshed workload was restarted, as the guide says (see [findings.md](findings.md#fixing-it-replacing-an-expired-issuer-while-the-trust-anchor-is-still-valid)). The guide suggests `linkerd check --proxy` to validate the result. In our lab it passed while four proxies still held expired certificates, so don't present it as proof that proxies hold valid certificates.

### Replacing expired certificates

- **URL:** https://linkerd.io/docs/tasks/replacing_expired_certificates/
- **Authority level:** Primary product documentation; normative recovery guide.
- **Claims supported:** Expired certificates put the mesh in an invalid state and zero downtime is no longer guaranteed; if only the issuer has expired and the trust-anchor key is available, replace the issuer; if the root has expired or its key is unavailable, replace root and issuer together; restart proxies/workloads after the trust configuration is updated.
- **Outline mapping:** Triage, Diagnosis, Recovery, Hygiene.
- **Research notes:** The strongest source for the recovery decision tree. Preserve its qualification that the issuer-only path depends on possession of the manually supplied trust-root key. For the issuer-only case it sends readers to "Manually Rotating Control Plane TLS Credentials", which our lab followed successfully.

### Rotating webhooks certificates

- **URL:** https://linkerd.io/2-edge/tasks/rotating_webhooks_certificates/
- **Authority level:** Primary product documentation; current edge task guide.
- **Claims supported:** Linkerd webhook and extension API-server connections are TLS-protected; webhook certificates use self-signed CAs embedded in webhook configuration; the documented default validity is 365 days; relevant secrets include the proxy injector, policy validator, ServiceProfile validator, and Viz tap injector.
- **Outline mapping:** Triage, Landscape, Diagnosis, Recovery, Hygiene.
- **Research notes:** Essential for treating a failed admission or policy operation as a potential webhook-TLS problem rather than automatically blaming mesh mTLS. Check version-specific component names and Secret names before including a command.

### Automatically Rotating Webhook TLS Credentials

- **URL:** https://linkerd.io/docs/tasks/automatically-rotating-webhook-tls-credentials/
- **Authority level:** Primary product documentation; normative configuration guidance.
- **Claims supported:** Webhook TLS credentials are separate from Linkerd proxy certificates and use a separate trust chain; Linkerd upgrades can regenerate default webhook certificates; cert-manager can manage regular automatic webhook-certificate rotation.
- **Outline mapping:** Landscape, Recovery, Hygiene.
- **Research notes:** Best source for the recommendation to manage webhook certificates as first-class operational credentials. It explicitly states the separation from proxy-to-proxy TLS.

### Troubleshooting and `linkerd check`

- **URL:** https://linkerd.io/docs/tasks/troubleshooting/
- **Authority level:** Primary product documentation; normative diagnostic guidance.
- **Claims supported:** `linkerd check` / `linkerd check --proxy` report distinct trust-anchor, issuer and webhook credential failures, including expiry, invalid CA/signing relationships, name mismatches, and missing Secrets; Linkerd's checks use a 60-day validity warning threshold.
- **Outline mapping:** Triage, Diagnosis, Recovery, Hygiene.
- **Research notes:** Make this the practical evidence-gathering source in the diagnosis section. It supports "certificate-like symptoms are not proof of expiry": inspect the reported failure and certificate state rather than inferring a root cause from a symptom. Mind its limits:
  - `linkerd check` does not inspect workload (proxy) certificates. This is from Linkerd's source code; in our lab it reported healthy while proxies held expired certificates.
  - The 60-day warning headline looked the same for an issuer with 15 minutes left. Only the date in its detail line showed how close expiry was (our lab).
  - The symptom may not look like a certificate error at all: in our lab, applications saw `Connection reset by peer`.

---

## This project's own evidence

### Our lab: identity issuer expiry

- **Where:** [findings.md](findings.md) (plain-language summary) and [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) (full record with raw evidence).
- **Authority level:** First-party experiment. One run, on Linkerd `edge-26.9.1`, on a single-node test cluster, with shortened lifetimes (15-minute issuer, 5-minute workload certificates). Paired with a run where nothing expired and nothing failed.
- **Claims supported:**
  - When the issuer expires, every workload certificate expires at the same moment.
  - New connections fail at once; open connections keep working; new pods never become ready.
  - After the issuer is replaced, workloads whose certificates had already expired stay broken until restarted.
  - `linkerd check` passed while proxies held expired certificates.
  - The signals listed in the findings' diagnosis section.
- **Outline mapping:** Triage, Diagnosis, Recovery, Hygiene.
- **Research notes:** Attribute it as "in our testing", naming the Linkerd version and the shortened lifetimes. It shows what happened in that run, not what always happens. Several open questions remain; they are listed in [findings.md](findings.md#still-open).

### Linkerd source code at `edge-26.9.1`

- **Where:** [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md), with permalinks to the exact lines.
- **Authority level:** Primary implementation. It is exact for that version and can change in later releases. Some conclusions in the notes are marked as inferences; keep that label.
- **Claims supported:**
  - Workload certificates are capped at the issuer's expiry.
  - Proxies renew at 70% of the remaining lifetime, never more often than every 10 seconds.
  - Linkerd's webhooks default to `failurePolicy: Ignore`.
  - Webhook serving certificates are generated with a 365-day lifetime.
  - Which certificates `linkerd check` inspects, and its fixed 60-day warning threshold.
  - Proxies read the trust anchor only when they start.
- **Outline mapping:** Landscape, Triage, Hygiene.
- **Research notes:** Cite for behaviour the documentation doesn't state. Where the notes mark a conclusion as an inference, present it as expected behaviour, not as fact, until a lab test confirms it.

---

## Kubernetes sources

### Dynamic Admission Control

- **URL:** https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Authority level:** Primary Kubernetes documentation; normative API behavior.
- **Claims supported:** The Kubernetes API server calls admission webhooks over HTTPS; `clientConfig.caBundle` supplies the CA bundle used to validate the webhook server; webhook failure handling is configured through `failurePolicy`.
- **Outline mapping:** Triage, Landscape, Diagnosis, Recovery.
- **Research notes:** Grounds the crucial distinction: `kube-apiserver → HTTPS webhook` is a call path with its own TLS validation, not another branch of Linkerd's workload-identity signing chain. It also documents what `failurePolicy: Ignore` means: an error calling the webhook, a TLS error included, is ignored and the request proceeds. Linkerd's Helm chart sets `Ignore` on all its webhooks by default (from Linkerd's source code; see [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md)). So an expired Linkerd webhook certificate should skip injection or validation rather than reject requests. We have not tested that yet.

### Admission Webhook Good Practices

- **URL:** https://kubernetes.io/docs/concepts/cluster-administration/admission-webhooks-good-practices/
- **Authority level:** Primary Kubernetes operational guidance.
- **Claims supported:** An unavailable webhook can reject matching API requests when configured to fail closed; webhook availability and failure policy affect blast radius; use of fail-open/fail-closed behavior requires deliberate design.
- **Outline mapping:** Triage, Diagnosis, Recovery, Hygiene.
- **Research notes:** Use for careful wording about urgency. Avoid implying that a webhook failure necessarily affects all cluster operations; its scope depends on matching rules and `failurePolicy`. Linkerd's own webhooks fail open by default (see "Dynamic Admission Control" above), so for Linkerd the typical risk is silent skipping, not rejection.

---

## PKI/X.509 and NIST guidance

### RFC 5280 — Internet X.509 Public Key Infrastructure Certificate and Certificate Revocation List (CRL) Profile

- **URL:** https://www.rfc-editor.org/rfc/rfc5280.html
- **Authority level:** IETF standards-track RFC; foundational technical standard.
- **Claims supported:** Certificates have a defined validity interval (`notBefore` and `notAfter`); certificate-path validation is time-sensitive; a relying party’s trust anchor is an input to path validation.
- **Outline mapping:** Intro, Landscape, Diagnosis.
- **Research notes:** Use sparingly for the mechanics of validity and certificate chains. Linkerd documentation should remain the source for Linkerd-specific consequences and procedures.

### NIST SP 800-57 Part 1 Rev. 5 — Recommendation for Key Management: Part 1 — General

- **URL:** https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-57pt1r5.pdf
- **Authority level:** NIST federal guidance; high-authority security and key-management guidance.
- **Claims supported:** Certificates should be inventoried upon creation to facilitate recovery and avoid expiry-related outages; a useful inventory records the certificate’s associated entity, owner/contact, private-key location or custodian, and validity period; monitoring can support proactive replacement.
- **Outline mapping:** Intro, Hygiene.
- **Research notes:** This is the strongest external source for the proposed ownership/inventory checklist. It directly connects incomplete certificate records to significant outages. Do not put private keys themselves in a general inventory unless the inventory is an approved key-backup/archive mechanism.

### NIST SP 800-57 Part 2 Rev. 1 — Best Practices for Key Management Organizations

- **URL:** https://csrc.nist.gov/pubs/sp/800/57/pt2/r1/final
- **Authority level:** NIST federal guidance; organizational key-management practices.
- **Claims supported:** Formal organizational responsibility, policy, lifecycle governance, and controls around cryptographic keys.
- **Outline mapping:** Hygiene.
- **Research notes:** Supporting authority for assigning an explicit owner/custodian and documented retrieval process for long-lived CA keys. Use Part 1 for certificate-inventory specifics.

### NIST SP 1800-16 — Securing Web Transactions: TLS Server Certificate Management

- **URL:** https://www.nccoe.nist.gov/publication/1800-16/VolB/index.html
- **Authority level:** NIST NCCoE practice guide; implementation-oriented guidance.
- **Claims supported:** Certificate-expiry outages are operationally common; inventories, current ownership data, replacement workflows, training, and verification that replacement certificates are actually deployed reduce risk.
- **Outline mapping:** Intro, Recovery, Hygiene.
- **Research notes:** Useful for operational language such as “monitor renewal, not merely expiry” and for validating that a renewed certificate is deployed and in use. It is general TLS guidance, not Linkerd procedure.

---

## cert-manager and automation

### cert-manager — Certificate resource

- **URL:** https://cert-manager.io/docs/usage/certificate/
- **Authority level:** Primary cert-manager documentation; normative for cert-manager configuration and behavior.
- **Claims supported:** Certificate renewal is configured through fields such as `duration`, `renewBefore`, and `renewBeforePercentage`; cert-manager records expected renewal timing in status; default renewal behavior is based on certificate lifetime; poorly chosen renewal windows can cause repeated or pathological renewal attempts.
- **Outline mapping:** Recovery, Hygiene.
- **Research notes:** Supports the precise version of “automation is not forgetfulness”: renewal has observable state, timing, and failure modes. Do not assert a universal renewal schedule without tying it to the actual configured resource/version.

### cert-manager — Prometheus Metrics

- **URL:** https://cert-manager.io/docs/devops-tips/prometheus-metrics/
- **Authority level:** Primary cert-manager documentation; operational observability reference.
- **Claims supported:** cert-manager exposes metrics for observing its components and certificate-management activity.
- **Outline mapping:** Diagnosis, Hygiene.
- **Research notes:** Supporting source for monitoring the renewal system’s health and behavior alongside certificate expiration dates. Choose alert expressions only after confirming installed cert-manager version and metric names.

---

## Real-world incidents and historical evidence

### linkerd2 issue #4808 — Replacing expired trust anchor fails

- **URL:** https://github.com/linkerd/linkerd2/issues/4808
- **Authority level:** Primary project issue record; historical anecdotal evidence, not normative documentation.
- **Claims supported:** An expired trust anchor can make routine upgrade/recovery paths materially more difficult and can surface X.509 expiry errors.
- **Outline mapping:** Intro, Triage, Recovery.
- **Research notes:** Use as a concrete historical illustration only. Pair any remediation advice with the current “Replacing expired certificates” guide.

### linkerd2 issue #4813 — Regenerate webhook TLS credentials during upgrade

- **URL:** https://github.com/linkerd/linkerd2/issues/4813
- **Authority level:** Primary project issue record; historical product-development evidence.
- **Claims supported:** Webhook TLS credentials have their own lifecycle and historically required explicit regeneration/rotation considerations.
- **Outline mapping:** Landscape, Recovery, Hygiene.
- **Research notes:** Useful background for why webhook certificates belong in the inventory. Do not treat this issue as a current runbook.

### linkerd2 issue #6200 — Identity/fail-fast problems after restarts

- **URL:** https://github.com/linkerd/linkerd2/issues/6200
- **Authority level:** Primary project issue record; historical anecdotal evidence.
- **Claims supported:** Restarts can expose an identity-issuance/control-plane problem that existing long-running workloads had not yet encountered.
- **Outline mapping:** Triage, Diagnosis.
- **Research notes:** Not a pure certificate-expiry incident. Use only to support the diagnostic pattern "old pods work; restarted/new pods fail", and explicitly avoid presenting it as proof that expiry is the cause. Our lab reproduced the same pattern for an expired issuer.

### linkerd2 discussion #7987 — Behavior after deliberately expiring certificates

- **URL:** https://github.com/linkerd/linkerd2/discussions/7987
- **Authority level:** Primary community discussion; experimental/anecdotal evidence.
- **Claims supported:** Deliberately expiring short-lived Linkerd credentials can disrupt application communication in a reproduction.
- **Outline mapping:** Intro, Triage.
- **Research notes:** A simple illustrative example, not a guarantee of exact timing or behavior across Linkerd releases/configurations. Use current documentation for all factual and recovery claims.

### linkerd2 issue #13136 — Proxies cannot refresh while the control plane is unavailable

- **URL:** https://github.com/linkerd/linkerd2/issues/13136
- **Authority level:** Primary project issue record; operator report and open feature request.
- **Claims supported:** During a long control-plane outage, proxies could not renew their certificates; the certificates eventually expired and affected pods had to be restarted.
- **Outline mapping:** Triage, Diagnosis, Hygiene.
- **Research notes:** Illustrates why the workload certificate lifetime is the tolerance for an identity-service outage. Not reproduced in our lab yet.

### linkerd2 issue #13196 — Rotating the API server's request-header CA breaks Viz tap

- **URL:** https://github.com/linkerd/linkerd2/issues/13196
- **Authority level:** Primary project issue record; operator report.
- **Claims supported:** After the Kubernetes API server's request-header client CA (used for aggregated APIs) was rotated, the tap APIService failed client-certificate verification and tap stopped working; restarting the tap pod fixed it.
- **Outline mapping:** Triage, Recovery.
- **Research notes:** A tap failure caused by a CA rotation rather than by expiry. Useful as a second cause in the tap row. Not reproduced in our lab.

---

## Unsupported or editorial claims needing evidence or clear labeling

### 90/60/30/7 escalation policy

- **Status:** Editorial organizational policy; partially anchored by product behavior.
- **What is supported:** Linkerd's checks use a 60-day certificate-validity warning threshold (see "Troubleshooting and `linkerd check`"). In our lab that warning's headline did not change as expiry approached, which is an argument for setting your own escalation windows on the expiry date or a metric.
- **What is not established by the sources above:** A universal Linkerd, Kubernetes, NIST, or cert-manager prescription for the complete sequence of 90 days / 60 days / 30 days / 7 days.
- **Recommended wording:** “Example organizational policy: begin planned maintenance at 90 days, warn at 60, require action at 30, and escalate at 7. Adapt these windows to the credential lifetime, ownership model, and change process. Linkerd itself warns at 60 days.”
- **Outline mapping:** Hygiene.

### “Hard trust-anchor replacement is the most common self-inflicted outage in this space”

- **Status:** Unsupported as written; do not state as a fact without comparative evidence.
- **What is supported:** Linkerd’s staged-rotation guidance establishes that replacing a trust anchor is a multi-step trust-bundle migration, and the expired-certificate recovery guide establishes that an expired root is disruptive.
- **Potentially supportable alternative:** Attribute a narrower claim if using a direct source. A Buoyant/CNCF statement reported in the prior research says expired certificates are “the most common reason for a production Linkerd installation to take downtime.” Before quoting or publishing it, locate the original page, confirm its wording and publication context, and attribute it directly.
- **Recommended wording now:** “A one-step root replacement can break validation mesh-wide; follow Linkerd’s staged trust-bundle rotation procedure.”
- **Outline mapping:** Hygiene.

### “Certificates are supposed to expire”

- **Status:** Editorial framing, with standards support for time-bounded validity.
- **What is supported:** RFC 5280 defines certificate validity intervals, and Linkerd documents finite validity periods for workload, issuer, trust-anchor, and webhook credentials.
- **Recommended wording:** “Certificate expiry is an expected lifecycle event; healthy systems make renewal and rotation routine.”
- **Outline mapping:** Intro, Hygiene.

### “Loss of the trust-anchor key is not immediately an outage”

- **Status:** Requires careful qualification.
- **What is supported:** Linkerd’s automation guide says Linkerd does not need access to the trust-anchor private key for its ongoing operation, while the recovery guide says an unavailable root key means root and issuer must be replaced together when recovery is required.
- **Recommended wording:** “Loss of the root key does not itself prove the currently deployed certificates are invalid, but it removes the ability to issue a replacement issuer under that root. Treat it as a lifecycle incident and plan migration while the existing trust configuration remains healthy.”
- **Outline mapping:** Recovery, Hygiene.

### “Single-proxy renewal failure is usually not a certificate-management task”

- **Status:** Useful diagnostic heuristic, not a source-backed rule. Our lab supports one specific cause.
- **What is supported:** After an expired issuer was replaced, proxies whose certificates had already expired stayed on them until their workloads were restarted (our lab). Linkerd issue #13136 reports proxies expiring during a long control-plane outage.
- **Evidence still needed:** Current Linkerd documentation or controlled tests connecting single-proxy renewal failures to identity-service reachability, clock skew, or workload authentication.
- **Recommended wording:** "A single proxy unable to renew its identity warrants investigation of the identity issuance path as well as the certificate lifecycle. If the issuer was just replaced, first check whether that workload has been restarted since."
- **Outline mapping:** Diagnosis, Recovery.

---

## Suggested citation posture for the blog post

1. Cite **Linkerd task and feature documentation** for every Linkerd operational claim and command.
2. Cite **Kubernetes documentation** when explaining webhook TLS, `caBundle`, and `failurePolicy`.
3. Cite **NIST** for inventory, ownership, key custody, monitoring, and recovery-process recommendations.
4. Cite **cert-manager documentation** for automation configuration and observability—not as proof that a given Linkerd installation is correctly configured.
5. Use **incidents** as attributed illustrations. Do not extrapolate their exact symptoms or version-specific workarounds into general claims.
6. Cite **our lab** as "in our testing", naming the Linkerd version and the shortened lifetimes, for behaviour no documentation states.
7. Cite **Linkerd's source code** for version-specific behaviour, and keep the "inference" label wherever the notes carry one.

## Maintenance log

- **2026-09-10:** Initial bibliography created from the established outline/source map. Source URLs were rechecked for availability; no commands or version-specific configuration have been copied into the blog outline.
- **2026-09-11:** Checked against the lab results and the source reading.
  - Updated the outline key to the current outline.
  - Corrected the manual-rotation, troubleshooting, admission-webhook and single-proxy entries.
  - Added this project's own evidence, and issues #13136 and #13196, which [findings.md](findings.md) cites.
