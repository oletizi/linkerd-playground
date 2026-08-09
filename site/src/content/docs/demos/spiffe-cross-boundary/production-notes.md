---
title: Production notes
description: How this teaching demo deviates from production best practices, and what to do instead.
---

This is a **teaching demo**. Its purpose is to make the mechanics of SPIFFE identity
across an infrastructure boundary easy to follow in one sitting. To keep the moving
parts legible, it takes deliberate shortcuts that are **not safe or appropriate for
production**. Do not copy this configuration into a real environment.

This page lists those shortcuts and what to do instead. It is grouped into the
exploitable security shortcuts first, then the broader operational and architectural
simplifications. The [manual](/demos/spiffe-cross-boundary/manual/) explains how each piece is built; this page
explains where each piece departs from production practice.

## Resolved by the current SPIRE topology

This demo runs the SPIRE **server in the cluster** and an **agent only** on the store,
which resolves three of the original findings: the **root key is off the edge** (it stays
in the cluster, mounted into the server as a Secret); **workload attestation** is scoped
to a dedicated non-root proxy by `unix:uid:2102` + `unix:path` (least-privilege isolation,
not host-root defense — see Security boundaries); and the agent **bootstrap is pinned** to
the server's trust bundle (no `insecure_bootstrap`). The remaining simplifications are
documented below.

## The ones that remain

- **The application can rewrite its own authorization policy.** The `retail-cloud` pod
  holds RBAC to `patch` the `MeshTLSAuthentication` that protects it, and the *Void
  authorization* button does so from an unauthenticated web endpoint. Production:
  authorization policy is authored by operators in a GitOps source of truth, never
  mutated by the workload it governs.
- **The root key lives in a Kubernetes Secret.** Off the edge (the important fix), but a
  cluster Secret is not HSM / offline-root custody. Production: back the root with
  external or offline PKI, an HSM, or Vault.
- **One trust domain spans both environments.** The edge reuses the cluster's trust
  domain — the whole point of the demo, but it removes the isolation boundary between
  on-prem and cloud. Production: give each environment its own trust domain and connect
  them with **SPIFFE federation**.
- **Full host-root compromise of the store is out of scope.** UID + path attestation
  isolates ordinary processes, but a root attacker on the store can run the permitted
  binary as the permitted uid, or attack the agent and read its node credentials. This is
  a demo boundary, stated honestly — not a bug to fix with more selectors.

## Security shortcuts

Several of these are now **resolved** (marked ✓ by the SPIRE re-architecture); the rest
are exploitable as written.

- **✓ Resolved — root CA key is off the edge.** The SPIRE server runs in the cluster; only
  a one-time join token and the public trust bundle go to the store. Residual: the root
  still lives in a cluster Secret (see "The ones that remain"). Production: managed/offline
  CA, HSM, or Vault.
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
- **✓ Resolved — workload attestation is uid + path.** The proxy runs as a dedicated
  non-root user (uid 2102), attested by `unix:uid:2102` + `unix:path`; an unrelated process
  (even one running as root) does not match. This is least-privilege isolation between
  ordinary processes, **not** a defense against host-root (see Security boundaries).
  `unix:sha256` is left as an optional production tightening.
- **✓ Resolved (bootstrap) — the agent pins the server's trust bundle** (`trust_bundle_path`;
  no `insecure_bootstrap`). Node enrollment uses a **one-time join token** — a legitimate
  SPIRE node-attestation mechanism, not a shortcut to remove. Production commonly binds
  enrollment to a **device identity** (TPM/DevID, enterprise PKI, or a cloud instance
  identity: `aws_iid`, `gcp_iit`, `k8s_psat`, `x509pop`) rather than a token.
- **Long-lived, password-less, unrevocable root.** A 10-year software root written
  unencrypted, with long SVID/CA TTLs and no revocation. → Encrypt keys at rest or hold
  them in an HSM/KMS; shorten TTLs (SPIRE rotates automatically); rely on short TTLs plus
  intermediate rotation in place of revocation.
- **Unverified, unpinned downloads.** `curl | sh` for Linkerd, "latest" SPIRE, an
  unchecked `.deb`, and `:latest` images. → Pin exact versions, verify checksums and
  signatures, pin images by digest.
- **✓ Resolved — app-scoped iptables.** The redirect matches only the app's uid (1000) →
  the proxy; all other host traffic (SPIRE agent, DNS, SSH, proxy egress) is untouched. No
  blanket root exemption, and no setup-ordering dependency.
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

- **Single-replica server, no HA.** The server is now central (in the cluster) with an
  agent-only edge — the correct topology — but it is one replica, not an HA server set.
  Production: an **HA SPIRE server** behind a stable endpoint with a networked datastore.
- **SQLite datastore** → a networked RDBMS (PostgreSQL/MySQL) with managed backups.
- **`KeyManager "disk"`** (plaintext signing keys) → a KMS/HSM-backed KeyManager
  (`aws_kms`, `gcp_kms`, PKCS#11).
- **No supervision** (`nohup &`, restart by `pkill`) → systemd units (or a DaemonSet for
  agents) with restart policies and health-gated readiness.

### Attestation

- **`join_token` node enrollment** — a legitimate one-time mechanism (kept). Production
  commonly binds enrollment to a device identity (TPM/DevID, enterprise PKI, or a cloud
  instance identity).
- **✓ Workload attestation is `unix:uid:2102` + `unix:path`** (resolved from `uid:0`) —
  least-privilege isolation, not host-root defense. `unix:sha256` optional.

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

- **✓ The proxy runs as a dedicated non-root user (uid 2102)**, attested by uid + path, and
  the iptables redirect is scoped to the app's uid. (Resolved.)
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
- **SPIRE and `step` installed at "latest"** (the SPIRE server image is pinned; the agent
  is pinned to match it) → pin and verify all tooling versions.

## Security boundaries (what this does and does not protect)

Two limitations the demo states explicitly, so the security claims are honest:

- **Demo PKI simplification.** The root CA key is removed from the edge but is stored in a
  Kubernetes Secret in the cluster — **not** protected by external/offline PKI, an HSM, or
  Vault. The correction that matters is that the key left the less-trusted edge host; its
  in-cluster Secret custody is still a demo simplification.
- **Edge host trust assumption.** Full **root compromise** of the store host can compromise
  that store's node and workload identities: root can run the permitted binary as the
  permitted uid, or attack the agent and read its node credentials. UID + executable-path
  workload attestation provides **least-privilege isolation between ordinary processes**,
  not a boundary against a hostile host administrator.
