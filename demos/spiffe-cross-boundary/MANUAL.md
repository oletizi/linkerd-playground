# SPIFFE for an external workload — a from-scratch manual

The [README](README.md) automates this setup with scripts. This document performs the
same setup by hand, explaining every configuration file and command involved in
giving a non-Kubernetes workload a SPIFFE identity and joining it to a Linkerd mesh.

The worked example is **RetailCloud**: a point-of-sale service (`store-pos`) runs on
a machine outside Kubernetes and sends inventory and sales data to a cloud
application (`retail-cloud`) running in the cluster. The cloud service accepts the
data only from the store's verified SPIFFE identity. The sections below build this
configuration incrementally.

> **This is a teaching demo, not a production blueprint.** It takes deliberate
> shortcuts — for example, the dashboard app holds permission to change its own
> authorization policy — to keep the mechanics legible in one sitting. Do not run this configuration in a real
> environment. [Production notes](PRODUCTION-NOTES.md) lists every shortcut and what to
> do instead.

> Convention: commands prefixed `[cloud]` run on the Kubernetes host; `[store]` run
> on the external machine. The trust domain throughout is
> `root.linkerd.cluster.local` (Linkerd's default).

---

## The mental model

Four things have to line up:

1. **A single root of trust.** Linkerd already issues every pod a certificate from a
   root CA (the *trust anchor*). We will make the external workload's certificates
   chain to that *same* root, so both sides validate each other. The result is one
   trust domain spanning two machines.
2. **An identity source on the external machine.** In the cluster, the control-plane
   component `linkerd-identity` issues certificates, trusting a pod's Kubernetes
   ServiceAccount. Off-cluster there is no Kubernetes, so **SPIRE** plays that role:
   it attests the local process and issues it a short-lived SVID.
3. **A data-plane proxy on the external machine.** A standalone `linkerd2-proxy`
   runs next to the workload, gets its identity from SPIRE, and does mTLS on the
   workload's behalf — exactly like an injected sidecar does in the cluster.
4. **The cluster's awareness of the workload.** An `ExternalWorkload` resource tells
   Linkerd this off-cluster process exists and what identity it carries, so policy
   and discovery treat it like any other mesh endpoint.

A fifth thing is a *prerequisite, not part of SPIFFE*: the two machines need plain
IP reachability (the proxy dials cluster pod IPs and resolves cluster DNS). SPIFFE
gives you identity; it does not give you connectivity.

---

## Prerequisites

- **Two Linux hosts** that can reach each other over IP. (On macOS, run each in a
  Linux VM — note that default VM networking often isolates guests from one another;
  you may need a shared VM-to-VM network, e.g. Lima's `user-v2`, or the
  [Tailscale recipe](connectivity-tailscale.md). This reachability is a precondition,
  covered in Part 2.)
- On the **cloud** host: a Kubernetes cluster (k3s is fine) and the `linkerd` CLI
  (edge channel — mesh expansion needs 2.15+), plus [`step`](https://smallstep.com/docs/step-cli/)
  to make certificates.
- On the **store** host: the SPIRE **agent** binary (`spire-agent`) — the server runs
  in the cluster (Part 3), so the store never needs `spire-server` — a container
  runtime (Docker/Podman) to run the app, and `iptables`.
- Pick one Linkerd edge version and use it everywhere — the standalone proxy binary
  must match the control plane. We'll call it `$LINKERD_VERSION` (e.g. `edge-26.7.2`).

---

## Part 1 — One root of trust (cloud)

Linkerd's identity system has two certificates: a long-lived **trust anchor** (the
root CA) and a shorter-lived **issuer** (an intermediate) that actually signs proxy
certs. Normally `linkerd install` generates both for you and you never see the root
key. We generate the pair ourselves so the in-cluster SPIRE server (Part 3) can use the
root as its `UpstreamAuthority` — the root key stays in the cluster the whole time.

```bash
[cloud] step certificate create root.linkerd.cluster.local ca.crt ca.key \
          --profile root-ca --no-password --insecure --not-after=87600h

[cloud] step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
          --profile intermediate-ca --not-after 8760h --no-password --insecure \
          --ca ca.crt --ca-key ca.key
```

- `root.linkerd.cluster.local` is the trust anchor's common name; the trust domain
  in every SPIFFE ID derives from it.
- Linkerd requires **ECDSA P-256** keys — `step` uses that profile by default.
- Keep `ca.crt` **and** `ca.key` here in the cluster: the in-cluster SPIRE server mounts
  them (as a read-only Secret) to sign the external workload's certificates. The key never
  goes to the store.

> **Demo shortcut:** this root is a password-less, 10-year, self-signed *software* root
> written straight to disk — quick to generate and inspect, but with no HSM, no encryption
> at rest, and no rotation or revocation plan. Production backs the root with an HSM or
> managed CA and defines rotation and cross-signing up front. See
> [Production notes → Security shortcuts](PRODUCTION-NOTES.md#security-shortcuts) and
> [Trust & CA](PRODUCTION-NOTES.md#trust--ca).

Install Linkerd with these certs instead of generated ones. Linkerd needs the
Gateway API CRDs present first:

```bash
[cloud] kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
[cloud] linkerd install --crds | kubectl apply -f -
[cloud] linkerd install \
          --identity-trust-anchors-file ca.crt \
          --identity-issuer-certificate-file issuer.crt \
          --identity-issuer-key-file issuer.key | kubectl apply -f -
[cloud] linkerd check
```

- `--identity-trust-anchors-file ca.crt` pins the root every proxy in the cluster
  will trust. Because the in-cluster SPIRE server signs under the matching `ca.key`, the
  SVIDs it issues to the off-cluster workload chain to this root and the cluster accepts
  them.

> **Demo shortcut:** the Gateway API CRDs and Linkerd here — and `step` and the SPIRE
> tooling in the prerequisites — are pulled from unpinned, unverified sources. Production
> pins exact versions and verifies checksums and signatures for all tooling and images.
> See [Production notes → Security shortcuts](PRODUCTION-NOTES.md#security-shortcuts).

Install the viz extension now — Part 8's verification uses `linkerd viz tap`, and
installing it *before* the workloads means their proxies are tap-enabled from the
start (installing viz later requires a `kubectl rollout restart` on each workload for
`tap` to see it):

```bash
[cloud] linkerd viz install | kubectl apply -f -
```

---

## Part 2 — The networking prerequisite (store)

Before any SPIFFE, the store's proxy must be able to reach the cluster's control
plane and, later, its data-plane peers. Concretely the store needs:

- an L3 route to the cluster **pod CIDR** and **service CIDR** (k3s defaults
  `10.42.0.0/16` and `10.43.0.0/16`), and
- DNS resolution for `*.cluster.local` (so it can find `linkerd-dst-headless`,
  `linkerd-policy`, and `retail-cloud`).

How you satisfy this is up to your network (a flat LAN, a VPN, an overlay). On a
flat LAN it's a static route plus a resolver entry — nothing Linkerd-specific:

```bash
[store] sudo ip route add 10.42.0.0/16 via <cloud-host-ip>
[store] sudo ip route add 10.43.0.0/16 via <cloud-host-ip>
[store] printf '[Resolve]\nDNS=10.43.0.10\nDomains=~cluster.local\n' \
          | sudo tee /etc/systemd/resolved.conf.d/cluster.conf
[store] sudo systemctl restart systemd-resolved
```

`10.43.0.10` is the cluster's CoreDNS ClusterIP (`kubectl -n kube-system get svc
kube-dns`). The pod/service CIDRs and this DNS IP are **k3s defaults, not portable** —
on any other cluster, discover yours (`kubectl -n kube-system get svc kube-dns` for
CoreDNS; your distro's config for the CIDRs) and substitute them wherever they recur
below (Part 4's proxy reaches the control plane over these). The cloud host must have
IP forwarding on so it routes the store's traffic into the pod network. This is the distinction between identity and
connectivity: SPIFFE provides identity; this step provides connectivity.

---

## Part 3 — An identity source: SPIRE server in the cloud, agent on the store

SPIRE has two roles. The **server** issues identities and holds signing authority; it
runs in the cloud next to the rest of the control plane and never exposes its signing key
to the store. The **agent** runs on the store, attests local processes, and hands them
SVIDs the server issued — over a local socket. This is SPIRE's normal topology, and it
keeps the root key off the less-trusted store host.

### 3a. Deploy the SPIRE server (cloud)

Run the server in the cluster, using the Linkerd root as its `UpstreamAuthority` so the
SVIDs it issues chain to the same anchor the mesh trusts. The root cert **and** key are
mounted as a read-only Kubernetes Secret — they stay in the cluster.

`server.cfg` (mounted from a ConfigMap):

```hcl
server {
    bind_address = "0.0.0.0"
    bind_port = "8081"
    trust_domain = "root.linkerd.cluster.local"
    data_dir = "/run/spire/data"
    ca_ttl = "168h"
    default_x509_svid_ttl = "48h"
}
plugins {
    DataStore "sql" { plugin_data { database_type = "sqlite3"
        connection_string = "/run/spire/data/datastore.sqlite3" } }
    KeyManager "disk" { plugin_data { keys_path = "/run/spire/data/keys.json" } }
    NodeAttestor "join_token" { plugin_data {} }
    UpstreamAuthority "disk" {
        plugin_data {
            cert_file_path = "/run/spire/secret/ca.crt"   # mounted from the Secret
            key_file_path  = "/run/spire/secret/ca.key"
        }
    }
}
```

Deploy it as a StatefulSet with the root as a Secret and a NodePort the store's agent can
reach (the demo does this in `cluster/spire/`), and restrict that NodePort to your overlay
(a host firewall rule scoped to the Tailscale interface):

```bash
[cloud] kubectl create namespace spire
[cloud] kubectl -n spire create secret generic spire-upstream-ca \
          --from-file=ca.crt=ca.crt --from-file=ca.key=ca.key      # root stays here, in-cluster
[cloud] kubectl -n spire create configmap spire-server-config --from-file=server.cfg
[cloud] kubectl apply -f spire-server.yaml                          # StatefulSet + NodePort :30081
```

> **Demo shortcut:** the server's datastore is SQLite, its signing keys live on disk
> (`KeyManager "disk"`), and it runs as a single StatefulSet replica with no HA.
> Production uses a networked RDBMS with managed backups, a KMS/HSM-backed KeyManager, and
> an HA server behind a stable endpoint. See
> [Production notes → SPIRE topology](PRODUCTION-NOTES.md#spire-topology).

- `UpstreamAuthority "disk"` is the key setting: SPIRE signs under Linkerd's root, so
  every SVID chains to the anchor the mesh already trusts — **without the root key ever
  leaving the cluster.**

> **Demo shortcut:** that root is delivered as a Kubernetes Secret and read from disk
> (`UpstreamAuthority "disk"`). Keeping the key in-cluster is the honest boundary this demo
> draws, but a cluster Secret is not HSM or offline-root custody. Production backs the root
> with external/offline PKI, an HSM, or Vault, and has SPIRE chain to a scoped intermediate
> rather than signing under the root directly. See
> [Production notes → The ones that matter most](PRODUCTION-NOTES.md#the-ones-that-matter-most)
> and [Trust & CA](PRODUCTION-NOTES.md#trust--ca).

- `NodeAttestor "join_token"` is how *agents* prove which node they are — a one-time
  enrollment token (3b).

> **Demo shortcut:** `join_token` node attestation is a one-time bearer token — legitimate,
> but production commonly binds enrollment to a hardware/device identity (TPM/DevID) or a
> cloud instance identity (`aws_iid`, `gcp_iit`, `k8s_psat`, `x509pop`). See
> [Production notes → Attestation](PRODUCTION-NOTES.md#attestation).

### 3b. Enroll the store's agent (store)

The store runs the **agent only**. It authenticates the server with a **pinned trust
bundle** (not trust-on-first-use), and attests itself with a one-time join token.

Export the server's bundle and mint a token on the cloud, then copy the bundle to the
store (only the public cert material and a single-use token leave the cluster — never the
key):

```bash
[cloud] kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server bundle show > bundle.pem
[cloud] kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server token generate \
          -spiffeID spiffe://root.linkerd.cluster.local/store/042/agent
# Copy BOTH public files to the store (only public material + a single-use token leave the cluster):
#   bundle.pem -> /opt/spire/certs/bundle.pem   (the agent's pinned server bundle)
#   ca.crt     -> /opt/spire/certs/ca.crt       (from Part 1; the trust anchor the proxy reads in Part 4c)
```

`agent.cfg` on the store:

```hcl
agent {
    data_dir = "/opt/spire/data/agent"
    trust_domain = "root.linkerd.cluster.local"
    server_address = "<cloud-node-addr>"
    server_port = 30081
    trust_bundle_path = "/opt/spire/certs/bundle.pem"    # pinned; no insecure_bootstrap
}
plugins {
    KeyManager "disk" { plugin_data { directory = "/opt/spire/data/agent" } }
    NodeAttestor "join_token" { plugin_data {} }
    WorkloadAttestor "unix" {
        plugin_data {
            discover_workload_path = true     # required to emit the unix:path selector
            workload_size_limit    = -1       # we don't use unix:sha256, so skip hashing
        }
    }
}
```

```bash
[store] sudo spire-agent run -config /opt/spire/agent.cfg -joinToken "$TOKEN"   # (a service unit in practice)
[store] sudo spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
```

> **Demo shortcut:** the agent's pinned trust bundle is a file copied to the store by hand,
> and the agent runs as a bare process (the `# (a service unit in practice)` note above)
> rather than under supervision. Production distributes bundles via a SPIFFE trust-bundle
> endpoint / federation and runs the agent as a supervised service (a systemd unit, or a
> DaemonSet for in-cluster agents) with restart policies. See
> [Production notes → Trust & CA](PRODUCTION-NOTES.md#trust--ca) and
> [SPIRE topology](PRODUCTION-NOTES.md#spire-topology).

- The `spire-server` binary inside the container lives at `/opt/spire/bin/` and is
  **not on `$PATH`**, so every `kubectl exec … spire-server` command here (and the
  registration in 3c) invokes it by full path.
- `trust_bundle_path` pins the server: the agent authenticates the server's certificate
  against this bundle. `insecure_bootstrap` (trust-on-first-use) is **not** used now that
  the agent talks to a *remote* server.
- `discover_workload_path = true` is required for the `unix:path` selector in 3c — without
  it the attestor never emits a path selector and attestation fails.
- The agent exposes the **SPIFFE Workload API** on a local Unix socket
  (`/tmp/spire-agent/public/api.sock`); the proxy reads its identity from there. This
  socket stays **local** to the store — it is never exposed over the network.

### 3c. Register the workload (cloud)

Registration says which *identity* a given process may receive — an administrative act
against the server. Do it on the cloud:

```bash
[cloud] kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry create \
          -parentID spiffe://root.linkerd.cluster.local/store/042/agent \
          -spiffeID spiffe://root.linkerd.cluster.local/store/042/inventory-sync \
          -selector unix:uid:2102 \
          -selector unix:path:/opt/linkerd-proxy/linkerd-proxy
```

> **Demo shortcut:** each workload identity is registered by hand with
> `spire-server entry create`. Production drives registration from the SPIRE Controller
> Manager (`ClusterSPIFFEID` CRDs) or a registrar/GitOps pipeline. See
> [Production notes → Lifecycle & automation](PRODUCTION-NOTES.md#lifecycle--automation).

- `-spiffeID …/store/042/inventory-sync` is the identity to grant.
- `-parentID …/store/042/agent` is the store's agent (attested in 3b) that will deliver it.
- The **two selectors** are the condition: the caller must be **uid 2102** **and** the
  proxy binary at that path. That is the `linkerd2-proxy`, which runs as a dedicated
  non-root user (Part 4) and holds the SVID on the app's behalf. This is
  **least-privilege isolation between ordinary processes** — an unrelated process (even
  one running as root) does not match, so it does not get this identity.

> **Demo shortcut:** `unix:uid` + `unix:path` attestation isolates ordinary processes, but
> it is **not** a defense against a full root compromise of the store host, which could run
> the permitted binary as the permitted uid. See
> [Production notes → Security boundaries](PRODUCTION-NOTES.md#security-boundaries-what-this-does-and-does-not-protect)
> and [Attestation](PRODUCTION-NOTES.md#attestation).

---

## Part 4 — The data-plane proxy on the store

### 4a. Get the proxy binary

The standalone proxy is the same binary shipped in Linkerd's sidecar image; extract
it, matching the control-plane version exactly.

```bash
[store] id=$(sudo docker create cr.l5d.io/linkerd/proxy:$LINKERD_VERSION)
[store] sudo docker cp "$id:/usr/lib/linkerd/linkerd2-proxy" /opt/linkerd-proxy/linkerd-proxy
[store] sudo docker rm -v "$id"
```

> **Demo shortcut:** the proxy binary is hand-extracted from the image and kept in
> version-match by discipline (`$LINKERD_VERSION`), and the image is pulled by tag rather
> than digest. Production ships the proxy as a versioned, signed package with automated
> version-match checks, and pins images by digest. See
> [Production notes → Lifecycle & automation](PRODUCTION-NOTES.md#lifecycle--automation)
> and [Security shortcuts](PRODUCTION-NOTES.md#security-shortcuts).

### 4b. Redirect traffic through the proxy (iptables)

The proxy only helps if the workload's traffic passes through it. On a bare host you
can't redirect "everything except the proxy" the way a pod's network namespace does —
that would also capture the SPIRE agent, DNS, SSH, and the proxy's own egress and break
the box. So the redirect is **scoped to the app's uid**: only the store-pos app (uid
1000) has its outbound sent to the proxy; everything else on the host is left alone.

```bash
[store] sudo iptables -t nat -N PROXY_APP_OUTPUT
[store] sudo iptables -t nat -A PROXY_APP_OUTPUT -o lo -j RETURN
[store] sudo iptables -t nat -A PROXY_APP_OUTPUT -p tcp -j REDIRECT --to-port 4140
[store] sudo iptables -t nat -A OUTPUT -m owner --uid-owner 1000 -p tcp -j PROXY_APP_OUTPUT
```

The invariant is simply: **app uid 1000 → the proxy; all other host traffic → normal
networking.** Because only uid 1000 is redirected, there is no blanket root exemption and
no setup-ordering dependency — the SPIRE agent (running as root) is never captured, so it
can enroll before or after these rules are in place.

### 4c. Launch the proxy — identity from SPIRE

The proxy is configured entirely through environment variables:

```bash
[store] export LINKERD2_PROXY_IDENTITY_SERVER_ID="spiffe://root.linkerd.cluster.local/store/042/inventory-sync"
[store] export LINKERD2_PROXY_IDENTITY_SERVER_NAME="inventory-sync.cluster.local"
[store] export LINKERD2_PROXY_POLICY_WORKLOAD='{"ns":"mixed-env","external_workload":"store-pos"}'
[store] export LINKERD2_PROXY_DESTINATION_CONTEXT='{"ns":"mixed-env","nodeName":"store","external_workload":"store-pos"}'
[store] export LINKERD2_PROXY_DESTINATION_SVC_ADDR="linkerd-dst-headless.linkerd.svc.cluster.local.:8086"
[store] export LINKERD2_PROXY_DESTINATION_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
[store] export LINKERD2_PROXY_POLICY_SVC_ADDR="linkerd-policy.linkerd.svc.cluster.local.:8090"
[store] export LINKERD2_PROXY_POLICY_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
[store] export LINKERD2_PROXY_IDENTITY_SPIRE_WORKLOAD_API_ADDRESS="unix:///tmp/spire-agent/public/api.sock"
[store] export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"
# Run the proxy as a dedicated non-root user (uid 2102), not root:
[store] sudo useradd -M -u 2102 -s /usr/sbin/nologin linkerd-proxy
[store] sudo -E setpriv --reuid=2102 --regid=2102 --clear-groups /opt/linkerd-proxy/linkerd-proxy
```

What each group does:

- **`IDENTITY_SERVER_ID` / `IDENTITY_SERVER_NAME`** — the SPIFFE ID this proxy should
  obtain and the SNI it presents. Must match the registered entry.
- **`IDENTITY_SPIRE_WORKLOAD_API_ADDRESS`** — the key change: instead of talking to
  the in-cluster `linkerd-identity` service, the proxy fetches its SVID from the
  **SPIRE agent's Workload API socket**. SPIRE attests the proxy (uid 2102 + binary
  path), matches the registration entry, and streams it a certificate — rotating it
  before expiry, with no restart.
- **`IDENTITY_TRUST_ANCHORS`** — the root the proxy validates *peers* against. It's
  the same `ca.crt`, so it trusts everything else in the mesh.
- **`DESTINATION_SVC_ADDR` / `POLICY_SVC_ADDR`** — where the proxy reaches the
  control plane: `linkerd-destination` (service discovery / endpoints) on 8086 and
  `linkerd-policy` (authorization policy) on 8090. These resolve via the cluster DNS
  and routes you set up in Part 2.
- **`POLICY_WORKLOAD` / `DESTINATION_CONTEXT`** — how the proxy identifies *itself*
  to those controllers: as the external workload `store-pos` in namespace
  `mixed-env`. This is why the `ExternalWorkload` (next part) must exist and match.

On startup, the log line to look for is `Certified identity id=spiffe://…/store/042/inventory-sync`,
which confirms SPIRE issued the SVID and the proxy has joined the mesh.

---

## Part 5 — Tell the cluster about the workload (ExternalWorkload)

Back on the cloud side, register the store as an `ExternalWorkload`. This is how the
mesh knows the workload exists, what identity it carries, and (for a server) how to
route to it — and it's what the `POLICY_WORKLOAD` reference above resolves against.

First create the namespace the external workload and the cloud app share, with Linkerd
injection enabled — the cloud app (Part 6) must be meshed for the Part 7 identity
policy to take effect:

```bash
[cloud] kubectl create namespace mixed-env
[cloud] kubectl annotate namespace mixed-env linkerd.io/inject=enabled
```

Then register the store as an `ExternalWorkload`:

```yaml
apiVersion: workload.linkerd.io/v1beta1
kind: ExternalWorkload
metadata:
  name: store-pos
  namespace: mixed-env
  labels:
    app: store-pos            # policy selectors match on this
    workload_name: store-pos
spec:
  meshTLS:
    identity: "spiffe://root.linkerd.cluster.local/store/042/inventory-sync"
    serverName: "inventory-sync.cluster.local"
  workloadIPs:
    - ip: "<store-host-ip>"
  ports:
    - port: 80
      name: http
```

- `meshTLS.identity` must equal the SPIFFE ID the proxy obtains. This is the identity
  the mesh attributes to traffic from this workload.
- `workloadIPs` / `ports` describe how to reach it *as a server*. In the push-only
  RetailCloud the store isn't dialed by anyone, so this is nominal — but the resource
  still gives the workload its mesh identity, which is what we need.

The endpoint is treated as NotReady until a `Ready` status condition exists; set it
(status is a subresource, so `kubectl apply` of the spec above won't):

```bash
[cloud] kubectl -n mixed-env patch externalworkload store-pos --subresource=status --type=merge \
          -p '{"status":{"conditions":[{"type":"Ready","status":"True","reason":"Manual","message":"demo","lastTransitionTime":"2026-01-01T00:00:00Z"}]}}'
```

> **Demo shortcut:** the workload's `Ready` status is forced by hand with a hardcoded
> `lastTransitionTime`. Production drives readiness from real health signals, never a
> static forced condition. See
> [Production notes → Lifecycle & automation](PRODUCTION-NOTES.md#lifecycle--automation).

---

## Part 6 — The application and the data flow

Two small services: the store service sends data, and the cloud service receives and
displays it.

**`store-pos` (store, non-root).** A small HTTP client that maintains an
inventory/sales model and POSTs a snapshot to the cloud's ingest endpoint every few
seconds.
Because it runs as `--user 1000`, its outbound POST is redirected through the proxy
and carries the `store/042/inventory-sync` SVID over mTLS. It resolves
`retail-cloud.mixed-env.svc.cluster.local` via the cluster DNS from Part 2.

**`retail-cloud` (cloud, a normal meshed pod).** Listens on two ports:

- `:8080` — the browser dashboard and its `/api/data`. No policy on this port, so
  the (unmeshed) browser can load it.
- `:8090` — the meshed **ingest** endpoint the store pushes to. This is the port we
  protect by identity in Part 7.

> **Demo shortcut:** the `:8080` dashboard and its `/api/data` are served over plain HTTP
> with no TLS and no authentication, so an unmeshed browser can load them directly.
> Production terminates TLS at an ingress/gateway and requires auth for the UI and any
> control endpoints. See
> [Production notes → Security shortcuts](PRODUCTION-NOTES.md#security-shortcuts).

It caches the latest report and renders it. When the store's pushes are refused, the
cached data stops updating, which is the behavior a real ingest pipeline would show.

---

## Part 7 — Authorization by identity

By default a meshed port is open to any meshed client. We make the ingest port
**default-deny except for the store's identity** with three policy resources on the
cloud side:

```yaml
# 1. Declare the protected port. Creating a Server flips :8090 to default-deny.
apiVersion: policy.linkerd.io/v1beta3
kind: Server
metadata: { namespace: mixed-env, name: retail-ingest }
spec:
  podSelector: { matchLabels: { app: retail-cloud } }
  port: ingest
  proxyProtocol: HTTP/1
---
# 2. Name the identity/identities allowed to authenticate.
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata: { namespace: mixed-env, name: allow-store }
spec:
  identities:
    - "spiffe://root.linkerd.cluster.local/store/042/inventory-sync"
---
# 3. Bind them: this Server requires that authentication.
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata: { namespace: mixed-env, name: ingest-allow-store }
spec:
  targetRef: { group: policy.linkerd.io, kind: Server, name: retail-ingest }
  requiredAuthenticationRefs:
    - { group: policy.linkerd.io, kind: MeshTLSAuthentication, name: allow-store }
```

- The `Server` both selects the workload+port and turns it default-deny.
- The `MeshTLSAuthentication` lists allowed **identities** — here the store's SPIFFE
  ID verbatim. (You can list several, or use ServiceAccount refs for in-cluster
  clients.)
- The `AuthorizationPolicy` ties them together: to reach `retail-ingest`, a client
  must present one of those identities over mTLS.

**Revoking access** is now a one-line policy change — swap the allowed identity for a
different one:

```bash
[cloud] kubectl -n mixed-env patch meshtlsauthentication allow-store --type=merge \
          -p '{"spec":{"identities":["spiffe://root.linkerd.cluster.local/nobody"]}}'
```

The store's next push returns **403**, even though its route, address, and firewall
are unchanged. In the demo, the dashboard's *Void authorization* button applies this
same patch, using an RBAC Role granted to `retail-cloud`.

> **Demo shortcut:** that *Void authorization* button lets the served `retail-cloud` app
> patch the very `MeshTLSAuthentication` that protects it — RBAC to rewrite its own
> authorization policy, reachable from an unauthenticated browser endpoint. This is the
> demo's headline simplification: vivid for teaching, but it means the workload can rewrite
> the policy that governs it, and any code-execution bug in the app inherits that power.
> Production authors authorization policy in a GitOps source of truth, never mutated by the
> workload it governs, and never grants an app write access to its own policy. See
> [Production notes → The ones that matter most](PRODUCTION-NOTES.md#the-ones-that-matter-most)
> and [Security shortcuts](PRODUCTION-NOTES.md#security-shortcuts).

---

## Part 8 — Verify

Watch the identities on the wire from the cloud side:

```bash
[cloud] linkerd -n mixed-env viz tap -o wide deploy/retail-cloud
```

Each inbound row shows `tls=true`, and with `-o wide`,
`src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync` — the
store's identity, on traffic arriving from the external host outside Kubernetes,
authenticated by SPIFFE as it pushes (`-o wide` also shows the `dst_srv_name` and
`dst_authz_name` that admitted it). Apply the revoke patch above and the rows become
`403`; restore it and they return to `200`. Nothing about the network moved — only
which identity was allowed.

---

## What each part provides

| Piece | What it provides the workload |
|---|---|
| Shared trust anchor (Part 1) + SPIRE `UpstreamAuthority` (Part 3) | a certificate the cluster trusts |
| SPIRE registration + `unix` attestor (Part 3) | a specific identity tied to the correct process |
| SPIRE Workload API + proxy env (Parts 3–4) | automatic issuance and rotation of that identity |
| iptables + non-root workload (Part 4) | its traffic passing through the proxy |
| `ExternalWorkload` (Part 5) | a representation in the mesh's model of the cluster |
| `Server` + `MeshTLSAuthentication` + `AuthorizationPolicy` (Part 7) | access decided by identity rather than location |

The final row is the purpose of the setup: when identity is portable and
cryptographic, authorization is defined in terms of workloads rather than networks.
