# SPIRE trust-architecture change (spiffe-cross-boundary) — design

**Status:** proposed (awaiting third-party review)
**Demo:** `demos/spiffe-cross-boundary/` (the RetailCloud demo)
**Author:** design produced via the superpowers brainstorming flow.

## Goal

Get the Linkerd **root CA private key off the edge** — the top finding of the demo's
security review — by moving to the accepted SPIRE topology (server in the cloud, agent
on the edge). While there, apply an endorsed third-party principle — **"simplify the
operational machinery, not the trust model"** — to harden the two other trust-model
weaknesses (workload attestation and bootstrap authentication), and to frame the
remaining operational simplifications honestly.

This is a teaching demo; the aim is that **every arrow in the trust contract
corresponds to a real security property**, while the operational machinery around it
stays deliberately small and clearly labelled.

## Problem domain

### Current architecture (what exists today)

- SPIRE **server and agent both run on the edge** machine.
- The edge holds the Linkerd **root** `ca.crt` **and** `ca.key`; the SPIRE server uses
  the root directly as `UpstreamAuthority "disk"`.
- Workload attestation is `unix:uid:0`; the `linkerd2-proxy` runs as **root**; iptables
  exempts uid 0 and redirects the app (uid 1000).
- The agent bootstraps with `insecure_bootstrap = true` (fine when server==agent host).
- Edge identity: `spiffe://root.linkerd.cluster.local/store-pos`.

### The three trust-model weaknesses (from the security review)

1. **Root key on the edge (High).** A compromise of the store host compromises the
   entire trust domain, with no revocation path. *This is the one the user asked to fix.*
2. **`unix:uid:0` workload attestation + proxy-as-root (High/Med).** Any root process on
   the edge that opens the Workload API socket can obtain the store's SVID.
3. **Trust-on-first-use bootstrap (Med).** Acceptable when the agent and server share a
   host; a real MITM exposure once the agent talks to a remote server.

### Constraints (Linkerd mesh-expansion realities)

- **The attested workload is the `linkerd2-proxy`, not the app.** The proxy calls the
  SPIRE Workload API and holds the SVID; it does mTLS on the app's behalf. The app never
  talks to SPIRE — its traffic is redirected into the proxy by iptables. So workload
  attestation must target the **proxy** process.
- **On a bare host the iptables redirect must be app-scoped.** You cannot "redirect
  everything except the proxy uid" as you would inside a pod netns — that would also
  capture the agent→server traffic, DNS, SSH, apt, and break the host. The redirect must
  match **only the app's uid**.
- **Trust domain is pinned to Linkerd's** `root.linkerd.cluster.local` (derived from the
  trust anchor). Only the SPIFFE **path** is free to make descriptive.
- **Two-VM demo over Tailscale.** Edge VM on this Mac; cluster VM on `orion-m1`. The edge
  already routes the cluster pod/service CIDRs and reaches the cluster node's tailnet IP.

## Solution space

### Chosen — server in Kubernetes, agent-only edge, workload attestation hardened

Move the SPIRE server into k3s as a StatefulSet; the edge runs the agent only; the
proxy runs as a dedicated non-root user attested by uid + binary path; the agent pins
the server bundle. See "Decisions" and "Design" below.

### Rejected — dedicated intermediate on the edge (keep server on the edge)

Give the edge SPIRE server a scoped **intermediate** (signed by the root) instead of the
root itself, so the root key stays in the cluster. **Rejected because** the live root is
`CA:TRUE, pathlen:1`; an intermediate makes the edge chain `root → edge-ca → SPIRE-CA →
leaf` (depth 2), which exceeds the root's path length. That forces **regenerating the
root and reinstalling Linkerd across the cluster** — a disruptive re-rooting. And
**independently of the path-length issue**, this topology would deliberately leave CA
signing material (the intermediate key) on the less-trusted edge host — the opposite of
the security objective. The chosen approach removes signing material from the edge
entirely and needs no re-rooting.

### Rejected — SPIRE server as a host process on the cluster node

Simpler (and already prototyped healthy), same trust property. **Rejected in favour of**
the in-cluster StatefulSet because k3s already hosts the cloud side (retail-cloud, the
Linkerd control plane), so an in-cluster SPIRE server is the coherent, conventional
placement *for this demo*. (In-cluster is a well-supported topology, **not** a SPIRE
requirement — SPIRE does not mandate server placement; the essential property is that
the server is central and off the edge.) The host-process variant remains the documented
fallback if the k8s deployment proves fragile.

### Rejected — do nothing, keep documenting

The demo already documents these as shortcuts. **Rejected because** the user explicitly
asked to fix the root-key exposure, and the endorsed principle is to fix *trust-model*
weaknesses (as opposed to operational machinery).

## Decisions

- **Scope:** full — root-key topology fix **and** workload-attestation hardening **and**
  the pedagogical touches (descriptive SPIFFE path, dashboard enrollment panel, honest
  join-token framing).
- **SPIRE server placement:** in-cluster **StatefulSet** in k3s (namespace `spire`),
  single replica, sqlite on a volume, root cert+key as a k8s **Secret**,
  `UpstreamAuthority "disk"` → that Secret.
- **Edge reachability:** the server API is exposed via a **NodePort** (`:30081`); the edge
  agent dials `<cluster-node-addr>:30081`. (Reachable directly over Tailscale; not via the
  pod-CIDR route.) **Invariant (defense in depth):** `:30081` is reachable from the edge
  over the **Tailscale path only**, not intentionally exposed on unrelated node interfaces
  — enforced via a host firewall rule or kube-proxy `--nodeport-addresses` scoped to the
  tailnet CIDR. The pinned bundle + join-token + root-chained server cert are the actual
  identity boundary; interface scoping is *only* defense in depth.
- **Bootstrap:** the agent pins the server's trust bundle (`trust_bundle_path`);
  `insecure_bootstrap` is **removed** (defaults false).
- **Workload attestation:** the proxy runs as a dedicated **non-root user (uid 2102**, the
  same uid the in-cluster proxy uses); the registration entry's selectors are
  **`unix:uid:2102` + `unix:path:/opt/linkerd-proxy/linkerd-proxy`**. This is
  **least-privilege isolation between ordinary processes**, not a boundary against
  host-root (see Security boundaries). The `unix` WorkloadAttestor **must** set
  `discover_workload_path = true` (and `workload_size_limit = -1`, since we don't use the
  `unix:sha256` selector) — otherwise it never emits `unix:path` and attestation fails.
- **iptables:** OUTPUT redirect matches **only the app's uid (1000)** → the proxy's
  outbound port; no blanket root exemption; inbound redirect dropped (the push-only store
  is a client, not a server).
- **Identity:** SVID path becomes `spiffe://root.linkerd.cluster.local/store/042/inventory-sync`;
  trust domain unchanged. k8s object/label names kept (`store-pos`) to bound churn.
- **Kept & documented (not fixed):** single SPIRE replica + sqlite; **join-token**
  enrollment (a legitimate one-time node-attestation mechanism — production binds
  enrollment to a **device identity**: TPM/DevID, enterprise PKI, or cloud instance
  identity); **root-key storage** — the Linkerd trust-anchor private key now lives in a
  k8s Secret in the cluster (the important correction is that it *left the edge*; a
  production deployment would protect the root via external/offline PKI, an HSM, or Vault,
  **not** a cluster Secret); the cloud **Void-button RBAC** (the one place a workload
  mutates its own authorization policy, kept for the interactive moment).

## Design

### Cloud side (new)

- `namespace/spire`.
- `Secret/spire-upstream-ca` — `ca.crt` + `ca.key` (from the cluster's `~/linkerd-certs`).
- `ConfigMap/spire-server` — `server.cfg`: `bind_address 0.0.0.0:8081`, trust domain
  `root.linkerd.cluster.local`, `DataStore "sql"` (sqlite on the pod volume),
  `KeyManager "disk"` (pod volume), `NodeAttestor "join_token"`,
  `UpstreamAuthority "disk"` → the mounted Secret.
- `StatefulSet/spire-server` — 1 replica, official `spire-server` image pinned by
  version, mounts the ConfigMap + Secret + a data volume.
- **Pod hardening (cheap least-privilege, since this pod holds the demo's most sensitive
  credential):** the CA Secret mounted **read-only**; a dedicated `spire-server`
  ServiceAccount with `automountServiceAccountToken: false` (join-token attestation needs
  no Kubernetes API); no extra RBAC; everything confined to the `spire` namespace.
- `Service/spire-server` — type **NodePort**, `8081 → 30081`, scoped to the tailnet per
  the reachability invariant above (host firewall / kube-proxy `--nodeport-addresses`).
- Registration workflow via `kubectl -n spire exec`:
  - `bundle show` → the pinned bootstrap bundle for the edge.
  - `token generate -spiffeID …/store/042/agent` → the enrollment token.
  - `entry create -parentID …/store/042/agent -spiffeID …/store/042/inventory-sync
    -selector unix:uid:2102 -selector unix:path:/opt/linkerd-proxy/linkerd-proxy`.

### Edge side (changed)

- **Remove** `ca.key` from `/opt/spire/certs`; keep `ca.crt` (proxy trust anchors only).
  **Remove** the SPIRE server (binary/config/process).
- `agent.cfg`: `server_address = <cluster-node-addr>`, `server_port = 30081`,
  `trust_bundle_path = /opt/spire/certs/bundle.pem`, `NodeAttestor "join_token"`,
  `KeyManager "disk"`, and
  `WorkloadAttestor "unix" { plugin_data { discover_workload_path = true, workload_size_limit = -1 } }`.
  No `insecure_bootstrap`.
- Create user `linkerd-proxy` (uid 2102). `run-proxy.sh` launches the proxy **as 2102**
  (not root). The proxy reads the public Workload API socket; the `unix` attestor sees
  uid 2102 + the proxy binary path and matches the entry.
- `iptables.sh`: single OUTPUT rule redirecting the **app uid (1000)** TCP → 4140; leave
  the proxy (2102) and all system traffic untouched. The desired invariant is simply:
  *app uid 1000 → Linkerd proxy; all other host traffic → normal networking.* Because the
  redirect matches only uid 1000, the SPIRE agent's traffic (root) is never captured
  **regardless of ordering** — there is no setup-ordering dependency (verified by
  restarting the agent *after* iptables and confirming it reconnects).

### Identity / policy / app updates

- `config.local.env`: `EDGE_SPIFFE_ID`, `EDGE_SERVER_NAME`, and the proxy env in
  `run-proxy.sh` use `…/store/042/inventory-sync`.
- `ExternalWorkload.meshTLS.identity` and `MeshTLSAuthentication.spec.identities` use the
  new SVID string. `retail-cloud/server.js` / `store-pos/server.js` identity constants
  updated.

### Dashboard panel (RetailCloud aesthetic)

A per-store block that separates enrollment from workload identity:

```
Store 042
  Node enrollment   ✓ Enrolled with a one-time demo token
                      Production: device-bound identity (TPM or enterprise PKI)
  Workload identity ✓ spiffe://…/store/042/inventory-sync
                      held by the local Linkerd proxy
  Connection        ✓ mTLS authenticated
  Cloud service     ✓ inventory ingest
```

The "held by the local Linkerd proxy" line keeps the application-level naming while
accurately stating *where* the credential lives (the proxy obtains and holds the SVID;
the app does not).

## Error handling / failure signatures (for verification & teaching)

- **Agent can't reach server** → agent log: dial/timeout to `<addr>:30081`; no SVIDs
  served; proxy never certifies.
- **Bad/expired join token** → agent attestation rejected at bootstrap; no node SVID.
- **A process that doesn't match `uid:2102`+path** → agent serves no SVID to that caller;
  it stays uncertified. This is the *desired* least-privilege behaviour: an unrelated
  process (including one running as root but not as uid 2102) does not get the store
  identity merely by reaching the socket. (It is **not** a defense against host-root — see
  Security boundaries.)
- **Bundle mismatch** → agent refuses the server on bootstrap (pinned bundle working).

## Verification (on the live two-VM demo)

Functional: proxy certifies as `…/store/042/inventory-sync`; store reports **200**;
**Void** → **403**; `linkerd viz tap` shows `client_id` = that ID and
`src_external_workload`.

Security-specific:
- `ca.key` is **absent** on the edge (`! test -e /opt/spire/certs/ca.key`).
- The agent bootstrap uses the **pinned bundle** (no `insecure_bootstrap`).
- The proxy attestation produces **both** `unix:uid:2102` **and**
  `unix:path:/opt/linkerd-proxy/linkerd-proxy` selectors (confirm before calling the
  workload-attestation change complete — proves `discover_workload_path` is in effect).
- An **unrelated uid-0** process that opens the Workload API socket does **not** match the
  registration (`uid:2102` + path) and receives **no** store SVID — least-privilege
  isolation between ordinary processes. (This does **not** defend against full host-root
  compromise; see Security boundaries.)
- The proxy process runs as **uid 2102**, not 0.
- **No setup-ordering dependency:** restart the SPIRE agent *after* iptables is installed;
  it reconnects to the server and workloads re-attest (proves the network rules are
  correct, not accidentally reliant on ordering).

## Security boundaries (what this does and does not protect)

The demo states two limitations explicitly, in the dashboard/docs, so the security claims
are honest:

- **Demo PKI simplification:** the root CA key is removed from the edge but is stored in a
  Kubernetes Secret in the cluster — **not** protected by external/offline PKI, an HSM, or
  Vault. The correction that matters is that the key left the less-trusted edge host; its
  in-cluster custody is still a demo simplification.
- **Edge host trust assumption:** full **root compromise** of the store host can
  compromise that store's node and workload identities (root can run the permitted binary
  as the permitted uid, or attack the agent and read its locally-stored node credentials).
  UID + executable-path workload attestation provides **least-privilege isolation between
  ordinary processes**, not a boundary against a hostile host administrator.

The trust contract — every arrow a real property:

```
pinned cloud trust anchor
        │
one-time node enrollment (join token)
        │
authenticated store SPIRE agent (rotating node SVID)
        │
uid + executable-path workload matching
        │
Linkerd proxy obtains a short-lived SVID
        │
Linkerd mTLS
        │
identity-based cloud authorization (the Void moment)
```

## What is explicitly NOT changed

Single-replica sqlite SPIRE server; join-token enrollment; in-cluster (Secret) root-key
storage; the cloud Void-button RBAC; the Tailscale/route/DNS connectivity shim; the trust
domain string. All remain documented in
`demos/spiffe-cross-boundary/PRODUCTION-NOTES.md`, which this change updates (the root-key
*on-the-edge* finding becomes resolved; the join-token framing is corrected; the
workload-attestation and bootstrap findings become resolved, re-scoped as least-privilege
per the review).

## Open questions

- **`unix:sha256`:** *resolved* — not baked in. It doesn't change the host-root boundary
  and adds upgrade bookkeeping (the hash changes every proxy upgrade); documented as an
  optional production tightening only.
- **NodePort vs hostNetwork:** *resolved* — NodePort, scoped to the tailnet (host firewall
  / kube-proxy `--nodeport-addresses`). Revisit only if NodePort→edge over Tailscale
  misbehaves.
- **Descriptive rename depth:** identity string changes to `…/store/042/inventory-sync`;
  whether to also rename k8s objects/labels from `store-pos` (deferred — more churn, no
  security value).

## Provenance

- Security + best-practice review of the demo (two sub-agent passes) →
  `demos/spiffe-cross-boundary/PRODUCTION-NOTES.md`.
- Endorsed third-party recommendation ("simplify the operational machinery, not the
  trust model"; SPIRE server in the cloud, agent on the store, one-time join-token
  enrollment, dedicated-user workload attestation, don't expose the Workload API over the
  network, disclose the node-bootstrap simplification).
- Technical corrections folded in during design: the attested workload is the proxy (not
  the app); the bare-host iptables redirect must be app-scoped; the trust domain is
  Linkerd-pinned (only the path is free); the cloud Void-button RBAC stays a documented
  shortcut.
- Derisk prototype confirmed a SPIRE server runs healthy and reachable on the cluster VM.
- **Third-party design review (round 1, "revise then approve")** folded into this
  revision: (required) enable `discover_workload_path` so the `unix:path` selector is
  actually produced; (required) re-scope the UID+path claim to least-privilege isolation,
  not host-root defense. (recommended, all adopted) constrain the NodePort to the Tailscale
  boundary; document in-cluster Secret root-key storage as a simplification and drop the
  "in-cluster = best practice" framing; remove the iptables-ordering caveat and prove it
  via an agent restart; cheap SPIRE-server pod hardening (read-only Secret, dedicated SA,
  `automountServiceAccountToken: false`, no extra RBAC); "held by the local Linkerd proxy"
  in the UI; strengthen the edge-intermediate rejection (leaves signing material on the
  less-trusted host regardless of the path-length issue).
