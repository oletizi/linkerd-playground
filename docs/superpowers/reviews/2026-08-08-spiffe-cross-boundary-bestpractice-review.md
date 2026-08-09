# Production Best-Practice Deviations — spiffe-cross-boundary demo

Scope reviewed: `MANUAL.md`, `README.md`, `edge/spire/{server,agent}.cfg`,
`edge/{install-spire,register-workload,run-proxy,iptables,extract-proxy}.sh`,
`store-pos/{server.js,run-store-pos.sh}`, `cluster/{gen-certs,install-linkerd}.sh`,
`cluster/retail/{apply.sh,authz.yaml,retail-cloud.yaml,store-pos.yaml}`,
`retail-cloud/server.js`, `net/shim.sh`, `connectivity-tailscale.md`.

This catalogues **operational / architectural shortcuts** (not exploitable
vulnerabilities — those are a separate review). Each item: where it appears, the
shortcut, why it is fine for a demo but wrong for production, and the recommended
practice.

---

## 1. Trust & CA

### 1.1 Root CA key copied to the edge as SPIRE's UpstreamAuthority
- **Where:** `MANUAL.md` Part 3a/3b (`UpstreamAuthority "disk"` pointing at
  `ca.crt`/`ca.key`); `edge/spire/server.cfg` lines 17-22; `README.md` "Copy the
  trust anchor to the store" and "Caveats"; `cluster/gen-certs.sh`.
- **Shortcut:** The Linkerd *root* CA private key (`ca.key`) is transported to the
  edge machine and handed to SPIRE via `UpstreamAuthority "disk"`, so a local SPIRE
  server signs SVIDs directly under the root.
- **Why fine for a demo / wrong for prod:** It makes the "one trust domain across two
  machines" idea tangible in one step. But the root key is the single most sensitive
  secret in the entire PKI — copying it onto an off-cluster, less-trusted edge host
  means a compromise of that host compromises the *whole* trust domain (cluster
  included), and it is impossible to revoke without re-rooting everything.
- **Recommended practice:** Never distribute the root key. Give SPIRE a dedicated
  **intermediate/signing CA** scoped to the edge, via an `UpstreamAuthority` backed by
  a managed CA — `UpstreamAuthority "aws_pca"` (AWS Private CA), `"cert-manager"`,
  `"vault"`, or SPIRE's own `"spire"` upstream nested under the cluster server. Keep
  the root offline. Scope each intermediate so it can be revoked independently.

### 1.2 Long-lived self-signed root, no HSM / managed CA
- **Where:** `cluster/gen-certs.sh` lines 22-23 (`--profile root-ca ... --not-after=87600h`).
- **Shortcut:** A 10-year (87600h) self-signed root is minted with `step` on the
  cluster VM's local disk, in software, with no hardware protection.
- **Why fine for a demo / wrong for prod:** A decade-long software root on a VM disk
  is convenient and never needs attention during the demo. In production a root that
  long-lived with no hardware backing and no rotation plan is a standing liability;
  key material on disk can be exfiltrated and there is no attestable custody.
- **Recommended practice:** Back the root with an HSM or managed CA (AWS Private CA,
  GCP CAS, HashiCorp Vault with an HSM/transit seal, cert-manager). Keep the root
  offline and short in *usage* (issue intermediates from it rarely). Define a rotation
  and cross-signing plan up front.

### 1.3 No key-rotation story for root or intermediate
- **Where:** `edge/spire/server.cfg` (`ca_ttl = "168h"` for SPIRE's own intermediate);
  `cluster/gen-certs.sh` (issuer `--not-after 8760h`); nothing anywhere rotates the
  root or re-distributes trust bundles.
- **Shortcut:** Only leaf SVIDs rotate (48h TTL). The Linkerd trust anchor and the
  edge-copied `ca.crt` are static files; there is no mechanism to roll the root or the
  issuer, or to propagate a new bundle to the edge.
- **Why fine for a demo / wrong for prod:** The demo runs for minutes, so nothing
  expires or needs rolling. In production, roots and intermediates *must* rotate, and
  trust-bundle distribution has to be automated or an expiry becomes a fleet-wide
  outage.
- **Recommended practice:** Automate issuer rotation (Linkerd + cert-manager
  integration), and distribute trust bundles via **SPIFFE trust-bundle federation** or
  a bundle endpoint rather than a hand-copied file. Plan root rollover with
  cross-signing.

### 1.4 Certificates created with `--no-password --insecure`
- **Where:** `cluster/gen-certs.sh` lines 22-26; `MANUAL.md` Part 1.
- **Shortcut:** Both root and issuer keys are written unencrypted (`--no-password`),
  and `step`'s `--insecure` flag is required to allow that.
- **Why fine for a demo / wrong for prod:** Automation-friendly for a throwaway VM.
  In production, private keys should not sit unencrypted on disk, and `--insecure`
  should never be a standing part of a provisioning pipeline.
- **Recommended practice:** Store keys encrypted / in a secrets manager or KMS; let
  the CA backend hold the key so it never lands on a filesystem in the clear.

---

## 2. SPIRE topology

### 2.1 SPIRE server and agent co-located on a single host
- **Where:** `edge/spire/agent.cfg` (`server_address = "localhost"`);
  `edge/install-spire.sh` (starts both server and agent on the edge VM);
  `MANUAL.md` Part 3d.
- **Shortcut:** One SPIRE *server* and one *agent* run on the same edge machine, and
  that server is the trust root for the workload.
- **Why fine for a demo / wrong for prod:** Minimal to stand up and reason about. But
  a SPIRE server is control-plane infrastructure; running one server per edge node,
  co-located with the workload it attests, means every edge host is its own root of
  signing authority and a single point of failure. It does not scale and blurs the
  server/agent trust boundary.
- **Recommended practice:** Run a small, hardened, **HA SPIRE server cluster**
  centrally (or reuse the cluster's SPIRE), and deploy only lightweight **agents** on
  edge nodes that dial back to it. Edge agents should hold no signing authority.

### 2.2 SQLite datastore
- **Where:** `edge/spire/server.cfg` lines 11-14 (`database_type = "sqlite3"`).
- **Shortcut:** The SPIRE server's registration entries and state live in a single
  local SQLite file.
- **Why fine for a demo / wrong for prod:** Zero-setup and perfectly adequate for one
  node. SQLite is single-writer, not replicated, and not suitable for an HA server set
  or for durability/backup guarantees.
- **Recommended practice:** Use a networked RDBMS (PostgreSQL or MySQL/Aurora) shared
  by the HA server set, with managed backups and failover.

### 2.3 KeyManager "disk"
- **Where:** `edge/spire/server.cfg` line 15; `edge/spire/agent.cfg` line 10.
- **Shortcut:** SPIRE's signing keys are persisted to a plaintext `keys.json` on the
  edge disk.
- **Why fine for a demo / wrong for prod:** Survives restarts with no infra. Software
  keys on disk on a less-trusted host are exfiltratable and unattestable.
- **Recommended practice:** Use a hardware/KMS-backed KeyManager —
  `KeyManager "aws_kms"`, `"gcp_kms"`, or an HSM/PKCS#11 backend — so the signing key
  never exists in the clear.

### 2.4 `insecure_bootstrap = true` (agent does not verify server on first contact)
- **Where:** `edge/spire/agent.cfg` line 7; `MANUAL.md` Part 3c.
- **Shortcut:** The agent skips verifying the SPIRE server's identity when it
  bootstraps.
- **Why fine for a demo / wrong for prod:** Justified in the manual because server and
  agent are the same host. Across a network it invites a man-in-the-middle to
  impersonate the SPIRE server during bootstrap — the trust-on-first-use hole.
- **Recommended practice:** Bootstrap with the server's trust bundle pinned
  (`trust_bundle_path` / `trust_bundle_url`), never `insecure_bootstrap`, whenever the
  agent and server are on different hosts.

### 2.5 Single node, no HA / no supervision for SPIRE
- **Where:** `edge/install-spire.sh` (both processes launched with `nohup ... &`,
  `sudo pkill` to restart); `MANUAL.md` Part 3d ("use a service unit in practice").
- **Shortcut:** SPIRE server and agent run as detached background processes, restarted
  by killing and relaunching, with no supervisor and no redundancy.
- **Why fine for a demo / wrong for prod:** Fastest way to get processes running in a
  script. There is no restart-on-crash, no ordering guarantee, no health-gated
  readiness, and no second instance — any crash silently drops identity issuance.
- **Recommended practice:** Run SPIRE under a process supervisor (**systemd** units
  with restart policies, or Kubernetes DaemonSet for agents) and run the server set
  HA behind a stable endpoint.

---

## 3. Attestation

### 3.1 `join_token` node attestation instead of platform attestation
- **Where:** `edge/spire/{server,agent}.cfg` (`NodeAttestor "join_token"`);
  `edge/install-spire.sh` lines 28-33; `MANUAL.md` Part 3d; `README.md` Caveats.
- **Shortcut:** The agent proves its node identity with a one-time shared secret
  (join token) generated on the same host and passed on the command line.
- **Why fine for a demo / wrong for prod:** Works on any infrastructure with no
  platform dependency, which is exactly why it's chosen for a portable demo. But a
  join token is a bearer secret with no binding to the actual node — anyone who
  obtains it can attest as that node, and it doesn't scale to fleets.
- **Recommended practice:** Use **platform node attestation** bound to hardware or
  cloud identity: `aws_iid` / `gcp_iit` / `azure_msi` instance identity, `tpm_devid`,
  `k8s_psat`, or `x509pop` with device certs. These bind the agent to a verifiable
  node identity and need no shared secret.

### 3.2 Weak `unix:uid:0` workload attestation / selector
- **Where:** `edge/spire/agent.cfg` (`WorkloadAttestor "unix"`);
  `edge/register-workload.sh` lines 8-12 (`-selector unix:uid:${UID_PROXY}` where
  `UID_PROXY = id -u root = 0`); `MANUAL.md` Part 3e.
- **Shortcut:** The workload is identified solely by "the calling process runs as
  uid 0." Any root process on the edge host that opens the Workload API socket would
  match this selector and be granted the `store-pos` SVID.
- **Why fine for a demo / wrong for prod:** One selector is easy to explain and the
  edge VM runs nothing else. In production, uid alone (especially uid 0) is a very
  weak binding — it authorizes an entire uid, not a specific program.
- **Recommended practice:** Use stronger, composite selectors: `unix:path` +
  `unix:sha256` of the binary, or richer attestors (`docker`/`k8s` label selectors,
  `systemd` unit). Run the proxy as a dedicated non-root service account and attest
  that specific binary, not "anything as root."

---

## 4. Lifecycle & automation

### 4.1 Manual, imperative registration-entry creation
- **Where:** `edge/register-workload.sh`; `MANUAL.md` Part 3e
  (`spire-server entry create ...`).
- **Shortcut:** Workload registration entries are created by ad-hoc CLI invocation,
  keyed to a hand-chosen SPIFFE ID and selector.
- **Why fine for a demo / wrong for prod:** One workload, created once, is trivial by
  hand. It doesn't scale, isn't declarative, has no audit trail, and drifts from any
  source of truth.
- **Recommended practice:** Automate registration with the **SPIRE Controller Manager**
  (`ClusterSPIFFEID` CRDs) or a registrar/GitOps pipeline so entries are declarative,
  reviewed, and reconciled.

### 4.2 Manual `ExternalWorkload` Ready-status patch via the status subresource
- **Where:** `cluster/retail/apply.sh` lines 28-30; `MANUAL.md` Part 5 (the
  `kubectl patch ... --subresource=status` with a hardcoded `lastTransitionTime`).
- **Shortcut:** The operator hand-patches the `ExternalWorkload`'s `Ready` condition
  (`reason: ManuallyReady`, `message: demo`) to mark the endpoint healthy. The manual
  even hardcodes `2026-01-01T00:00:00Z`.
- **Why fine for a demo / wrong for prod:** Bypasses the health machinery so the demo
  works immediately. In production, readiness must reflect *actual* liveness of the
  external workload; a permanently-forced Ready condition means the mesh will route to
  / trust a dead endpoint and never detect failure.
- **Recommended practice:** Let readiness be driven by real health signals — the
  Linkerd ExternalWorkload health/heartbeat mechanism or an automated controller that
  probes the workload — never a manual, static status patch.

### 4.3 Proxy version pinned by hand-extraction from the image
- **Where:** `edge/extract-proxy.sh`; `MANUAL.md` Part 4a. Version must equal
  `LINKERD_EDGE_VERSION` but nothing enforces it beyond a printed `--version`.
- **Shortcut:** The standalone `linkerd2-proxy` binary is `docker cp`'d out of the
  sidecar image onto the host, with matching left to operator discipline.
- **Why fine for a demo / wrong for prod:** Fine to do once by hand. There's no
  upgrade path, no drift detection, and skew between edge proxy and control plane is
  easy to introduce and hard to notice.
- **Recommended practice:** Distribute the proxy as a versioned, signed package/image
  through a managed rollout (config-management, package repo, or the official
  mesh-expansion tooling) with automated version-match checks.

### 4.4 App code shipped as a ConfigMap and run from a stock `node:20-alpine` image
- **Where:** `cluster/retail/apply.sh` lines 12-17; `cluster/retail/retail-cloud.yaml`
  (image `node:20-alpine`, `command: node /app/server.js`, code mounted from
  ConfigMap); `store-pos/run-store-pos.sh` (bind-mounts `server.js` into a stock
  image).
- **Shortcut:** Application source is injected at runtime via ConfigMap / bind mount
  rather than built into an image.
- **Why fine for a demo / wrong for prod:** Lets the demo edit code and re-apply with
  no registry. It's not immutable, not versioned, not scannable, and bypasses any
  supply-chain/build pipeline.
- **Recommended practice:** Build a versioned, pinned-digest, signed container image
  through CI; deploy that. No runtime code injection.

### 4.5 No GitOps / declarative reconciliation; imperative scripts throughout
- **Where:** all of `cluster/retail/apply.sh`, `edge/*.sh` (mix of `kubectl apply`,
  `kubectl patch`, `kubectl expose`, `rollout restart`, `delete --ignore-not-found`).
- **Shortcut:** State is driven by imperative shell that mutates live objects
  (including `expose`, JSON-patching a nodePort, deleting "stale" resources).
- **Why fine for a demo / wrong for prod:** Great for a guided walkthrough. There is
  no single declarative source of truth, no drift detection, and no reviewable change
  history for cluster state.
- **Recommended practice:** Manage manifests declaratively via GitOps (Argo CD / Flux)
  with pinned versions and PR review; reserve imperative kubectl for break-glass.

---

## 5. Networking

### 5.1 Static IP routes to pod/service CIDRs
- **Where:** `net/shim.sh` lines 16-22 (`ip route replace $cidr via $CLUSTER_NODE_ADDR`);
  `MANUAL.md` Part 2.
- **Shortcut:** The edge gets hand-added L3 routes to k3s's default `10.42.0.0/16` /
  `10.43.0.0/16`, assuming a flat LAN and IP forwarding on the cluster node.
- **Why fine for a demo / wrong for prod:** Simplest possible connectivity for two
  VMs. Static routes to hardcoded CIDRs are brittle, don't survive CIDR changes or
  multi-node clusters, and route raw pod traffic across an L3 boundary without an
  encrypted transport of its own.
- **Recommended practice:** Provide connectivity through a managed overlay/VPN
  (WireGuard, Tailscale subnet router — as the optional recipe shows, Cilium/Calico
  cross-cluster, or a cloud VPC peering) with proper route management, rather than
  hand-set static routes.

### 5.2 Hand-written `resolv.conf` / systemd-resolved override pointing at CoreDNS
- **Where:** `net/shim.sh` lines 24-28; `MANUAL.md` Part 2 (writes
  `/etc/systemd/resolved.conf.d/cluster.conf` with a hardcoded `COREDNS_ADDR`,
  default `10.43.0.10`).
- **Shortcut:** The edge is pointed at the CoreDNS ClusterIP for `*.cluster.local`,
  with the IP hardcoded/derived by config.
- **Why fine for a demo / wrong for prod:** Works because the ClusterIP is stable in a
  fresh k3s. It's a single hardcoded resolver with no HA, breaks if CoreDNS's ClusterIP
  differs, and sends edge DNS across the boundary in the clear.
- **Recommended practice:** Use a resolvable, HA DNS path (node-local DNS, a proper
  split-horizon resolver, or overlay-provided DNS) discovered rather than hardcoded.

### 5.3 Node exposure via NodePort 30080 with imperative JSON-patch
- **Where:** `cluster/retail/apply.sh` lines 38-42; `retail-cloud.yaml` `type: NodePort`.
- **Shortcut:** The dashboard is exposed by `kubectl expose` + a JSON patch forcing
  nodePort 30080, over plain HTTP.
- **Why fine for a demo / wrong for prod:** Quick way to reach a UI on a VM. NodePort
  with a pinned port and no TLS/ingress/auth is not how a production service is
  fronted.
- **Recommended practice:** Front the app with an Ingress/Gateway + TLS +
  authentication, declaratively managed.

### 5.4 Processes launched with `&`/`nohup` instead of service units
- **Where:** `edge/install-spire.sh` (server/agent), `edge/run-proxy.sh` line 21
  (proxy), plus `MANUAL.md` explicit note "(use a service unit in practice)".
- **Shortcut:** SPIRE server, SPIRE agent, and the proxy are detached background jobs;
  restart = `pkill` + relaunch; readiness = `sleep` + `grep` the log.
- **Why fine for a demo / wrong for prod:** Zero-config for a script. No supervision,
  no restart-on-failure, no boot persistence, no ordering, no health gating.
- **Recommended practice:** Model each as a **systemd unit** (or container/DaemonSet)
  with dependency ordering, restart policy, and real health checks.

---

## 6. App / runtime

### 6.1 Proxy runs as root; app forced non-root only to satisfy iptables
- **Where:** `edge/run-proxy.sh` line 21 (`sudo -E ... linkerd-proxy`);
  `edge/iptables.sh` (`-m owner --uid-owner 0 -j RETURN`);
  `store-pos/run-store-pos.sh` (`--user 1000:1000`); `MANUAL.md` Part 4b consequence
  note.
- **Shortcut:** The proxy runs as uid 0, and the iptables OUTPUT rule exempts uid 0 to
  avoid a redirect loop — which forces the *application* to run as non-root (uid 1000)
  purely so its traffic is captured. The registration selector (`unix:uid:0`) is then
  keyed to "root."
- **Why fine for a demo / wrong for prod:** It's the shortest correct wiring for one
  binary. Running the network-facing proxy as full root is unnecessary privilege, and
  coupling the app's uid choice to the proxy's is a fragile arrangement where the whole
  identity model hinges on a single uid.
- **Recommended practice:** Run the proxy under a **dedicated, non-root service user**
  with only the capabilities it needs (`CAP_NET_ADMIN`/`CAP_NET_RAW` as required), key
  the iptables exemption and the SPIRE selector to *that* uid + binary path/hash, and
  let apps run as their own users independently. This mirrors how the in-cluster proxy
  runs as a fixed non-zero proxy uid (2102).

### 6.2 The in-cluster app holds RBAC to mutate mesh policy at runtime
- **Where:** `cluster/retail/retail-cloud.yaml` lines 7-29 (Role granting `patch`/`update`
  on `meshtlsauthentications` bound to the `retail-cloud` ServiceAccount);
  `retail-cloud/server.js` `setAllowed()` (lines 28-42) PATCHing the
  `MeshTLSAuthentication` with the SA token; `MANUAL.md` Part 7 "Void" button.
- **Shortcut:** The demo application itself is granted RBAC to rewrite the very
  authorization policy that protects it, and does so from application code (the Void
  button).
- **Why fine for a demo / wrong for prod (architectural, distinct from the security
  angle):** It makes the "flip policy live" demo self-contained. But letting a
  workload mutate its own security policy inverts the control plane / data plane
  separation — policy should be authored by operators/GitOps, not by the app it
  governs. It couples a business service to cluster-admin-style policy control and
  makes the effective policy non-auditable (it can change without a Git change).
- **Recommended practice:** Keep authorization policy in the **declarative GitOps
  source of truth**, changed via reviewed commits and reconciled by a controller. If a
  runtime toggle is genuinely needed, put it behind a separate, narrowly-scoped
  operator tool — never grant the served application write access to its own policy.

### 6.3 App uses Docker `--network host`
- **Where:** `store-pos/run-store-pos.sh` (`--network host`).
- **Shortcut:** The POS container shares the host network namespace so the host
  iptables redirect and the shared Workload API socket path line up.
- **Why fine for a demo / wrong for prod:** Needed here so the app's egress hits the
  host's PROXY_INIT_OUTPUT chain. Host networking removes network isolation and
  namespace boundaries.
- **Recommended practice:** Use per-workload network namespaces with the redirect and
  proxy scoped to that namespace (as an injected sidecar does), rather than host
  networking.

---

## 7. Operations

### 7.1 Single trust domain spanning environments instead of federation
- **Where:** `edge/spire/{server,agent}.cfg` (`trust_domain =
  "root.linkerd.cluster.local"` on the edge, identical to the cluster's);
  `README.md` "one trust domain, no federation"; `MANUAL.md` "The mental model".
- **Shortcut:** The off-cluster edge shares the *same* trust domain as the cluster by
  reusing the cluster's root.
- **Why fine for a demo / wrong for prod:** One trust domain is the simplest thing to
  reason about and is the whole point of the demo. But collapsing distinct
  environments (on-prem store vs cloud cluster) into one trust domain removes the
  isolation boundary — a compromise on one side is a compromise of the same identity
  authority as the other.
- **Recommended practice:** Give each environment its **own trust domain** and connect
  them with **SPIFFE federation** (trust-bundle exchange between separate SPIRE
  servers), authorizing specific foreign identities. This preserves per-environment
  blast-radius containment.

### 7.2 Hardcoded namespace / labels / identity strings
- **Where:** `retail-cloud/server.js` (`STORE_ID`, `CLOUD_ID`, `DENY_ID` string-built);
  `store-pos/server.js` (`INGEST` default hardcodes `retail-cloud.mixed-env...`);
  `cluster/retail/*.yaml` (`mixed-env`, `app: store-pos` selectors); the `DENY_ID`
  points at a `blocked` ServiceAccount that is never created.
- **Shortcut:** Namespace `mixed-env`, workload labels, and SPIFFE IDs are string
  literals scattered across app code and manifests; the "deny" identity is a
  made-up name.
- **Why fine for a demo / wrong for prod:** Fine for a fixed single-tenant demo. It's
  brittle, non-reusable across namespaces/tenants, and the ad-hoc `blocked` identity is
  a magic string rather than a real policy target.
- **Recommended practice:** Parameterize identities/namespaces through
  config/templating (Helm/Kustomize), and express "deny" as an explicit empty/false
  authorization rather than pointing at a non-existent SA.

### 7.3 No monitoring / alerting / backup for the SPIRE datastore
- **Where:** absence across `edge/*` — no metrics endpoint configured in
  `server.cfg`/`agent.cfg`, no backup of `datastore.sqlite3` or `keys.json`, logs go
  to `/tmp/*.log`.
- **Shortcut:** SPIRE runs with `log_level = "DEBUG"` to `/tmp`, no telemetry, no
  datastore backup, no alerting on issuance failures or cert expiry.
- **Why fine for a demo / wrong for prod:** Nothing needs to be observed for a
  minutes-long demo. In production, silent SPIRE failure = fleet-wide identity outage;
  loss of the datastore/keys = loss of all registrations.
- **Recommended practice:** Enable SPIRE's Prometheus telemetry and alert on issuance
  errors / bundle expiry; ship logs to a real sink at an appropriate level; back up
  the (RDBMS) datastore and protect key material; monitor SVID rotation health.

### 7.4 DEBUG logging left on
- **Where:** `edge/spire/server.cfg` line 6, `edge/spire/agent.cfg` line 3
  (`log_level = "DEBUG"`).
- **Shortcut:** Both SPIRE components log at DEBUG.
- **Why fine for a demo / wrong for prod:** Helpful when teaching / troubleshooting a
  walkthrough. DEBUG is noisy, can leak sensitive attestation detail, and adds
  overhead.
- **Recommended practice:** Run at `INFO`/`WARN` in production with structured log
  shipping; reserve DEBUG for diagnosis.

### 7.5 "Latest" version resolution for SPIRE at install time
- **Where:** `edge/install-spire.sh` lines 12-14 (resolves SPIRE **latest** release
  from the GitHub API and installs it); similarly `cluster/gen-certs.sh` installs the
  latest `step` `.deb`.
- **Shortcut:** SPIRE (and `step`) versions float to whatever "latest" is at run time.
- **Why fine for a demo / wrong for prod:** Always-current with no maintenance for a
  demo. Unpinned versions make runs non-reproducible and can introduce breaking
  changes silently — notably at odds with the demo's own care to pin the *Linkerd*
  version everywhere.
- **Recommended practice:** Pin SPIRE and tooling to specific, tested versions
  (verified digests/checksums), upgraded deliberately.

---

## Cross-cutting note

The demo is admirably honest in places — `README.md` "Caveats" and several `MANUAL.md`
call-outs already flag the root-key-on-edge trade-off, `join_token`, and "use a
service unit in practice." The items above extend that honesty into a complete list;
the biggest production-relevant themes are: (a) **root key custody & trust-domain
isolation** (1.1, 7.1), (b) **SPIRE as real HA infrastructure** rather than a
co-located single node (2.x), (c) **platform attestation & strong selectors** over
join tokens and `uid:0` (3.x), and (d) **declarative lifecycle** over imperative,
runtime-mutated policy — especially the app holding RBAC to rewrite its own
authorization (6.2, 4.5).
