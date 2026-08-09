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
root and reinstalling Linkerd across the cluster** — a disruptive re-rooting — and it
still leaves a signing key (the intermediate) on the less-trusted edge host. The chosen
approach removes signing material from the edge entirely and needs no re-rooting.

### Rejected — SPIRE server as a host process on the cluster node

Simpler (and already prototyped healthy), same trust property. **Rejected in favour of**
the in-cluster StatefulSet because the accepted best practice places the SPIRE server
as an in-cluster workload, and the demo optimizes for teaching the real topology. The
host-process variant remains the documented fallback if the k8s deployment proves
fragile.

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
  pod-CIDR route.)
- **Bootstrap:** the agent pins the server's trust bundle (`trust_bundle_path`);
  `insecure_bootstrap` is **removed** (defaults false).
- **Workload attestation:** the proxy runs as a dedicated **non-root user (uid 2102**, the
  same uid the in-cluster proxy uses); the registration entry's selectors are
  **`unix:uid:2102` + `unix:path:/opt/linkerd-proxy/linkerd-proxy`**.
- **iptables:** OUTPUT redirect matches **only the app's uid (1000)** → the proxy's
  outbound port; no blanket root exemption; inbound redirect dropped (the push-only store
  is a client, not a server).
- **Identity:** SVID path becomes `spiffe://root.linkerd.cluster.local/store/042/inventory-sync`;
  trust domain unchanged. k8s object/label names kept (`store-pos`) to bound churn.
- **Kept & documented (not fixed):** single SPIRE replica + sqlite; **join-token**
  enrollment (a legitimate one-time node-attestation mechanism — production binds
  enrollment to a **device identity**: TPM/DevID, enterprise PKI, or cloud instance
  identity); the cloud **Void-button RBAC** (the one place a workload mutates its own
  authorization policy, kept for the interactive moment).

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
- `Service/spire-server` — type **NodePort**, `8081 → 30081`.
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
  `WorkloadAttestor "unix"`, `KeyManager "disk"`. No `insecure_bootstrap`.
- Create user `linkerd-proxy` (uid 2102). `run-proxy.sh` launches the proxy **as 2102**
  (not root). The proxy reads the public Workload API socket; the `unix` attestor sees
  uid 2102 + the proxy binary path and matches the entry.
- `iptables.sh`: single OUTPUT rule redirecting the **app uid (1000)** TCP → 4140; leave
  the proxy (2102) and all system traffic untouched. (Enroll the agent first, so the
  agent↔server connection predates any redirect and is never captured anyway.)

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
  Connection        ✓ mTLS authenticated
  Cloud service     ✓ inventory ingest
```

## Error handling / failure signatures (for verification & teaching)

- **Agent can't reach server** → agent log: dial/timeout to `<addr>:30081`; no SVIDs
  served; proxy never certifies.
- **Bad/expired join token** → agent attestation rejected at bootstrap; no node SVID.
- **Proxy uid/path doesn't match the entry** → agent serves no SVID to that caller;
  proxy stays uncertified. (This is the *desired* behaviour for a non-matching process —
  it is the security property, demonstrated by the "root process gets nothing" check.)
- **Bundle mismatch** → agent refuses the server on bootstrap (pinned bundle working).

## Verification (on the live two-VM demo)

Functional: proxy certifies as `…/store/042/inventory-sync`; store reports **200**;
**Void** → **403**; `linkerd viz tap` shows `client_id` = that ID and
`src_external_workload`.

Security-specific:
- `ca.key` is **absent** on the edge (`! test -e /opt/spire/certs/ca.key`).
- The agent bootstrap uses the **pinned bundle** (no `insecure_bootstrap`).
- A **root** process on the edge that opens the Workload API socket receives **no** SVID
  for the store identity (attestation is the proxy's uid 2102 + path).
- The proxy process runs as **uid 2102**, not 0.

## What is explicitly NOT changed

Single-replica sqlite SPIRE server; join-token enrollment; the cloud Void-button RBAC;
the Tailscale/route/DNS connectivity shim; the trust domain string. All remain
documented in `demos/spiffe-cross-boundary/PRODUCTION-NOTES.md`, which this change
updates (the root-key finding becomes resolved; the join-token framing is corrected;
the workload-attestation and bootstrap findings become resolved).

## Open questions

- **Proxy as uid 2102 specifics:** whether to also pin `unix:sha256` of the proxy binary
  in the selector (stronger, but the hash changes on every proxy upgrade — likely
  document it as the production tightening rather than bake it in).
- **NodePort vs hostNetwork** for the server API: NodePort chosen for cleanliness; revisit
  if NodePort→edge reachability over Tailscale misbehaves.
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
