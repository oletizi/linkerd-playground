# Certificate Hygiene for Linkerd — Research Links

This is the working link index for the article. The companion [bibliography](bibliography.md) records claim-level mappings, authority, and editorial caveats.

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
