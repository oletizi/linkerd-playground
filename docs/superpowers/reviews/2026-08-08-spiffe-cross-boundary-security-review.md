# Security review — spiffe-cross-boundary demo

Scope: the RetailCloud teaching demo that gives an off-cluster workload a SPIFFE
identity and joins it to a Linkerd mesh. This is a catalogue of the exploitable
holes and unsafe practices in the demo *as written*, so they can be documented
honestly. We are NOT fixing them. For each: title, location, risk/exploit,
severity, and the secure production practice.

A note up front on one hypothesized issue: **the `retail-cloud` `/api/policy`
handler does NOT shell out to `kubectl` and has no command-injection surface.** It
calls the Kubernetes API directly over HTTPS (`retail-cloud/server.js:28-42`) with
the pod's ServiceAccount token, and the patched identity value is a hardcoded
constant (`STORE_ID` or `DENY_ID`), never taken from request input. So there is no
shell and no attacker-chosen identity *through the endpoint*. The real problems
around that endpoint are different (no authN on the endpoint; the SA token + RBAC
as a lateral-movement prize) and are findings 2 below.

---

## HIGH

### H1. The Linkerd root CA private key is copied out of the cluster to the store host (and staged in world-readable /tmp)
- **Where:** `MANUAL.md:139-148` (`cp ca.crt ca.key /opt/spire/certs/`), `README.md:102-108`
  (`limactl shell ... cat linkerd-certs/ca.key > /tmp/ca.key`, then `cat /tmp/ca.key | ... tee /opt/spire/certs/ca.key`),
  `edge/spire/server.cfg:17-22` (`UpstreamAuthority "disk"` reads `ca.key`),
  `cluster/gen-certs.sh:22-23`.
- **Risk / exploit:** `ca.key` is the trust anchor for the *entire* trust domain
  `root.linkerd.cluster.local`. Placing it on the store host means the root of trust
  now lives on a machine that also runs a network-facing POS process, SPIRE (as
  root), and the proxy (as root). Anyone who compromises the store host reads
  `/opt/spire/certs/ca.key` and can mint a valid SVID for **any** identity in the
  mesh — `retail-cloud`, `linkerd-identity`, any ServiceAccount — defeating every
  `MeshTLSAuthentication`/`AuthorizationPolicy` in the cluster and enabling
  impersonation of the control plane itself. There is no revocation path (see H-adjacent
  M2), so the only remediation is rotating the anchor across the whole mesh. The
  README's `/tmp/ca.key` staging on the Mac host also exposes the key to any other
  local user/process (default file perms in `/tmp`).
- **Severity:** High. This is the single largest blast radius in the demo.
- **Secure practice:** Never move the root key off the cluster (or off an HSM/offline
  store). Give SPIRE an **intermediate** signing key via an `UpstreamAuthority` that
  chains to, but is not, the root — SPIRE's `UpstreamAuthority "disk"` with an
  intermediate, or a real CA backend (Vault/`cert-manager`/AWS PCA). Scope and rotate
  that intermediate independently; keep the root offline. Transport secrets over an
  authenticated channel, never through shared `/tmp`. The demo's own README caveat
  acknowledges this ("the root CA key lives on the edge... a real deployment would use
  an intermediate").

### H2. `/api/policy` mutates cluster authorization policy with no authentication, on the browser-facing NodePort
- **Where:** `retail-cloud/server.js:77-88` (`POST /api/policy` on `UI_PORT` 8080, no
  auth check), `cluster/retail/retail-cloud.yaml:63-77` (`Service` type `NodePort`
  exposing 8080), `cluster/retail/apply.sh:39-42` (second NodePort `retail-cloud-lan`
  pinned to `30080`). RBAC in `cluster/retail/retail-cloud.yaml:7-29`.
- **Risk / exploit:** Port 8080 has **no Linkerd `Server`/authz** (by design, so the
  browser can load it — `MANUAL.md:404-407`) and is published on the node at `:30080`
  (and a second random NodePort). Anyone who can reach that node — the whole LAN, or
  the whole tailnet under the Tailscale recipe — can `POST /api/policy {"allow":false}`
  and flip the real `MeshTLSAuthentication` to deny the store, or `{"allow":true}` to
  restore it. That is an unauthenticated, remote, real mutation of cluster security
  policy: a trivial DoS on the store's data path with no credentials. There is no
  origin check, CSRF token, or auth of any kind; a browser on any page could also be
  made to trigger it (simple CSRF).
- **Severity:** High (unauthenticated remote policy mutation), even though the app
  constrains the *value* patched.
- **Secure practice:** Require authentication/authorization on any state-changing
  admin endpoint; never expose it unauthenticated on a NodePort. Separate the
  read-only dashboard from privileged control actions; put the control action behind
  authN (mTLS/OIDC), CSRF protection, and ideally a separate, access-controlled
  network path. Do not co-locate an unauthenticated web listener in the same process
  that holds a policy-mutating SA token.

### H2b. The retail-cloud ServiceAccount + RBAC is a lateral-movement prize
- **Where:** `cluster/retail/retail-cloud.yaml:7-29` (Role grants
  `get/patch/update` on `meshtlsauthentications` in `mixed-env`; RoleBinding to the
  `retail-cloud` SA), token auto-mounted and read at `server.js:30-32`.
- **Risk / exploit:** A web-facing Node process holds a token that can rewrite the
  namespace's `MeshTLSAuthentication` objects. Any RCE/SSRF in `retail-cloud` (it
  parses attacker-influenced JSON on two ports, runs as root — see M5) yields the SA
  token and thereby the ability to set the allowed identities to *anything*, e.g.
  authorize an attacker-controlled identity to reach the ingest port, or deny
  legitimate ones. The `patch`/`update` verbs on `meshtlsauthentications` are broader
  than the single toggle the app uses.
- **Severity:** High (privilege the app should not hold, reachable via app compromise).
- **Secure practice:** The app should not mutate its own authorization policy. If a
  control action is genuinely needed, mediate it through a separate, minimally
  privileged controller with a narrowly scoped Role (ideally a purpose-built
  admission-guarded CRD or a `resourceNames`-restricted Role limited to the one object),
  and disable SA token automount on the web pod (`automountServiceAccountToken: false`).

### H3. Workload identity is bound only to `unix:uid:0`, and the proxy runs as root — any root process on the store gets the store-pos SVID
- **Where:** `edge/register-workload.sh:6-13` (`-selector unix:uid:${UID_PROXY}` where
  `UID_PROXY=$(id -u root)=0`), `MANUAL.md:248-259`, `edge/spire/agent.cfg:12`
  (`WorkloadAttestor "unix"`), proxy launched as root `edge/run-proxy.sh:21`
  (`sudo -E ... linkerd-proxy`).
- **Risk / exploit:** The `unix` workload attestor authorizes the SVID purely on the
  caller's uid. The registration entry says "any process with uid 0 may receive
  `spiffe://.../store-pos`." SPIRE, the proxy, and (per the iptables exemption, M4)
  effectively any privileged tooling all run as root on this host. **Any** root
  process that can open the agent's Workload API socket
  (`/tmp/spire-agent/public/api.sock`, the "public" socket) can therefore obtain the
  store's full mesh identity and mint mTLS connections as `store-pos`. The binding
  between "the POS workload" and "the identity" is essentially nonexistent — it's
  "root on this box," not "this program."
- **Severity:** High. Identity is only as strong as its attestation, and uid:0 is a
  very weak, broadly-held selector.
- **Secure practice:** Attest on stronger, narrower properties — a dedicated
  non-root service uid + binary path + signature, or SPIRE's `docker`/`k8s`/`systemd`
  workload attestors, or hardware/platform attestation. Combine multiple selectors so
  the entry matches exactly one intended program, and run the proxy as a dedicated
  unprivileged user. Restrict access to the Workload API socket.

---

## MEDIUM

### M1. `insecure_bootstrap = true` plus join-token passed on the command line
- **Where:** `edge/spire/agent.cfg:7` (`insecure_bootstrap = true`),
  `edge/install-spire.sh:28,33` (`token generate ... | awk`, then
  `spire-agent run ... -joinToken "$TOKEN"`), `MANUAL.md:202-234`.
- **Risk / exploit:** `insecure_bootstrap` skips verification of the SPIRE server's
  identity on first contact, so a MITM on the agent↔server channel could impersonate
  the server during bootstrap. `join_token` is a bearer secret: passed as a process
  argument it is visible in `ps`/`/proc/<pid>/cmdline` to any local user, and it
  provides no hardware/instance binding — anyone who captures it within its validity
  window can attest as the node. Here server and agent are the same host, which
  narrows the window, but the pattern is unsafe if copied to real infra.
- **Severity:** Medium (mitigated by same-host, dangerous if generalized).
- **Secure practice:** Provide the agent the server's trust bundle and set
  `insecure_bootstrap = false`. Use platform node attestation (AWS/GCP/Azure instance
  identity, TPM, or x509) instead of `join_token`; if join tokens are unavoidable,
  deliver them out-of-band and never on the command line.

### M2. Long-lived, password-less, unrevocable root CA
- **Where:** `cluster/gen-certs.sh:22-23` (`--profile root-ca --no-password --insecure
  --not-after=87600h`), `MANUAL.md:66-72`. No CRL/OCSP anywhere.
- **Risk / exploit:** A 10-year (87600h) root with its key stored unencrypted on disk
  (`--no-password`, which requires `--insecure`) and no revocation mechanism. Combined
  with H1 (key off-cluster), a single leak is unrecoverable short of re-rooting the
  entire mesh; there is no way to revoke a specific issued SVID. The 48h SVID TTL /
  168h CA TTL (`server.cfg:7-8`) are also long by SPIFFE norms (minutes-to-hours),
  widening the window a stolen SVID remains valid.
- **Severity:** Medium.
- **Secure practice:** Encrypt CA keys at rest (or keep them in an HSM/KMS), shorten
  root lifetimes with a rotation plan, shorten SVID TTLs to hours or less (SPIRE
  rotates automatically), and rely on short TTLs + intermediate rotation in lieu of
  revocation.

### M3. Unverified, unpinned software downloads across setup (supply chain)
- **Where:** `cluster/install-linkerd.sh:10` (`curl -sL https://run.linkerd.io/install-edge | ... sh`),
  `edge/install-spire.sh:12-17` (resolve *latest* SPIRE tag from GitHub API, download
  tarball, no checksum/signature check), `cluster/gen-certs.sh:12-17` (download step-cli
  `.deb`, `dpkg -i`, no verification), `cluster/install-linkerd.sh:15` and
  `MANUAL.md:85` (`kubectl apply` remote Gateway API manifest), `retail-cloud.yaml:47`
  (`node:20-alpine`), `edge/extract-proxy.sh:10` (proxy image by version tag),
  `edge/run-app.sh:6` (`ealen/echo-server:latest`).
- **Risk / exploit:** `curl | sh` and unpinned/unchecked binaries mean a compromised
  or MITM'd upstream (or a moved `latest` tag) executes arbitrary code as the
  installing user (often root). No digests, no signature verification, no version
  pinning for SPIRE or step; container images are pulled by mutable tag, not digest.
- **Severity:** Medium.
- **Secure practice:** Pin exact versions and verify checksums/signatures (cosign,
  GPG, `sha256sum`) before executing; pin container images by digest; vendor or
  mirror manifests rather than applying remote URLs directly.

### M4. iptables root-egress exemption sends all root-originated traffic outside the mesh (cleartext, unauthenticated)
- **Where:** `edge/iptables.sh:18` (`-m owner --uid-owner 0 -j RETURN`),
  `MANUAL.md:288-304`.
- **Risk / exploit:** Every outbound TCP connection from a uid-0 process bypasses the
  proxy entirely — no mTLS, no identity, no policy. The exemption exists to stop the
  root proxy looping, but it also means *any* root process on the store egresses in
  cleartext with no mesh authorization. It is also the reason the app must run
  non-root (`--user 1000`); if an operator forgets, the workload silently loses mTLS
  and identity while appearing to work. Inbound side: the PREROUTING rule redirects
  *all* inbound TCP to 4143 except a fixed ignore list that includes 4190/4191
  (`iptables.sh:7,13`); 4191 is the proxy's admin/metrics port, left directly
  reachable.
- **Severity:** Medium.
- **Secure practice:** Run the proxy as a dedicated non-root uid and exempt only that
  uid, so root processes are not blanket-exempted; keep the app non-root by
  construction; ensure the proxy admin port (4191) is bound to loopback / not exposed.

### M5. retail-cloud pod runs as root with no securityContext, unbounded request bodies
- **Where:** `cluster/retail/retail-cloud.yaml:31-61` (no `securityContext`,
  `runAsNonRoot`, `readOnlyRootFilesystem`, or resource limits; app code delivered via
  mutable ConfigMap and mounted at `/app`), `retail-cloud/server.js:47-55,78-84`
  (accumulates `req` body into a string with no size cap on both `/ingest` and
  `/api/policy`).
- **Risk / exploit:** The web pod runs as root in-container by default and mounts the
  policy-mutating SA token (see H2b), maximizing the value of any code-exec bug.
  Unbounded body accumulation on both listeners allows a memory-exhaustion DoS. App
  code coming from a ConfigMap means anyone who can edit ConfigMaps in the namespace
  changes running app code without a registry/image gate.
- **Severity:** Medium.
- **Secure practice:** Set `runAsNonRoot: true`, drop capabilities, read-only rootfs,
  and CPU/memory limits; cap request body sizes; ship app code as a signed, pinned
  image rather than a ConfigMap; disable SA token automount unless required.

---

## LOW

### L1. Dashboard and APIs served over plaintext HTTP with no TLS or auth
- **Where:** `retail-cloud/server.js:62-91` (plain `http.createServer` on 8080),
  exposed via NodePort `:30080` (`cluster/retail/apply.sh:40-47`). `/api/data`
  (`server.js:67-75`) returns the identities in the clear.
- **Risk / exploit:** No transport encryption or authentication on the browser
  surface; traffic (including the void/restore control actions of H2) is sniffable and
  tamperable on the LAN/tailnet. Identity strings are disclosed (low sensitivity, but
  informative to an attacker).
- **Severity:** Low.
- **Secure practice:** Terminate TLS (ingress/gateway) and require auth for the UI and
  any control endpoints.

### L2. Ingest port (:8090) also published as a NodePort — unnecessary attack surface
- **Where:** `cluster/retail/retail-cloud.yaml:63-77` (`Service` type `NodePort`
  includes the `ingest`/8090 port).
- **Risk / exploit:** The meshed ingest port is enforced default-deny by the Linkerd
  `Server` (an unmeshed NodePort client presents no SPIFFE identity and is denied), so
  this is not directly bypassable — but publishing it on the node is needless surface
  and invites confusion/misconfiguration.
- **Severity:** Low.
- **Secure practice:** Expose only the UI port on the node; keep the ingest port
  cluster-internal.

### L3. SPIRE server, agent, root CA key, and the workload all co-located on one host, all as root
- **Where:** `edge/spire/agent.cfg:5` (`server_address = "localhost"`),
  `edge/install-spire.sh:25,33` (both run via `sudo nohup`), `MANUAL.md:212-214,224-230`.
- **Risk / exploit:** No separation of duties — control plane (server), node agent,
  signing key, and workload share a fate. Compromise of the box is compromise of
  everything (compounds H1/H3).
- **Severity:** Low (demo simplification; noted for honesty).
- **Secure practice:** Run the SPIRE server centrally and separately from agents;
  keep signing material off the workload host; least-privilege service accounts.

### L4. Fragile operational patterns: manual Ready patching and broad `pkill -f`
- **Where:** `cluster/retail/apply.sh:29-30` and `MANUAL.md:383-386` (manually forcing
  the ExternalWorkload `Ready` status), `edge/install-spire.sh:22,31` and
  `edge/run-proxy.sh:19` (`sudo pkill -f 'spire-server run'` etc.).
- **Risk / exploit:** Manually asserting `Ready` bypasses the health signal the mesh
  would otherwise compute. `pkill -f` matches on command-line substrings and can kill
  unrelated processes that happen to share the pattern. Operational/robustness rather
  than a direct exploit.
- **Severity:** Low.
- **Secure practice:** Let the workload's health drive readiness; target processes by
  PID/cgroup/systemd unit rather than `pkill -f`.

### L5. Legacy abstract-variant echo app uses host networking and a `:latest` image
- **Where:** `edge/run-app.sh:4-6` (`docker run --network host ... ealen/echo-server:latest`).
- **Risk / exploit:** `--network host` removes network namespace isolation (the
  container shares the host's interfaces/ports), and `ealen/echo-server` reflects
  request data back; `:latest` is unpinned. Part of the older CLI "beats" variant, not
  the main RetailCloud path, but shipped in the tree.
- **Severity:** Low.
- **Secure practice:** Pin the image by digest, avoid `--network host`, and don't run
  a request-reflecting echo server where request contents matter.

---

## Summary table (ranked)

| # | Title | Severity |
|---|---|---|
| H1 | Root CA private key copied off-cluster to the store (and staged in /tmp) | High |
| H2 | `/api/policy` mutates cluster authz with no auth, on the browser NodePort | High |
| H2b | retail-cloud SA + RBAC can rewrite MeshTLSAuthentication — lateral-movement prize | High |
| H3 | Identity bound only to `unix:uid:0` + proxy as root — any root proc gets the SVID | High |
| M1 | `insecure_bootstrap=true` + join-token on the command line | Medium |
| M2 | 10-year password-less root CA, long SVID TTLs, no revocation | Medium |
| M3 | Unverified/unpinned downloads (`curl\|sh`, latest SPIRE, unchecked .deb, :latest) | Medium |
| M4 | iptables uid-0 egress exemption bypasses the mesh for all root processes | Medium |
| M5 | retail-cloud runs as root, no securityContext, unbounded request bodies | Medium |
| L1 | Plaintext HTTP, no TLS/auth on the dashboard + control APIs | Low |
| L2 | Ingest port needlessly published as a NodePort | Low |
| L3 | SPIRE server+agent+CA key+workload co-located, all root | Low |
| L4 | Manual Ready patching and broad `pkill -f` | Low |
| L5 | Legacy echo app: `--network host` + `:latest` | Low |
