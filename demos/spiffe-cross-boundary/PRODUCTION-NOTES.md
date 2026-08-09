# Production notes — how this demo simplifies

This is a **teaching demo**. Its purpose is to make the mechanics of SPIFFE identity
across an infrastructure boundary easy to follow in one sitting. To keep the moving
parts legible, it takes deliberate shortcuts that are **not safe or appropriate for
production**. Do not copy this configuration into a real environment.

This page lists those shortcuts and what to do instead — the exploitable security
shortcuts first, then the broader operational and architectural simplifications. The
[manual](MANUAL.md) explains how each piece is built; this page explains where each piece
departs from production practice.

## The ones that matter most

- **The application can rewrite its own authorization policy.** The `retail-cloud` pod
  holds RBAC to `patch` the `MeshTLSAuthentication` that protects it, and the *Void
  authorization* button does so from an unauthenticated web endpoint. Production:
  authorization policy is authored by operators in a GitOps source of truth, never mutated
  by the workload it governs.
- **The root CA key is stored in a Kubernetes Secret.** It is off the store — only a
  one-time join token and the public trust bundle go to the edge — but a cluster Secret is
  not HSM / offline-root custody. Production: back the root with external or offline PKI,
  an HSM, or Vault.
- **One trust domain spans both environments.** The store reuses the cluster's trust
  domain — the whole point of the demo, but it removes the isolation boundary between
  on-prem and cloud. Production: give each environment its own trust domain and connect
  them with **SPIFFE federation**.

## Security shortcuts

These are exploitable as written, not merely non-ideal.

- **Unauthenticated policy mutation on a browser-facing NodePort.** `POST /api/policy` has
  no auth and is published on the node, so anyone who reaches it can flip the store's
  authorization (a remote, credential-free denial of service, and CSRF-able). → Require
  authentication on any state-changing endpoint; separate the read-only dashboard from
  privileged control actions.
- **The web pod's ServiceAccount token is a lateral-movement prize.** That pod runs as
  root and mounts a token that can rewrite namespace policy, so any code-execution bug in
  the app yields policy control. → Do not grant the served app write access to its own
  policy; disable token automount; mediate any real control action through a separate,
  narrowly scoped controller.
- **Web pod runs as root with no `securityContext` and unbounded request bodies.**
  Memory-exhaustion DoS and a high-value target for any code-exec bug. → `runAsNonRoot`,
  dropped capabilities, read-only rootfs, resource limits, and request-size caps.
- **Long-lived, password-less, unrevocable root.** A 10-year software root written
  unencrypted, with long SVID/CA TTLs and no revocation. → Encrypt keys at rest or hold
  them in an HSM/KMS; shorten TTLs (SPIRE rotates automatically); rely on short TTLs plus
  intermediate rotation in place of revocation.
- **Unverified, unpinned downloads.** `curl | sh` for Linkerd, an unchecked `step` `.deb`,
  and `:latest` container images. → Pin exact versions, verify checksums and signatures,
  pin images by digest.
- **Plaintext HTTP, no TLS or auth on the dashboard and APIs.** → Terminate TLS at an
  ingress/gateway and require auth for the UI and any control endpoints.

## Operational and architectural simplifications

Not directly exploitable, but not how a production system is built.

### Trust & CA

- **The SPIRE server's upstream is the root on disk** (`UpstreamAuthority "disk"`, from a
  Secret) → a scoped intermediate from a managed CA (Vault, cert-manager, AWS Private CA),
  with the root kept offline.
- **A long-lived self-signed software root, no HSM/managed CA, no rotation plan** → back
  the root with an HSM or managed CA; define rotation and cross-signing up front.
- **The store's trust bundle is a hand-copied file** → distribute bundles via a **SPIFFE
  trust-bundle endpoint** / federation.

### SPIRE topology

- **Single-replica server, no HA.** The server is central (in the cluster) with an
  agent-only edge, but it is one replica → an **HA SPIRE server** behind a stable endpoint.
- **SQLite datastore** → a networked RDBMS (PostgreSQL/MySQL) with managed backups.
- **`KeyManager "disk"`** (signing keys on disk) → a KMS/HSM-backed KeyManager (`aws_kms`,
  `gcp_kms`, PKCS#11).
- **No process supervision** (`setsid`/`nohup`, restart by `pkill`) → systemd units (or a
  DaemonSet for agents) with restart policies and health-gated readiness.

### Attestation

- **`join_token` node enrollment** — a legitimate one-time mechanism. Production commonly
  binds enrollment to a **device identity** (TPM/DevID, enterprise PKI, or a cloud instance
  identity: `aws_iid`, `gcp_iit`, `k8s_psat`, `x509pop`) rather than a token.
- **Workload attestation is `unix:uid:2102` + `unix:path`** — enough to isolate ordinary
  processes on the host. `unix:sha256` (binary hash) is an optional tightening; note the
  host-root boundary below.

### Lifecycle & automation

- **Manual `spire-server entry create`** → the **SPIRE Controller Manager**
  (`ClusterSPIFFEID` CRDs) or a registrar/GitOps pipeline.
- **Manual `ExternalWorkload` Ready-status patch** (with a hardcoded timestamp) → drive
  readiness from real health signals, never a static forced condition.
- **Proxy binary hand-extracted from the image, version by discipline** → a versioned,
  signed package with automated version-match checks.
- **App code shipped as a ConfigMap / bind mount on a stock image** → a built,
  pinned-digest, signed container image from CI. No runtime code injection.
- **Imperative `kubectl` throughout, no declarative source of truth** → GitOps (Argo
  CD/Flux) with pinned versions and PR review.

### Networking

- **Static routes to hardcoded pod/service CIDRs** → a managed overlay/VPN (WireGuard,
  Tailscale subnet router, cross-cluster CNI, or VPC peering) with real route management.
- **A hand-written resolver pointing at a hardcoded CoreDNS ClusterIP** → an HA, discovered
  DNS path.
- **The dashboard is a plain-HTTP NodePort set by JSON-patch** → an Ingress/Gateway with
  TLS and auth, managed declaratively.

### App & runtime

- **Docker `--network host` for the POS container** → per-workload network namespaces with
  the redirect scoped to that namespace, as an injected sidecar does.

### Operations

- **Hardcoded namespaces, labels, and identity strings** (and a `blocked` ServiceAccount
  that is never created, used to express "deny") → parameterize via Helm/Kustomize; express
  deny as an explicit empty authorization.
- **No monitoring, alerting, or backup for SPIRE** → enable SPIRE's Prometheus telemetry,
  alert on issuance failures and bundle expiry, back up the datastore and key material.
- **`step` and Linkerd installed from unpinned sources** → pin and verify all tooling
  versions and checksums.

## Security boundaries (what this does and does not protect)

Two limitations stated explicitly, so the security claims are honest:

- **PKI custody.** The root CA key is stored in a Kubernetes Secret, not protected by
  external/offline PKI, an HSM, or Vault.
- **Edge host trust.** Full **root compromise** of the store host can compromise that
  store's node and workload identities: root can run the permitted binary as the permitted
  uid, or attack the agent and read its node credentials. UID + executable-path workload
  attestation provides **least-privilege isolation between ordinary processes**, not a
  boundary against a hostile host administrator.
