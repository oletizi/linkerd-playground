# Certificate Hygiene for Linkerd — Research Links

This is the working link index for the article. The companion [sources](../sources.md) records claim-level mappings, authority, and editorial caveats.

## Linkerd: core operations

- [Automatic mTLS](https://linkerd.io/docs/features/automatic-mtls/)
- [Replacing expired certificates](https://linkerd.io/docs/tasks/replacing_expired_certificates/)
- [Troubleshooting](https://linkerd.io/docs/tasks/troubleshooting/)
- [Automatically rotating control-plane TLS credentials](https://linkerd.io/2-edge/tasks/automatically-rotating-control-plane-tls-credentials/)
- [Manually rotating control-plane TLS credentials](https://linkerd.io/2-edge/tasks/manually-rotating-control-plane-tls-credentials/)

## Linkerd: webhook TLS

- [Rotating webhook certificates](https://linkerd.io/2-edge/tasks/rotating_webhooks_certificates/)
- [Automatically rotating webhook TLS credentials](https://linkerd.io/docs/tasks/automatically-rotating-webhook-tls-credentials/)

## Kubernetes: admission webhooks

- [Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [Admission Webhook Good Practices](https://kubernetes.io/docs/concepts/cluster-administration/admission-webhooks-good-practices/)

## Certificate and key-management guidance

- [RFC 5280: Internet X.509 PKI Certificate and CRL Profile](https://www.rfc-editor.org/rfc/rfc5280.html)
- [NIST SP 800-57 Part 1 Rev. 5: Recommendation for Key Management — General](https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-57pt1r5.pdf)
- [NIST SP 800-57 Part 2 Rev. 1: Best Practices for Key Management Organizations](https://csrc.nist.gov/pubs/sp/800/57/pt2/r1/final)
- [NIST SP 1800-16: Securing Web Transactions — TLS Server Certificate Management](https://www.nccoe.nist.gov/publication/1800-16/VolB/index.html)

## cert-manager and observability

- [Certificate resource](https://cert-manager.io/docs/usage/certificate/)
- [Prometheus metrics](https://cert-manager.io/docs/devops-tips/prometheus-metrics/)

## Historical Linkerd incidents and reproductions

- [linkerd2 #4808: Replacing expired trust anchor fails](https://github.com/linkerd/linkerd2/issues/4808)
- [linkerd2 #4813: Regenerate webhook TLS credentials during upgrade](https://github.com/linkerd/linkerd2/issues/4813)
- [linkerd2 #6200: Identity/fail-fast problems after restarts](https://github.com/linkerd/linkerd2/issues/6200)
- [linkerd2 discussion #7987: Behavior after deliberately expiring certificates](https://github.com/linkerd/linkerd2/discussions/7987)

---

## Real-world incident reading catalog

This catalog is deliberately broader than the article’s factual spine. It is a reading queue of firsthand reports from the Linkerd support forum and public GitHub trackers. A report may be incomplete, configuration-specific, or unresolved. Treat its **reported cause** and **reported resolution** as the reporter’s/maintainer’s account, not as a universal runbook; use the primary documentation above for published procedures.

### Linkerd support forum: direct operator reports

The [complete Linkerd Support Forum `certificates` tag](https://linkerd.buoyant.io/tag/certificates) is the broadest starting point and should be revisited before publication. The following threads are especially relevant to the article’s symptoms and recovery paths.

| Report | What manifested | Reported cause or working theory | Reported resolution / reading value |
| --- | --- | --- | --- |
| [Identity issuer not refreshing certificates as expected](https://linkerd.buoyant.io/t/linkerd-identity-issuer-not-refreshing-certificates-as-expected/811) | Some proxies reported expired peers and failed to obtain identity; workload-to-workload calls degraded. | After issuer rotation, some workloads appeared not to refresh for an unexpectedly long time. A maintainer later suggested an ordering problem: the trust bundle may not have been updated before issuer rotation. | Restarting the identity issuer followed by other control-plane/workload pods restored service. Strong symptom and sequencing case; root cause remains unconfirmed. |
| [Linkerd does not start when using cert-manager and trust-manager](https://linkerd.buoyant.io/t/linkerd-does-not-start-when-using-cert-manager-and-trust-manager-to-rotate-the-mtls-certs/825) | Control plane failed to start in an automated-rotation setup. | Configuration-specific report; no completed public reply. | Read as an unresolved integration case; useful reminder to validate automation in a non-production cluster. |
| [`linkerd check` fails for webhooks and APIService TLS](https://linkerd.buoyant.io/t/linkerd-check-failed-for-linkerd-webhooks-and-apisvc-tls-there-is-no-linkerd-proxy-injected-in-our-eks-cluster-pods/806) | `linkerd check` surfaced webhook/APIService TLS failure even though workloads were not injected. | Separate webhook/APIService trust relationship, not mesh workload identity. | Useful for the “which certificate landscape failed?” distinction. |
| [Certificate management with AWS Private CA Issuer](https://linkerd.buoyant.io/t/linkerd-certificate-management-with-aws-private-ca-issuer/796) | Operator sought an external/private-CA integration path. | Integration and ownership design question rather than a confirmed outage. | Good reading for non-self-signed CA deployments and boundary conditions around issuer ownership. |
| [Intermediate-CA expiry with cert-manager](https://linkerd.buoyant.io/t/security-and-operational-considerations-when-setting-intermediate-ca-cert-expiries-cert-manager/280) | Questions around expiry choices for intermediate CAs. | Certificate lifetime and rotation design. | Useful background for distinguishing a long-lived trust anchor from a more frequently rotated issuer. |
| [Trouble with trusted anchors](https://linkerd.buoyant.io/t/trouble-with-trusted-anchors-i-dont-know-where-to-look/783) | Operator could not interpret trust-anchor state. | Trust/issuer configuration and diagnostic ambiguity. | Reading for language that meets operators where they are; reinforces a clear decision tree. |
| [Linkerd cert monitoring](https://linkerd.buoyant.io/t/linkerd-cert-monitoring/775) | Operator sought certificate monitoring. | Need to observe expiry and renewal. | Direct input for the hygiene section’s monitoring guidance. |
| [`linkerd check --proxy`](https://linkerd.buoyant.io/t/linkerd-check-proxy/664) | Questions about proxy-level check results. | Diagnostic interpretation. | Useful companion to the official troubleshooting documentation. |
| [“Cert is not issued by the trust anchor” after a couple days](https://linkerd.buoyant.io/t/cert-is-not-issued-by-the-trust-anchor-error-after-a-couple-days/638) | A trust-chain error appeared after initial success. | Likely issuer/trust-bundle relationship issue; forum response should be read in full before drawing conclusions. | Valuable example that delayed failure is not necessarily a leaf-certificate expiry. |
| [Tap fails after automatic webhook TLS rotation](https://linkerd.buoyant.io/t/linkerd-tap-is-not-working-after-automatically-rotating-webhook-tls-credentials/485) | Tap functionality failed after webhook TLS automation. | Webhook/APIService credential lifecycle rather than data-plane mTLS. | Useful webhook-specific post-rotation regression case. |
| [Issuer credentials expired or not yet valid](https://linkerd.buoyant.io/t/error-failed-to-verify-issuer-credentials-for-identity-linkerd-cluster-local-with-trust-anchors-x509-certificate-has-expired-or-is-not-yet-valid/348) | Linkerd failed issuer-credential verification with an X.509 time-validity error. | Expiry/time-validity failure in issuer credentials or their chain. | Directly relevant error text for the triage table; follow the thread’s version/context before quoting a fix. |
| [Automating updates for expiring Linkerd certificates](https://linkerd.buoyant.io/t/create-a-script-that-can-automatically-update-the-needed-certifications-for-linkerd-once-they-expire/283) | Operator wanted automation after recognizing expiry risk. | Manual lifecycle management did not meet operational needs. | Useful context for recommending supported automation rather than an ad hoc expiry script. |
| [cert-manager webhook certificate renewal failure](https://linkerd.buoyant.io/t/cert-manager-webhook-certificates-renewal-failure/223) | cert-manager-managed webhook certificate renewal failed. | Automation failure in the webhook path. | A high-value example for monitoring the renewal mechanism, not only `notAfter`. |

### Linkerd GitHub: product and operator reports

| Report | What manifested | Reported cause or working theory | Reported resolution / reading value |
| --- | --- | --- | --- |
| [#15109: identity misses issuer Secret rotation](https://github.com/linkerd/linkerd2/issues/15109) | `linkerd-identity` continued using an expired issuer and stopped issuing new workload identities; mesh connectivity degraded. | Reporter observed a missed Secret update with no deterministic reproduction. A maintainer suggested, but could not confirm, a node/kubelet-level failure to refresh the mounted Secret. | Closed without a confirmed root cause. Essential example of why “the Secret changed” is not sufficient proof that the running component reloaded it. |
| [#13136: proxies cannot refresh while control plane is unavailable](https://github.com/linkerd/linkerd2/issues/13136) | During a long control-plane outage, proxies could not refresh and eventually expired; affected pods then needed restart. | The renewal schedule left insufficient recovery leeway for the outage duration. | Open feature request to expose proxy identity-refresh tuning. Strong evidence for monitoring identity/control-plane availability alongside certificate dates. |
| [#13613: automatic trust-anchor rotation requires reloads](https://github.com/linkerd/linkerd2/issues/13613) | A trust-manager bundle update was not consumed automatically by Linkerd components/workloads. | Trust roots appeared to be read at process start. | Open request; reporter expected control-plane and workload restarts. Read with the documented staged root-rotation procedure. |
| [#13196: extension API-server CA rotation breaks Viz tap](https://github.com/linkerd/linkerd2/issues/13196) | After `requestheader-client-ca-file` rotation, the tap APIService logged client-certificate verification failures and stopped working. | Tap did not consume the rotated ConfigMap CA. | Restarting the tap pod fixed the report. Good example of an APIService certificate relationship distinct from mesh identity. |
| [#13361: automatic webhook TLS generation and GitOps drift](https://github.com/linkerd/linkerd2/issues/13361) | A fresh install passed checks, but the proxy-injector webhook check failed after a day. | The reporter’s GitOps reconciler was overwriting/generated webhook Secrets or webhook configuration. | Reporter resolved it by configuring GitOps ignore-differences for generated webhook TLS Secret data and webhook configuration. Excellent “automation fighting automation” case. |
| [#11972: cert-manager issuer cannot initialize](https://github.com/linkerd/linkerd2/issues/11972) | Linkerd control-plane deployment was blocked by cert-manager issuer errors about expected Secret data. | Certificate/Secret format or configuration mismatch. | Reporter later confirmed a configuration fix, without publishing the exact correction. Use to flag Secret schema/type validation early in setup. |
| [#9622: incomplete issuer-only renewal documentation](https://github.com/linkerd/linkerd2/issues/9622) | Operator identified a gap in guidance for renewing an issuer without rotating the trust anchor. | Documentation/operational-procedure ambiguity. | Open. Read to understand why root rotation and issuer rotation should not be collapsed into one recovery story. |
| [#4808: replacing expired trust anchor fails](https://github.com/linkerd/linkerd2/issues/4808) | An expired trust anchor complicated the normal upgrade/recovery route. | Root already expired. | Historical evidence that recovery after root expiry is qualitatively harder than planned rotation. Use current recovery docs for instructions. |
| [#4813: regenerate webhook TLS credentials during upgrade](https://github.com/linkerd/linkerd2/issues/4813) | Webhook credentials required lifecycle handling during upgrades. | Historical product lifecycle limitation. | Context for why webhook certificates need ownership and renewal planning; not a current runbook. |
| [#6200: identity/fail-fast problems after restarts](https://github.com/linkerd/linkerd2/issues/6200) | Existing workloads had operated, while restarted/new workloads exposed an identity path failure. | Not a pure expiry incident. | Keep as a diagnostic analogue: “old pods work, new ones do not” points toward issuance/identity path investigation, not proof of expiry. |

### cert-manager GitHub: automation failure modes that transfer to Linkerd deployments

| Report | What manifested | Reported cause or working theory | Reported resolution / reading value |
| --- | --- | --- | --- |
| [#7617: cert-manager webhook fails to renew its own certificate](https://github.com/cert-manager/cert-manager/issues/7617) | cert-manager’s webhook pod could not renew its own certificate and became unavailable. | Self-hosted webhook certificate lifecycle failure. | Reporter’s immediate workaround was deleting the certificate Secret; issue was later closed as fixed. Good reminder that the certificate manager itself has serving credentials. |
| [#7895: expired certificate still reports `Ready=True`](https://github.com/cert-manager/cert-manager/issues/7895) | Site TLS was broken; the Certificate resource still showed Ready and “has not expired,” while `notAfter` was past. | Renewal was in progress/failed without state expressing the operational reality clearly. | Open report. Strong reason to alert on actual expiry/renewal state and deployed behavior, not a single friendly status field. |
| [#8847: certificate stuck in failed renewal](https://github.com/cert-manager/cert-manager/issues/8847) | An ACME challenge failure left an Order pending for more than 24 hours during renewal. | Issuance dependency/challenge failure. | Open report. Relevant as a generic “automation can stall” pattern, though it is not a Linkerd identity-CA example. |
| [#5864: leaf outlives its issuing CA](https://github.com/cert-manager/cert-manager/issues/5864) | cert-manager allowed a leaf certificate with a later `NotAfter` than its intermediate CA. | Duration configuration did not enforce issuer-chain lifetime. | Open report. Very relevant to choosing issuer and leaf lifetimes: leaf monitoring alone cannot establish a valid chain. |
| [#2478: CA issuer Secret rotation](https://github.com/cert-manager/cert-manager/issues/2478) | A CA issuer’s own certificate rotation risked breaking everything trusting its issued certificates. | A one-step CA Secret replacement offers no trust-overlap period. | Feature request proposes overlapping trusted CA material before switching signing. Excellent general explanation of the “old + new trust bundle” pattern. |
| [#6815: Secret not refreshed after critical configuration change](https://github.com/cert-manager/cert-manager/issues/6815) | Changes to Secret template/keystore settings were not reflected until renewal. | Update triggers did not cover every referenced input. | Closed but later commenters reported similar behavior. Useful broader evidence that declarative configuration changes may not imply immediate credential/consumer refresh. |

### Kubernetes GitHub: control-plane and webhook analogues

These cases are not Linkerd incidents. They are included because Linkerd’s admission webhooks and APIService integrations live in the same Kubernetes TLS and process-reload world.

| Report | What manifested | Reported cause or working theory | Reported resolution / reading value |
| --- | --- | --- | --- |
| [#98310: renewed kubeadm certificates still needed restarts](https://github.com/kubernetes/kubernetes/issues/98310) | Certificate expiry errors occurred after the scheduled expiry despite `check-expiration` showing renewal had completed. | API servers still had old certificates loaded. | Restarting API servers fixed the report; maintainer pointed out the renewal command’s restart note. Strong general “renewed on disk ≠ active in memory” example. |
| [#86552: API-server loopback certificate expires after a year](https://github.com/kubernetes/kubernetes/issues/86552) | A long-running API server became unhealthy around certificate expiry, with TLS handshake errors. | In-memory loopback client/server certificate was not renewed/reloaded. | Closed; read as a stale-process analogue, not a Linkerd-specific incident. |
| [#102556: unable to renew an expired certificate](https://github.com/kubernetes/kubernetes/issues/102556) | Control plane was broken and kubelet initialization was stuck; `kubeadm certs check-expiration` appeared healthy. | An expired kubelet client credential was outside the inspected/renewed set. | Reporter recovered it; maintainer suggested documenting kubelet-client recovery. Good warning against a single inventory/check view. |
| [#102283: recreating PKI after CA expiry leaves nodes unauthorized](https://github.com/kubernetes/kubernetes/issues/102283) | Recreating PKI/kubeconfigs restored some API access but nodes remained `Unauthorized`/`NotReady`. | Replacing an expired CA as a one-step recovery broke trust across dependent credentials. | Maintainer directed readers to the manual CA rotation guidance. Strong analogue for staged trust migration rather than wholesale CA replacement. |
| [#96256: kubelet rotation fails when server is unreachable](https://github.com/kubernetes/kubernetes/issues/96256) | The active kubelet client certificate expired while the server was unavailable, preventing normal renewal. | Renewal depended on access to a control-plane service that was unavailable after expiry. | Closed as support. Good circular-dependency analogue: a component may need the still-valid credential to obtain its replacement. |
| [#110530: validating webhook PKI fails after algorithm policy change](https://github.com/kubernetes/kubernetes/issues/110530) | A fail-closed validating webhook rejected requests after Kubernetes/Go rejected SHA-1-signed certificate chains. | Cryptographic algorithm became unacceptable, even though this was not a time-expiry event. | Fixed by [#110551](https://github.com/kubernetes/kubernetes/pull/110551). Important caveat: X.509-looking failures are not always expiry failures. |
| [#102013: CR creation fails after webhook appears ready](https://github.com/kubernetes/kubernetes/issues/102013) | API requests to create custom resources failed with webhook connection-refused errors shortly after deployment. | Readiness/routing timing gap. | Historical report; useful triage reminder that admission failure can be availability/routing, not TLS. |
| [#120890: expiry errors after kubeadm renewal](https://github.com/kubernetes/kubernetes/issues/120890) | API-server logs still reported an expired credential after `renew all`. | Setup-specific; issue closed as support rather than confirmed product bug. | Include as a cautionary read: identify *which* certificate is in the error before assuming the command renewed it. |
| [#118944: manual rotation after certificate expiry fails](https://github.com/kubernetes/kubernetes/issues/118944) | Cluster became inaccessible after a year; manual CA/certificate recovery was attempted with mixed results. | Expired CA and manual recovery complexity. | Closed as support. Useful contrast between planned rotation and emergency recovery. |

### Search trails for continued reading

- [All Linkerd issues mentioning certificates](https://github.com/linkerd/linkerd2/issues?q=is%3Aissue+certificate)
- [All Linkerd discussions in the repository](https://github.com/linkerd/linkerd2/discussions)
- [cert-manager issues mentioning renewal](https://github.com/cert-manager/cert-manager/issues?q=is%3Aissue+renewal)
- [Kubernetes issues mentioning webhook certificates](https://github.com/kubernetes/kubernetes/issues?q=is%3Aissue+%22webhook+certificate%22)
- [Kubernetes manual CA rotation guidance](https://kubernetes.io/docs/tasks/tls/manual-rotation-of-ca-certificates/)
