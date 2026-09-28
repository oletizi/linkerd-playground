# Linkerd certificate behavior: research for expiry demos

Research date: 2026-09-10. All source reads are pinned to:

- linkerd/linkerd2 tag `edge-26.9.1` = commit `2946a07088e182f0bf86626045c8f129176b329d`
  (base: `L2 = https://github.com/linkerd/linkerd2/blob/2946a07088e182f0bf86626045c8f129176b329d/`)
- linkerd/linkerd2-proxy `main` = commit `a66af8117769df060adda6233302a2d1c4142229` (2026-09-01). edge-26.9.1 ships proxy v2.368.0. I read proxy `main` from three days before the release, not the v2.368.0 tag. The identity and TLS code quoted here is stable, so drift is unlikely, but I did not diff against the tag.
  (base: `PX = https://github.com/linkerd/linkerd2-proxy/blob/a66af8117769df060adda6233302a2d1c4142229/`)
- linkerd/linkerd-kubert tag `kubert/v0.27.0` (the version the policy-controller pins in `Cargo.lock`)

Labels: **VERIFIED** means I read it in source or docs. **INFERRED** means it is my reasoning from verified pieces.

---

## 1. Versions, install path, Gateway API

- **VERIFIED**: The latest edge is **edge-26.9.1**, published **2026-09-04T23:14:08Z**. The one before it is edge-26.8.4 (2026-08-25). Source: `gh release list -R linkerd/linkerd2`, https://github.com/linkerd/linkerd2/releases/tag/edge-26.9.1. Its release notes have no cert or identity changes: proxy bumps v2.367.0/v2.368.0, a multicluster exec-auth fix, a destination IP-conflict fix, and dependency bumps.
- **VERIFIED**: `curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install-edge | sh` is current. The script contains `LINKERD2_VERSION=${LINKERD2_VERSION:-edge-26.9.1}`, so `LINKERD2_VERSION=edge-26.9.1` pins it explicitly. The script handles Darwin `arm64` (downloads `-darwin-arm64`). Release assets include `linkerd2-cli-edge-26.9.1-darwin-arm64` and `-linux-arm64`.
- Gateway API: the sources disagree, so pin explicitly.
  - **VERIFIED**: The install-edge script's post-install hint says `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml`.
  - **VERIFIED**: The CLI's own error text says `kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml` (`GatewayAPICRDsMissingError`, L2 `pkg/healthcheck/healthcheck.go` ~L2271).
  - **VERIFIED**: The hard code minimum is that `httproutes` and `grpcroutes.gateway.networking.k8s.io` must serve `v1`: "please upgrade to Gateway API v1.1.1 or later" (`CheckGatewayAPICRDs`, healthcheck.go ~L2233-2256). The `gateway-api-crd` check category runs in `linkerd check` (cli/cmd/check.go ~L139-143). `linkerd install` errors with `GatewayAPICRDsMissingError` when the CRDs are absent and `installGatewayAPI` is false (cli/cmd/install.go ~L362-386).
  - **VERIFIED (docs)**: The Gateway API page for edge lists supported Gateway API **1.2.1 - 1.5.1** and gives the v1.5.1 standard-install URL. https://linkerd.io/2-edge/features/gateway-api/
  - **VERIFIED**: The `linkerd-crds` chart can install its own bundled Gateway API CRDs with `installGatewayAPI: true` (default `false`). The bundled HTTPRoute is annotated `gateway.networking.k8s.io/bundle-version: v1.1.1` (L2 `charts/linkerd-crds/values.yaml`, `charts/linkerd-crds/templates/gateway.networking.k8s.io_httproutes.yaml`).
  - **INFERRED recommendation**: For a disposable cluster, use `kubectl apply --server-side -f .../v1.5.1/standard-install.yaml`. It matches the CLI's own instruction and the docs' upper bound.

## 2. Workload (leaf) certificate lifetime and proxy refresh

- **VERIFIED**: Helm values and defaults (L2 `charts/linkerd-control-plane/values.yaml` L472-479):
  - `identity.issuer.issuanceLifetime: 24h0m0s`
  - `identity.issuer.clockSkewAllowance: 20s`
- **VERIFIED**: The CLI exposes these as `--identity-issuance-lifetime` and `--identity-clock-skew-allowance`, both duration flags (L2 `cli/cmd/options.go` L103-113). `--set identity.issuer.issuanceLifetime=2m` also works.
- **VERIFIED**: The chart passes them as `-identity-issuance-lifetime=` and `-identity-clock-skew-allowance=` args (L2 `charts/linkerd-control-plane/templates/identity.yaml` L167-168).
- **VERIFIED: there is no minimum-value validation.** The identity controller runs `time.ParseDuration`. On a parse error it logs `Invalid issuance lifetime: ...` and **silently falls back to 24h** (`identity.DefaultIssuanceLifetime`). Same for clock skew: it warns and falls back to `tls.DefaultClockSkewAllowance` = 10s. See L2 `controller/cmd/identity/main.go` L104-123 and `pkg/tls/ca.go` L71-88. The CLI's `validateValues` never checks the lifetime (options.go ~L490-545), and the chart has no `values.schema.json`.
- **VERIFIED: the leaf validity window.** `Validity.Window` sets `NotBefore = now - skew` and `NotAfter = now + lifetime + skew` (L2 `pkg/tls/ca.go` L284-296). So `issuanceLifetime=1m` with the default 20s skew gives leaves roughly 80s of remaining validity at issuance.
- **VERIFIED: leaves are clamped to the issuer's expiry.** `CA.createTemplate` clamps `NotAfter` to `firstCrtExpiration`, the earliest `NotAfter` among the issuer cert and any certs in its `TrustChain` (L2 `pkg/tls/ca.go` L90-105, L228-240). **INFERRED**: `crt.pem` normally holds only the issuer, so the clamp is effectively "never outlive the issuer", not "never outlive the trust anchor".
- **VERIFIED: the proxy refreshes at 70% of the *remaining* lifetime, clamped to `[min_refresh, max_refresh]`.** Source: PX `linkerd/proxy/identity-client/src/certify.rs` L188-203 (`.map(|d| d * 7 / 10) // 70% duration`). If the current cert is already expired, or certification failed with no prior expiry, it waits `min_refresh` (L198). A failed certify keeps the old credentials (L118-126, `error!(error, "Failed to obtain identity")`). The proxy rejects a returned cert that is already expired (`"certificate already expired"`, L175-177).
- **VERIFIED: defaults** `DEFAULT_IDENTITY_MIN_REFRESH = 10s` and `DEFAULT_IDENTITY_MAX_REFRESH = 24h` (PX `linkerd/app/src/env.rs` L365-366).
- **VERIFIED: configurable** through the env vars `LINKERD2_PROXY_IDENTITY_MIN_REFRESH` and `LINKERD2_PROXY_IDENTITY_MAX_REFRESH` (PX `linkerd/app/src/env.rs` L219-220, `linkerd/app/src/env/identity.rs` L96-104). The chart does not template them. You can inject them with Helm `proxy.additionalEnv` or the workload/namespace annotation `config.linkerd.io/proxy-additional-env` (a JSON list of EnvVar, merged by name: Helm < namespace < workload). Source: L2 `pkg/k8s/labels.go` L125, L330-338; `charts/partials/templates/_proxy.tpl` L243-247.
- **VERIFIED: proxy identity metric stems** are `expiration_timestamp`, `refresh_timestamp`, and `refreshes` (PX `linkerd/identity/src/metrics.rs` L27-52). **INFERRED**: they are exported under an `identity_cert_` prefix (for example `identity_cert_expiration_timestamp_seconds`). Check on a live proxy's `:4191/metrics`.

## 3. Issuer expiry behavior

**At identity controller startup with an expired issuer: fatal exit, then CrashLoopBackOff.**
- **VERIFIED**: `svc.Initialize()` calls `loadCredentials()`, which calls `creds.Crt.Verify(svc.trustAnchors, "", time.Time{})`. On error it returns `failed to verify issuer credentials for '%s' with trust anchors: %w`. `main` then calls `log.Fatalf("Failed to initialize identity service: %s", err)`. Sources: L2 `pkg/identity/service.go` L81-88 and L125-154; `controller/cmd/identity/main.go` L184-188.
- **VERIFIED**: `Crt.Verify` treats a zero time as "now" and decorates expiry errors as `%w - Current Time : ... - Invalid before ... - Invalid After ...` (L2 `pkg/tls/cred.go` L88-104).
- **INFERRED expected log line**: `Failed to initialize identity service: failed to verify issuer credentials for 'identity.linkerd.cluster.local' with trust anchors: x509: certificate has expired or is not yet valid: current time ... is after ... - Current Time : ... - Invalid before ... - Invalid After ...`.
- **VERIFIED**: The issuer must also be a CA, or it fails with `it must be an intermediate-CA, but it is not` (service.go L140-142).

**When the issuer expires while identity is running: it refuses to sign. No crash, no reload.**
- **VERIFIED**: Every `Certify` RPC calls `ensureIssuerStillValid()`, which verifies the issuer chain against the anchors at the current time. On failure it logs `could not process CSR because of CA cert validation failure: <err> - CSR Identity : <id>`, records a **Warning event `IssuerValidationFailed`**, and returns the error (a raw error, not a gRPC status). It never produces a leaf chained to an expired intermediate. Source: L2 `pkg/identity/service.go` L198-232.
- **VERIFIED**: The identity process stays up. `ready` stays true and the gRPC server keeps serving (main.go L189-216).
- **VERIFIED**: Identity exposes the gauge `issuer_cert_ttl_seconds` ("The remaining seconds until the issuer certificate expires") on its admin server (`:9990`). It goes negative after expiry. A matching trust-anchor metric is a `TODO` in the source. See service.go L156-171.
- **INFERRED**: Clamping and 70% refresh interact near issuer expiry. Leaves expire exactly when the issuer does, and proxies refresh ever more often (down to the 10s floor) as expiry approaches. After expiry each proxy retries every 10s, and each retry adds an `IssuerValidationFailed` event, so expect event spam.

**It does watch and reload the issuer Secret.**
- **VERIFIED**: `tls.NewFsCredsWatcher(*issuerPath, ...)` watches the mounted directory `/var/run/linkerd/identity/issuer`, a Secret volume from `linkerd-identity-issuer` with no `subPath`. It fires on the kubelet's atomic `..data` symlink create. Sources: L2 `controller/cmd/identity/main.go` L126-138; `pkg/tls/creds_watcher.go` L37-74; `charts/linkerd-control-plane/templates/identity.yaml` L224-225, L265-267.
- **VERIFIED**: On a change, `Run()` calls `Initialize()` again. On success it records Normal event `IssuerUpdated` ("Updated identity issuer"). On failure (for example, the new cert is also expired or doesn't chain to the anchors) it records Warning `IssuerUpdateSkipped` ("Skipping issuer update as certs could not be read from disk: ...") and **keeps the old issuer**. Source: service.go L105-123.
- **VERIFIED**: The trust anchors themselves are read once at startup (`os.ReadFile(k8s.MountPathTrustRootsPEM)`, main.go L68-71, L98-102). The identity controller only picks up a changed `linkerd-identity-trust-roots` ConfigMap after a restart.
- **INFERRED**: Kubelet propagation delay for Secret volume updates (sync period plus cache TTL, typically tens of seconds to about a minute) sits between `kubectl apply` and the reload. Budget for it in demo timing. See https://kubernetes.io/docs/concepts/configuration/secret/

**Does `linkerd install` / `linkerd upgrade` refuse a near-expiry issuer or anchor? No. It refuses only certs that are already expired or not yet valid.**
- **VERIFIED**: `validateValues` calls `IssuerCertData.VerifyAndBuildCreds()` (L2 `cli/cmd/options.go` L519-541) for both `linkerd.io/tls` and external (`kubernetes.io/tls`) schemes. `VerifyAndBuildCreds` checks, in order (L2 `pkg/issuercerts/issuercerts.go` L117-127, L205-236):
  - `CheckCertValidityPeriod`: not before `NotBefore`, not after `NotAfter`
  - ECDSA P-256 algorithm
  - `IsCA`
  - chain verify against the anchors at now

  There is **no minimum remaining validity**. A 10-minute issuer or anchor passes. **INFERRED**: Go's x509 verification checks the validity of roots as well as intermediates (`isValid` is called for `rootCertificate` candidates; https://github.com/golang/go/blob/master/src/crypto/x509/verify.go ~L449-479, L759). So `linkerd install` **rejects an already-expired trust anchor**, not only an expired issuer.
- **VERIFIED**: `linkerd upgrade` runs the same `validateValues`. Without `--force` it also runs `ensureIssuerCertWorksWithAllProxies`, which verifies the (possibly new) issuer against each meshed pod's injected trust bundle. It fails with "You are attempting to use an issuer certificate which does not validate against the trust anchors of the following pods ... Use the --force flag to proceed anyway". Source: L2 `cli/cmd/upgrade.go` L234-240, L307-343.
- **VERIFIED**: A **Helm** install does no validity checking. It only runs `required` on `crtPEM`/`keyPEM`/`identityTrustAnchorsPEM` (identity.yaml L19-20; `_proxy.tpl` L217). **INFERRED**: an expired issuer delivered via Helm installs cleanly, and then identity crashloops. This is the cleanest way to demo the startup failure.
- **VERIFIED, useful side fact**: If `linkerd install` gets no certs, it generates **one self-signed root used as both trust anchor and issuer**, with `Validity{}`, meaning `DefaultLifetime` = 365 days. Sources: L2 `cli/cmd/options.go` L660-669; `pkg/tls/ca.go` L71-77, L149-158.

## 4. Trust anchor distribution and expiry

- **VERIFIED: how proxies get the bundle.** Injected (non-control-plane) proxies get `LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS` as a literal env value baked into the pod spec at injection time. The proxy-injector re-reads `/var/run/linkerd/identity/trust-roots/ca-bundle.crt` (a mount of ConfigMap `linkerd-identity-trust-roots`) **on every admission request** and overrides `IdentityTrustAnchorsPEM` with it. Control-plane pods instead use `valueFrom.configMapKeyRef` on `linkerd-identity-trust-roots`/`ca-bundle.crt` when `proxy.loadTrustBundleFromConfigMap` is set. Sources: L2 `charts/partials/templates/_proxy.tpl` L204-218; `controller/proxy-injector/webhook.go` L43-52; `charts/linkerd-control-plane/templates/identity.yaml` L27-36. Pods carry an annotation `linkerd.io/trust-root-sha256` (`_metadata.tpl` L8).
- **VERIFIED: it is not re-read without a restart.** The proxy parses the env var once at startup (PX `linkerd/app/src/env/identity.rs` L131-137) and builds a static `RootCertStore` (PX `linkerd/meshtls/src/creds.rs` L20-52). Env vars are immutable for a running container, and ConfigMap-sourced env vars are also resolved only at container start. **INFERRED**: rotating the bundle requires rolling every meshed workload. `linkerd check --proxy` flags pods whose bundle text differs from the ConfigMap ("Some pods do not have the current trust bundle and must be restarted"; L2 healthcheck.go L2362-2393).
- **Proxy behavior with an expired trust anchor:**
  - **VERIFIED**: The proxy loads roots with `add_parsable_certificates` and does no expiry check on the roots (creds.rs L40-46).
  - **VERIFIED**: rustls/webpki reduces a root to a `TrustAnchor { subject, subject_public_key_info, name_constraints }`, which has **no validity fields** (https://docs.rs/rustls-pki-types/latest/rustls_pki_types/struct.TrustAnchor.html).
  - **VERIFIED**: Peer verification (`AnySanVerifier` wrapping `verify_server_cert_signed_by_trust_anchor`) and self-validation in `Store::set_certificate` check the leaf and intermediates against `now` (PX `linkerd/meshtls/src/creds/verify.rs` L37-64; `creds/store.rs` L107-163).
  - **INFERRED (important)**: **an expired trust anchor does not by itself break data-plane mTLS between running proxies.** Handshakes keep working while the leaf and issuer are still valid.
  - **INFERRED**: The failure surfaces through the **identity controller**. Go's x509 does check root validity, so after anchor expiry every `Certify` fails `ensureIssuerStillValid` (`IssuerValidationFailed`), and a restarted identity pod crashloops. Proxies then can't renew. mTLS breaks when each proxy's current leaf expires, which is up to `issuanceLifetime` (+skew) after the anchor expires.
  - **INFERRED**: The time from anchor expiry to visible breakage equals the remaining leaf lifetime. With the default 24h that is long; with `issuanceLifetime=2m` it is fast.
- **VERIFIED**: New pods never become Ready while identity can't issue. The proxy waits on `identity.ready()` before serving inbound or outbound traffic (PX `linkerd/app/src/lib.rs` L271-287; `linkerd/app/src/identity.rs` L160-169).

## 5. Webhook serving certificates

| Component | Helm prefix | Secret (namespace) | Mounted by |
|---|---|---|---|
| proxy-injector | `proxyInjector.*` | `linkerd-proxy-injector-k8s-tls` (linkerd) | proxy-injector deployment |
| sp-validator | `profileValidator.*` (note the name) | `linkerd-sp-validator-k8s-tls` (linkerd) | `sp-validator` container in linkerd-destination (`/var/run/linkerd/tls`) |
| policy-validator | `policyValidator.*` | `linkerd-policy-validator-k8s-tls` (linkerd) | `policy` container in linkerd-destination (`--server-tls-key/--server-tls-certs=/var/run/linkerd/tls/...`) |
| viz tap APIService | `tap.*` | `tap-k8s-tls` (linkerd-viz) | tap deployment |
| viz tap-injector | `tapInjector.*` | `tap-injector-k8s-tls` (linkerd-viz) | tap-injector deployment |

- **VERIFIED: the per-component values** are `externalSecret` (bool; skip creating the Secret), `crtPEM`, `keyPEM`, `caBundle`, `injectCaFrom` (cert-manager `Certificate` ref), and `injectCaFromSecret` (cert-manager direct injection from a Secret with `ca.crt`). Sources: L2 `charts/linkerd-control-plane/values.yaml` L511-675; `viz/charts/linkerd-viz/values.yaml` L154-209 (tap), L248-339 (tapInjector). The `linkerd.webhook.validation` partial fails the render when both `injectCaFrom` and `injectCaFromSecret` are set, when either is set together with `caBundle`, or when `externalSecret` is set with none of the three (L2 `charts/partials/templates/_validate.tpl`). The docs list the same Secret names and use cert-manager `duration: 24h`, `renewBefore: 1h`. https://linkerd.io/2-edge/tasks/automatically-rotating-webhook-tls-credentials/
- **VERIFIED: the self-generated certs are hard-coded to 365 days** via `genSelfSignedCert $host (list) (list $host) 365`, and no value changes it. The cert is self-signed, so the same cert serves as both server cert and `caBundle`. Sources: L2 `proxy-injector-rbac.yaml` L59-60; `destination-rbac.yaml` L66-67, L125-126; viz `tap-injector-rbac.yaml` L43-44; `tap-rbac.yaml` L105-106.
- **Making them short-lived requires supplying your own.** Either set `crtPEM`+`keyPEM`+`caBundle` (for example a `step`/`openssl` cert with a few minutes' validity), or set `externalSecret=true` plus `caBundle` or cert-manager injection.
  - **VERIFIED gotcha**: The template picks `caBundle` as `empty(.caBundle) ? $ca.Cert : .caBundle`. If you set `crtPEM`/`keyPEM` and forget `caBundle`, the webhook's `caBundle` becomes a *different, freshly generated* self-signed cert, and the API server can never verify your server cert.
- **INFERRED**: `genSelfSignedCert` runs on every render and the templates use no `lookup`. So each `linkerd upgrade` / `helm upgrade` / `linkerd viz install` re-render issues brand-new webhook certs and caBundles. That is an implicit rotation.
- **Reload without restart: yes, for all five.**
  - **VERIFIED**: proxy-injector, sp-validator, and tap-injector all use `webhook.Launch` → `webhook.NewServer`. `NewServer` runs `FsCredsWatcher` on the TLS mount (fsnotify on `..data`) and serves through `TLSConfig.GetCertificate` from an `atomic.Value` that `ProcessEvents`/`UpdateCert` refreshes. Sources: L2 `controller/webhook/server.go` L45-106; `controller/cmd/proxy-injector/main.go` L25; `controller/cmd/sp-validator/main.go` L22; `viz/tap/injector/main.go` L22. On a bad new cert it logs `Skipping update as cert could not be read from disk` and keeps the old one (`pkg/tls/creds_watcher.go` L93-111).
  - **VERIFIED**: The tap API server has the same watcher pattern (L2 `viz/tap/api/server.go` L47-113).
  - **VERIFIED**: policy-validator uses kubert's server, which "reloads its TLS credentials for each connection to support certificate rotation" (`linkerd-kubert` `kubert/src/server.rs` at `kubert/v0.27.0`, header doc and `serve_conn` ~L278-287: `// Reload the TLS credentials for each connection.`).
  - **VERIFIED**: The server loads the cert without checking its dates. **INFERRED**: an *expired* serving cert still gets served; the failure shows up at the API server's TLS verification, not in the webhook server.

## 6. failurePolicy, selectors, rules

Global value: `webhookFailurePolicy: Ignore` (L2 values.yaml L415-416). **VERIFIED**. The Kubernetes default when the field is unset is `Fail`: "`Ignore` means that an error calling the webhook is ignored" (https://kubernetes.io/docs/reference/kubernetes-api/extend-resources/validating-webhook-configuration-v1/). TLS and connection errors count as call errors (https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/).

| Webhook (config name) | failurePolicy | namespaceSelector (default) | objectSelector | Rules | timeout |
|---|---|---|---|---|---|
| `linkerd-proxy-injector-webhook-config` (Mutating) | `{{webhookFailurePolicy}}` = Ignore | `config.linkerd.io/admission-webhooks NotIn [disabled]`; `kubernetes.io/metadata.name NotIn [kube-system, cert-manager]` | `linkerd.io/control-plane-component DoesNotExist`; `linkerd.io/cni-resource DoesNotExist` | CREATE; `""/v1` `pods`, `services`; Namespaced | `proxyInjector.timeoutSeconds` = 10 |
| `linkerd-sp-validator-webhook-config` (Validating) | Ignore (same global value) | `config.linkerd.io/admission-webhooks NotIn [disabled]` | none | CREATE, UPDATE; `linkerd.io` v1alpha1/v1alpha2 `serviceprofiles` | unset (K8s default 10s) |
| `linkerd-policy-validator-webhook-config` (Validating) | Ignore (same global value) | `config.linkerd.io/admission-webhooks NotIn [disabled]` | none | CREATE, UPDATE; `policy.linkerd.io/*`: authorizationpolicies, httplocalratelimitpolicies, httproutes, networkauthentications, meshtlsauthentications, serverauthorizations, servers, egressnetworks; `gateway.networking.k8s.io/*`: httproutes, grpcroutes, tlsroutes, tcproutes | unset (10s) |
| `linkerd-tap-injector-webhook-config` (Mutating) | `tapInjector.failurePolicy` = Ignore | `kubernetes.io/metadata.name NotIn [kube-system]` | none by default | CREATE; `""/v1` `pods`; Namespaced; `reinvocationPolicy: IfNeeded` | unset (10s) |

Sources (**VERIFIED**): L2 `charts/linkerd-control-plane/templates/proxy-injector-rbac.yaml` L80-120; `destination-rbac.yaml` L87-198; `viz/charts/linkerd-viz/templates/tap-injector-rbac.yaml` L63-106; `viz/charts/linkerd-viz/values.yaml` L270-284.

**Tap APIService** `v1alpha1.tap.linkerd.io` (**VERIFIED**, viz `tap-rbac.yaml` L104-153): `group: tap.linkerd.io`, `version: v1alpha1`, `service: tap/<viz ns>`, `groupPriorityMinimum: 1000`, `versionPriority: 100`. `caBundle` comes from `tap.caBundle` or the generated 365-day self-signed cert, and is omitted when `tap.injectCaFrom`/`injectCaFromSecret` are set (cert-manager annotations instead). There is no `insecureSkipTLSVerify`. The serving cert is Secret `tap-k8s-tls`.
**INFERRED**: An expired tap cert makes the aggregator mark the APIService `Available=False` (FailedDiscoveryCheck), so `linkerd viz tap` fails. Unavailable aggregated APIs are also known to cause discovery errors in `kubectl` and can stall namespace deletion. This is generic kube-aggregator behavior, not Linkerd-specific.

## 7. `linkerd check` certificate checks

All **VERIFIED** from L2 `pkg/healthcheck/healthcheck.go` L964-1202 and `cli/cmd/check.go` L159-181.

**Category `linkerd-identity`:**
- `certificate config is valid` (fatal). Fetches the issuer Secret per scheme and parses it.
- `trust anchors are using supported crypto algorithm` (fatal)
- `trust anchors are within their validity period` (fatal). Error: `Invalid anchors: * <serial> <CN> not valid anymore. Expired on <RFC3339>`.
- `trust anchors are valid for at least 60 days` (warning)
- `issuer cert is using supported crypto algorithm` (fatal)
- `issuer cert is within its validity period` (fatal). Error: `issuer certificate is not valid anymore. Expired on ...`.
- `issuer cert is valid for at least 60 days` (warning)
- `issuer cert is issued by the trust anchor`

The 60-day threshold is `expirationWarningThresholdInDays = 60` (`pkg/issuercerts/issuercerts.go` L22, L129-135) and is not configurable.

**Category `linkerd-webhooks-and-apisvc-tls`:**
- `proxy-injector webhook has valid cert` (fatal)
- `proxy-injector cert is valid for at least 60 days` (warning)
- `sp-validator webhook has valid cert` (fatal)
- `sp-validator cert is valid for at least 60 days` (warning)
- `policy-validator webhook has valid cert` (fatal; skipped if not installed)
- `policy-validator cert is valid for at least 60 days` (warning)

How the fatal checks work (`CheckCertAndAnchors`, L1496-1519): the webhook config's `caBundle` is treated as the anchors, and the Secret's cert is checked for validity and verified against those anchors for the name `<svc>.<ns>.svc`.

**Viz (`linkerd viz check`, category `linkerd-viz`)**, from L2 `viz/pkg/healthcheck/healthcheck.go` L156-192:
- `tap API server has valid cert` (fatal)
- `tap API server cert is valid for at least 60 days` (warning)
- `tap API service is running` (warning)

There is **no tap-injector cert check**.

**`linkerd check --proxy`** (`dataPlaneOnly`) adds `linkerd-data-plane`, `linkerd-identity-data-plane` (`data plane proxies certificate match CA`, a warning), and `linkerd-opaque-ports-definition`. Without `--proxy`, the check runs `linkerd-control-plane-version` and `linkerd-extension-checks` instead. The data-plane identity check only compares each pod's injected trust-anchor PEM text against `linkerd-identity-trust-roots` (L2362-2393). **It never inspects proxies' leaf certificates or their expiry.** Docs on the expired-cert symptom text: https://linkerd.io/2-edge/tasks/replacing_expired_certificates/

**INFERRED gaps worth stating in the article:**
- No check looks at leaf certs.
- The tap-injector cert is not checked.
- Nothing verifies that the webhook Secret cert and the API server's `caBundle` stay in sync over time, except by re-running the check.
- Any short-lived demo cert will trigger the 60-day warnings immediately, so the checks can't tell "10 minutes left" from "59 days left".

## 8. kind on arm64 (Apple Silicon / OrbStack Docker)

- **VERIFIED**: Linkerd images are built multi-arch by default: `SUPPORTED_ARCHS=${SUPPORTED_ARCHS:-linux/amd64,linux/arm64}` (L2 `bin/_docker.sh` L29, L73). The darwin-arm64 and linux-arm64 CLI assets exist for edge-26.9.1.
- **VERIFIED**: `proxyInit.iptablesMode` defaults to `"nft"` and `runAsRoot: false` (L2 values.yaml L332, L359-361).
- **VERIFIED**: A `gh search issues` of linkerd/linkerd2 for "kind arm64", "apple silicon", and "orbstack" returned no kind-on-arm64 bug. Adjacent findings:
  - #13631, "Back-off restarting failed container linkerd-network-validator" on **OrbStack's built-in Kubernetes (k3s)**, not kind. Closed as stale without a fix. https://github.com/linkerd/linkerd2/issues/13631
  - #15613 (open), an arm64 proxy memory-release (jemalloc) issue. Irrelevant to short demos.
  - #9544 (2022, closed), "Linkerd Viz fails to run on arm64". Historical.
- **VERIFIED, but it only affects contributor tooling**: The repo's `bin/kind` helper pins kind v0.11.1 and hard-codes `arch=amd64` on Darwin. It is a contributor dev script and doesn't affect users who install kind themselves.
- **INFERRED**: No known blocker. kind node images are multi-arch, and kind's node iptables backend is nft, which matches Linkerd's `nft` default. The network-validator only runs with the CNI plugin, so avoid `linkerd-cni` in demos to sidestep #13631-style problems. kind nodes share the host kernel clock, so `clockSkewAllowance` is not a factor.

---

## Implications for demo design

**Easier / clean to demo**
1. **Expired issuer, startup crash.** Install via Helm, or `kubectl apply` a replacement `linkerd-identity-issuer` Secret, with an issuer that is already expired, then `kubectl rollout restart deploy/linkerd-identity`. It deterministically gets `log.Fatalf("Failed to initialize identity service: failed to verify issuer credentials ... x509: certificate has expired ...")` and goes into CrashLoopBackOff. The `linkerd install` CLI will refuse an already-expired issuer, so use Helm or a post-install Secret swap for this one.
2. **Issuer expiring while running.** Install with an issuer that has about 5-10 minutes of validity; the CLI accepts it because no minimum is enforced. Leaves are clamped to issuer `NotAfter`, so all proxies' certs expire at the same moment as the issuer. After that: identity emits `IssuerValidationFailed` events per CSR, proxies log `Failed to obtain identity` and retry every 10s, meshed mTLS fails, and new pods never become Ready. `issuer_cert_ttl_seconds` on identity `:9990` is a ready-made countdown. Recovery demo: patch the Secret with a valid issuer and watch the `IssuerUpdated` event with no pod restart (allow for kubelet propagation delay).
3. **Silent un-meshing from an expired proxy-injector cert.** Supply `proxyInjector.crtPEM`/`keyPEM`/`caBundle` with a cert that expires in a few minutes. After expiry, the default `failurePolicy: Ignore` means new pods are admitted **without a proxy** and nothing errors. `linkerd check` goes fatal on "proxy-injector webhook has valid cert", but only if someone runs it. This is a strong operational-hygiene story. The same pattern applies to sp-validator and policy-validator: invalid ServiceProfiles and policies are accepted silently.
4. **Short leaves with identity down.** Set `issuanceLifetime=1m` or `2m`, then `kubectl scale deploy/linkerd-identity --replicas=0`. Within about 1-2.5 minutes the leaves expire and mTLS fails. This shows that the leaf lifetime is your tolerance window for identity-controller outages.

**Harder / needs care**
- **The trust anchor expiry demo has a delayed, indirect failure.** Proxies (rustls/webpki) ignore trust-anchor validity dates, so traffic keeps flowing after the anchor expires until each leaf expires. The identity controller (Go x509) refuses right away. To make the failure visible quickly, pair a short-lived anchor with a short `issuanceLifetime`. The delay is also worth explaining in the article, because "the root expired but traffic still works" misleads people.
- **The CLI rejects an already-expired anchor or issuer**, but accepts one expiring in minutes. Plan install timing so certs are valid at `linkerd install` time and expire during the demo. Alternatively, use Helm, which does no validation.
- **Webhook cert expiry needs self-supplied certs.** Generated ones are fixed at 365 days. You must set `caBundle` alongside `crtPEM`/`keyPEM`, or the template injects an unrelated generated CA.
- **Any re-render rotates webhook certs** (`linkerd upgrade`, `helm upgrade`, `linkerd viz install`). That can "fix" a staged failure, or break a hand-installed cert, if the demo script re-renders mid-scenario.
- **Trust-root rotation needs pod restarts.** The env var is baked in at injection, and the identity controller also reads the roots only at startup. It is a good "hygiene" demo, but requires a restart choreography.
- **The 60-day warnings fire immediately** for every short-lived demo cert. `linkerd check` output will show ‼ warnings from the start; the × fatal appears only after actual expiry.
- **Kubelet Secret propagation delay**, roughly up to a minute, sits between a Secret update and any in-process reload (identity issuer, webhook servers, tap). Add waits and polls, not fixed sleeps.

**Infeasible / not available**
- There is no Helm value or flag to shorten Linkerd's self-generated webhook or tap certs.
- There is no minimum-lifetime guard on `issuanceLifetime`. An invalid string silently becomes 24h, which is itself a demo-worthy footgun. A very small valid value is accepted, but the proxy's `min_refresh` floor of 10s bounds the refresh cadence.
- `linkerd check` has no leaf-certificate or tap-injector cert check, so the "check catches it" story cannot cover those.
- There is no trust-anchor TTL metric (it is a `TODO` in source); only `issuer_cert_ttl_seconds` exists.
