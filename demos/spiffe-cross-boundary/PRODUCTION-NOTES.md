# Production notes — how this demo simplifies

This is a **teaching demo**. Its purpose is to make the mechanics of SPIFFE identity
across an infrastructure boundary easy to follow in one sitting. To keep the moving
parts legible, it takes deliberate shortcuts that are **not safe or appropriate for
production**. Do not copy this configuration into a real environment.

This page lists those shortcuts and what to do instead. It is grouped into the
exploitable security shortcuts first, then the broader operational and architectural
simplifications. The [manual](MANUAL.md) explains how each piece is built; this page
explains where each piece departs from production practice.

## The four that matter most

- **The trust domain's root key is copied onto the edge machine.** SPIRE's
  `UpstreamAuthority "disk"` signs with Linkerd's root `ca.key`, so a compromise of the
  store host compromises the entire trust domain — every identity in the cluster
  included — with no revocation path. Production: give the edge a scoped **intermediate**
  from a managed CA and keep the root offline.
- **The application can rewrite its own authorization policy.** The `retail-cloud` pod
  holds RBAC to `patch` the `MeshTLSAuthentication` that protects it, and the *Void
  authorization* button does so from an unauthenticated web endpoint. Production:
  authorization policy is authored by operators in a GitOps source of truth, never
  mutated by the workload it governs.
- **Workload identity is bound to "any root process."** The registration selector is
  `unix:uid:0` and the proxy runs as root, so any root process on the edge that can open
  the Workload API socket obtains the `store-pos` identity. Production: attest a specific
  non-root binary (path + hash, or a platform attestor).
- **One trust domain spans both environments.** The edge reuses the cluster's trust
  domain, which is the whole point of the demo but removes the isolation boundary between
  on-prem and cloud. Production: give each environment its own trust domain and connect
  them with **SPIFFE federation**.

## Security shortcuts

These are exploitable as written, not merely non-ideal.

- **Root CA private key on the edge (and staged through `/tmp`).** As above: whole-trust-
  domain blast radius, no revocation. → Scoped intermediate from a managed CA (Vault,
  cert-manager, AWS Private CA); root stays offline; transport secrets over an
  authenticated channel, never shared `/tmp`.
- **Unauthenticated policy mutation on a browser-facing NodePort.** `POST /api/policy`
  has no auth and is published on the node, so anyone who reaches it can flip the store's
  authorization (a remote, credential-free denial of service, and CSRF-able). → Require
  authentication on any state-changing endpoint; separate the read-only dashboard from
  privileged control actions.
- **The web pod's ServiceAccount token is a lateral-movement prize.** That same pod runs
  as root and mounts a token that can rewrite namespace policy, so any code-execution bug
  in the app yields policy control. → Do not grant the served app write access to its own
  policy; disable token automount; mediate any real control action through a separate,
  narrowly scoped controller.
- **Identity bound only to `unix:uid:0`.** Weak, broadly held selector; the proxy runs as
  root. → Composite selectors (`unix:path` + `unix:sha256`) or a platform/container
  attestor, and run the proxy as a dedicated non-root user.
- **Trust-on-first-use bootstrap and a bearer join token.** `insecure_bootstrap = true`
  and a `join_token` passed on the command line (visible in `/proc`). → Pin the server's
  trust bundle; use platform node attestation (`aws_iid`, `gcp_iit`, `k8s_psat`,
  `x509pop`).
- **Long-lived, password-less, unrevocable root.** A 10-year software root written
  unencrypted, with long SVID/CA TTLs and no revocation. → Encrypt keys at rest or hold
  them in an HSM/KMS; shorten TTLs (SPIRE rotates automatically); rely on short TTLs plus
  intermediate rotation in place of revocation.
- **Unverified, unpinned downloads.** `curl | sh` for Linkerd, "latest" SPIRE, an
  unchecked `.deb`, and `:latest` images. → Pin exact versions, verify checksums and
  signatures, pin images by digest.
- **Blanket root-egress exemption in iptables.** `--uid-owner 0 -j RETURN` sends all
  root-originated traffic outside the mesh in cleartext, and forces the app to run
  non-root to be captured. → Run the proxy as a dedicated non-root uid and exempt only
  that uid.
- **Web pod runs as root with no `securityContext` and unbounded request bodies.** Memory-
  exhaustion DoS and a high-value target for any code-exec bug. → `runAsNonRoot`, dropped
  capabilities, read-only rootfs, resource limits, and request-size caps.
- **Plaintext HTTP, no TLS or auth on the dashboard and APIs.** → Terminate TLS at an
  ingress/gateway and require auth for the UI and any control endpoints.

## Operational and architectural simplifications

Not directly exploitable, but not how a production system is built.

### Trust & CA

- **Root key handed to SPIRE via `UpstreamAuthority "disk"`** → a scoped intermediate from
  a managed CA; keep the root offline.
- **Long-lived self-signed software root, no HSM/managed CA, no rotation plan** → back the
  root with an HSM or managed CA; define rotation and cross-signing up front.
- **No trust-bundle distribution mechanism** (the edge `ca.crt` is a hand-copied file) →
  distribute bundles via **SPIFFE trust-bundle federation** or a bundle endpoint.

### SPIRE topology

- **Server and agent co-located on one edge host**, so every edge is its own signing root
  and single point of failure → a central, hardened, **HA SPIRE server** with lightweight
  agents on edge nodes that hold no signing authority.
- **SQLite datastore** → a networked RDBMS (PostgreSQL/MySQL) with managed backups.
- **`KeyManager "disk"`** (plaintext signing keys) → a KMS/HSM-backed KeyManager
  (`aws_kms`, `gcp_kms`, PKCS#11).
- **No supervision** (`nohup &`, restart by `pkill`) → systemd units (or a DaemonSet for
  agents) with restart policies and health-gated readiness.

### Attestation

- **`join_token` node attestation** → platform attestation bound to hardware or cloud
  identity.
- **`unix:uid:0` workload selector** → composite/binary-scoped selectors or a
  container/platform attestor.

### Lifecycle & automation

- **Manual `spire-server entry create`** → the **SPIRE Controller Manager**
  (`ClusterSPIFFEID` CRDs) or a registrar/GitOps pipeline.
- **Manual `ExternalWorkload` Ready-status patch** (with a hardcoded timestamp) → drive
  readiness from real health signals, never a static forced condition.
- **Proxy binary hand-extracted from the image, version by discipline** → a versioned,
  signed package with automated version-match checks.
- **App code shipped as a ConfigMap / bind mount on a stock image** → a built, pinned-
  digest, signed container image from CI. No runtime code injection.
- **Imperative `kubectl` throughout, no declarative source of truth** → GitOps (Argo
  CD/Flux) with pinned versions and PR review.

### Networking

- **Static routes to hardcoded pod/service CIDRs** → a managed overlay/VPN (WireGuard,
  Tailscale subnet router, cross-cluster CNI, or VPC peering) with real route management.
- **Hand-written resolver pointing at a hardcoded CoreDNS ClusterIP** → an HA, discovered
  DNS path.
- **NodePort over plain HTTP set by JSON-patch** → an Ingress/Gateway with TLS and auth,
  managed declaratively.

### App & runtime

- **Proxy runs as root; the app is forced non-root only to satisfy the iptables
  exemption** → run the proxy as a dedicated non-root user with only the capabilities it
  needs, keyed to that uid and binary.
- **The served app holds RBAC to mutate its own policy** (the Void button) → policy lives
  in GitOps; any runtime toggle goes through a separate, minimally privileged operator
  tool.
- **Docker `--network host` for the POS container** → per-workload network namespaces with
  the redirect scoped to that namespace, as an injected sidecar does.

### Operations

- **Single trust domain across environments** → per-environment trust domains joined by
  **SPIFFE federation** for blast-radius containment.
- **Hardcoded namespaces, labels, and identity strings** (and a `blocked` ServiceAccount
  that is never created, used to express "deny") → parameterize via Helm/Kustomize;
  express deny as an explicit empty authorization.
- **No monitoring, alerting, or backup for SPIRE** → enable SPIRE's Prometheus telemetry,
  alert on issuance failures and bundle expiry, back up the datastore and key material.
- **`log_level = "DEBUG"` left on** → `INFO`/`WARN` with structured log shipping.
- **SPIRE and `step` installed at "latest"** (inconsistent with the demo's own Linkerd
  pinning) → pin and verify tooling versions.
