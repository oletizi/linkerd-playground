---
title: The manual
description: A from-scratch, no-scripts walkthrough of every config file, field, and command behind this demo.
---

The [README](https://github.com/oletizi/linkerd-playground/blob/main/demos/spiffe-cross-boundary/README.md) automates this setup with scripts. This document performs the
same setup by hand, explaining every configuration file and command involved in
giving a non-Kubernetes workload a SPIFFE identity and joining it to a Linkerd mesh.

The worked example is **RetailCloud**: a point-of-sale service (`store-pos`) runs on
a machine outside Kubernetes and sends inventory and sales data to a cloud
application (`retail-cloud`) running in the cluster. The cloud service accepts the
data only from the store's verified SPIFFE identity. The sections below build this
configuration incrementally.

> **This is a teaching demo, not a production blueprint.** It takes deliberate
> shortcuts — starting with copying the trust domain's root key onto the store host — to
> keep the mechanics legible in one sitting. Do not run this configuration in a real
> environment. [Production notes](/demos/spiffe-cross-boundary/production-notes/) lists every shortcut and what to
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
  Linux VM.)
- On the **cloud** host: a Kubernetes cluster (k3s is fine) and the `linkerd` CLI
  (edge channel — mesh expansion needs 2.15+), plus [`step`](https://smallstep.com/docs/step-cli/)
  to make certificates.
- On the **store** host: the SPIRE binaries (`spire-server`, `spire-agent`), a
  container runtime (Docker/Podman) to run the app, and `iptables`.
- Pick one Linkerd edge version and use it everywhere — the standalone proxy binary
  must match the control plane. We'll call it `$LINKERD_VERSION` (e.g. `edge-26.7.2`).

---

## Part 1 — One root of trust (cloud)

Linkerd's identity system has two certificates: a long-lived **trust anchor** (the
root CA) and a shorter-lived **issuer** (an intermediate) that actually signs proxy
certs. Normally `linkerd install` generates both for you and you never see the root
key. We need the root key later (SPIRE will sign with it), so we generate the pair
ourselves.

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
- Keep `ca.crt` **and** `ca.key`: the root key is what makes cross-machine trust
  possible, because SPIRE will use it to sign the external workload's certificates.

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
  will trust. Because we hold the matching `ca.key`, we can now mint *sibling*
  certificates off-cluster that this cluster will accept.

(Optionally `linkerd viz install | kubectl apply -f -` to get `linkerd viz tap`,
which we use to see identities on the wire.)

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
kube-dns`). The cloud host must have IP forwarding on so it routes the store's
traffic into the pod network. This is the distinction between identity and
connectivity: SPIFFE provides identity; this step provides connectivity.

---

## Part 3 — An identity source on the store (SPIRE)

### 3a. Give SPIRE the cluster's root

Copy the trust anchor from Part 1 onto the store machine. SPIRE will use it as its
**upstream authority** — meaning SPIRE issues an intermediate below this root and
signs workload SVIDs with it, so they chain to the exact same root Linkerd uses.

```bash
[store] sudo mkdir -p /opt/spire/certs
# transport ca.crt and ca.key here by whatever secure means you have, then:
[store] sudo cp ca.crt ca.key /opt/spire/certs/
```

> **Trade-off to understand:** putting the root *key* on the store lets a local
> SPIRE server sign certificates, but it also means the root key now lives outside
> the cluster. Fine for a demo; in production you'd hand SPIRE an *intermediate*
> (via the `UpstreamAuthority` of your choice) rather than the root itself.

### 3b. The SPIRE server config

`/opt/spire/server.cfg`:

```hcl
server {
    bind_address = "127.0.0.1"
    bind_port = "8081"
    trust_domain = "root.linkerd.cluster.local"
    data_dir = "/opt/spire/data/server"
    ca_ttl = "168h"
    default_x509_svid_ttl = "48h"
}
plugins {
    DataStore "sql" {
        plugin_data { database_type = "sqlite3"
            connection_string = "/opt/spire/data/server/datastore.sqlite3" }
    }
    KeyManager "disk" { plugin_data { keys_path = "/opt/spire/data/server/keys.json" } }
    NodeAttestor "join_token" { plugin_data {} }
    UpstreamAuthority "disk" {
        plugin_data {
            cert_file_path = "/opt/spire/certs/ca.crt"
            key_file_path  = "/opt/spire/certs/ca.key"
        }
    }
}
```

Field by field:

- `trust_domain` **must** equal Linkerd's (`root.linkerd.cluster.local`). If it
  differs, the SPIFFE IDs won't match what the mesh expects and mTLS won't validate.
- `default_x509_svid_ttl = "48h"` is how long each issued SVID lives before it must
  be rotated. Short-lived certs are the SPIFFE norm; rotation is automatic (Part 4).
- `KeyManager "disk"` persists SPIRE's own signing keys across restarts.
- `NodeAttestor "join_token"` chooses how *agents* prove their identity to the
  server. `join_token` is a one-time shared secret — the simplest, works on any
  infrastructure. (On real infra you'd swap in cloud-instance or x509 attestation.)
- `UpstreamAuthority "disk"` is the key setting: it points SPIRE at Linkerd's
  `ca.crt`/`ca.key`, so everything SPIRE signs chains to that root.

### 3c. The SPIRE agent config

`/opt/spire/agent.cfg`:

```hcl
agent {
    data_dir = "/opt/spire/data/agent"
    trust_domain = "root.linkerd.cluster.local"
    server_address = "localhost"
    server_port = 8081
    insecure_bootstrap = true
}
plugins {
    KeyManager "disk" { plugin_data { directory = "/opt/spire/data/agent" } }
    NodeAttestor "join_token" { plugin_data {} }
    WorkloadAttestor "unix" { plugin_data {} }
}
```

- `server_address`/`server_port` point the agent at the local SPIRE server (both run
  on the store in this demo).
- `insecure_bootstrap = true` skips verifying the server's TLS on first contact —
  acceptable because server and agent are the same host here.
- `NodeAttestor "join_token"` matches the server's node attestor: the agent presents
  a join token to prove which node it is.
- `WorkloadAttestor "unix"` is how the agent later identifies *workloads* that ask
  for a certificate: it inspects the calling process's Unix properties (uid, gid,
  path). This is what ties "the process asking" to "the identity it's allowed."

### 3d. Start the server, then bootstrap the agent

```bash
[store] sudo spire-server run -config /opt/spire/server.cfg &   # (use a service unit in practice)

# Mint a one-time join token bound to the agent's SPIFFE ID:
[store] TOKEN=$(sudo spire-server token generate \
                 -spiffeID spiffe://root.linkerd.cluster.local/agent | awk '{print $2}')

[store] sudo spire-agent run -config /opt/spire/agent.cfg -joinToken "$TOKEN" &

[store] sudo spire-server healthcheck && sudo spire-agent healthcheck \
          -socketPath /tmp/spire-agent/public/api.sock
```

That `token generate` → `-joinToken` handshake is **node attestation**: the agent
proves to the server it's an authorized node, and thereafter can request SVIDs. Note
the agent exposes the **SPIFFE Workload API** on a Unix socket
(`/tmp/spire-agent/public/api.sock`) — the proxy will read its identity from there.

### 3e. Register the workload

Node attestation says "this agent is allowed to run." **Registration** says which
*identity* a given process may receive. This is an administrative act against the
server — the workload never names itself.

```bash
[store] sudo spire-server entry create \
          -parentID spiffe://root.linkerd.cluster.local/agent \
          -spiffeID spiffe://root.linkerd.cluster.local/store-pos \
          -selector unix:uid:0
```

- `-spiffeID …/store-pos` is the identity to grant.
- `-parentID …/agent` is the agent that will attest and deliver it.
- `-selector unix:uid:0` is the condition the process must meet. **This uid is the
  proxy's**, not the app's — the `linkerd2-proxy` runs as root, holds the SVID, and
  does mTLS on the app's behalf. Registration *authorizes*; the `unix` workload
  attestor later *enforces* by checking the caller's uid against this entry.

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

### 4b. Redirect traffic through the proxy (iptables)

Like an injected sidecar, the proxy only helps if the workload's traffic passes
through it. These nat rules send inbound TCP to the proxy's inbound port (4143) and
outbound TCP to its outbound port (4140):

```bash
[store] sudo iptables -t nat -N PROXY_INIT_REDIRECT
[store] sudo iptables -t nat -A PROXY_INIT_REDIRECT -p tcp --match multiport --dports 4190,4191,4567,4568 -j RETURN
[store] sudo iptables -t nat -A PROXY_INIT_REDIRECT -p tcp -j REDIRECT --to-port 4143
[store] sudo iptables -t nat -A PREROUTING -j PROXY_INIT_REDIRECT

[store] sudo iptables -t nat -N PROXY_INIT_OUTPUT
[store] sudo iptables -t nat -A PROXY_INIT_OUTPUT -m owner --uid-owner 0 -j RETURN
[store] sudo iptables -t nat -A PROXY_INIT_OUTPUT -o lo -j RETURN
[store] sudo iptables -t nat -A PROXY_INIT_OUTPUT -p tcp --match multiport --dports 4567,4568 -j RETURN
[store] sudo iptables -t nat -A PROXY_INIT_OUTPUT -p tcp -j REDIRECT --to-port 4140
[store] sudo iptables -t nat -A OUTPUT -j PROXY_INIT_OUTPUT
```

The important line is `-m owner --uid-owner 0 -j RETURN`: traffic **from uid 0 is
not redirected**. That's how the proxy (running as root) avoids redirecting its own
outbound into an infinite loop.

> **Consequence for the app:** because uid 0 is exempt, your workload must run as a
> **non-root** user, or its outbound will bypass the proxy and lose mTLS + identity.
> In RetailCloud the store pushes *out* to the cloud, so this matters: we run the
> POS container with `--user 1000`. (A server-only workload, which only receives on
> :4143 via PREROUTING, wouldn't hit this.)

### 4c. Launch the proxy — identity from SPIRE

The proxy is configured entirely through environment variables:

```bash
[store] export LINKERD2_PROXY_IDENTITY_SERVER_ID="spiffe://root.linkerd.cluster.local/store-pos"
[store] export LINKERD2_PROXY_IDENTITY_SERVER_NAME="store-pos.cluster.local"
[store] export LINKERD2_PROXY_POLICY_WORKLOAD='{"ns":"mixed-env","external_workload":"store-pos"}'
[store] export LINKERD2_PROXY_DESTINATION_CONTEXT='{"ns":"mixed-env","nodeName":"store","external_workload":"store-pos"}'
[store] export LINKERD2_PROXY_DESTINATION_SVC_ADDR="linkerd-dst-headless.linkerd.svc.cluster.local.:8086"
[store] export LINKERD2_PROXY_DESTINATION_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
[store] export LINKERD2_PROXY_POLICY_SVC_ADDR="linkerd-policy.linkerd.svc.cluster.local.:8090"
[store] export LINKERD2_PROXY_POLICY_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
[store] export LINKERD2_PROXY_IDENTITY_SPIRE_WORKLOAD_API_ADDRESS="unix:///tmp/spire-agent/public/api.sock"
[store] export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"
[store] sudo -E /opt/linkerd-proxy/linkerd-proxy
```

What each group does:

- **`IDENTITY_SERVER_ID` / `IDENTITY_SERVER_NAME`** — the SPIFFE ID this proxy should
  obtain and the SNI it presents. Must match the registered entry.
- **`IDENTITY_SPIRE_WORKLOAD_API_ADDRESS`** — the key change: instead of talking to
  the in-cluster `linkerd-identity` service, the proxy fetches its SVID from the
  **SPIRE agent's Workload API socket**. SPIRE attests the proxy (uid 0), matches the
  registration entry, and streams it a certificate — rotating it before expiry, with
  no restart.
- **`IDENTITY_TRUST_ANCHORS`** — the root the proxy validates *peers* against. It's
  the same `ca.crt`, so it trusts everything else in the mesh.
- **`DESTINATION_SVC_ADDR` / `POLICY_SVC_ADDR`** — where the proxy reaches the
  control plane: `linkerd-destination` (service discovery / endpoints) on 8086 and
  `linkerd-policy` (authorization policy) on 8090. These resolve via the cluster DNS
  and routes you set up in Part 2.
- **`POLICY_WORKLOAD` / `DESTINATION_CONTEXT`** — how the proxy identifies *itself*
  to those controllers: as the external workload `store-pos` in namespace
  `mixed-env`. This is why the `ExternalWorkload` (next part) must exist and match.

On startup, the log line to look for is `Certified identity id=spiffe://…/store-pos`,
which confirms SPIRE issued the SVID and the proxy has joined the mesh.

---

## Part 5 — Tell the cluster about the workload (ExternalWorkload)

Back on the cloud side, register the store as an `ExternalWorkload`. This is how the
mesh knows the workload exists, what identity it carries, and (for a server) how to
route to it — and it's what the `POLICY_WORKLOAD` reference above resolves against.

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
    identity: "spiffe://root.linkerd.cluster.local/store-pos"
    serverName: "store-pos.cluster.local"
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

---

## Part 6 — The application and the data flow

Two small services: the store service sends data, and the cloud service receives and
displays it.

**`store-pos` (store, non-root).** A small HTTP client that maintains an
inventory/sales model and POSTs a snapshot to the cloud's ingest endpoint every few
seconds.
Because it runs as `--user 1000`, its outbound POST is redirected through the proxy
and carries the `store-pos` SVID over mTLS. It resolves
`retail-cloud.mixed-env.svc.cluster.local` via the cluster DNS from Part 2.

**`retail-cloud` (cloud, a normal meshed pod).** Listens on two ports:

- `:8080` — the browser dashboard and its `/api/data`. No policy on this port, so
  the (unmeshed) browser can load it.
- `:8090` — the meshed **ingest** endpoint the store pushes to. This is the port we
  protect by identity in Part 7.

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
    - "spiffe://root.linkerd.cluster.local/store-pos"
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

---

## Part 8 — Verify

Watch the identities on the wire from the cloud side:

```bash
[cloud] linkerd -n mixed-env viz tap deploy/retail-cloud
```

Each inbound row shows `tls=true` and
`client_id=spiffe://root.linkerd.cluster.local/store-pos` with
`src_external_workload=store-pos` — a workload outside Kubernetes, on another
machine, authenticated by SPIFFE identity as it pushes. Apply the revoke patch above
and the rows become `403`; restore it and they return to `200`. Nothing about the
network moved — only which identity was allowed.

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
