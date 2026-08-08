---
title: Reference
description: The key configuration artifacts for the SPIFFE external-workload setup, at a glance.
---

A quick lookup of the load-bearing configuration. Each links back to the part of the
**[manual](/demos/spiffe-cross-boundary/manual/)** that explains it in full.

## Trust domain

`root.linkerd.cluster.local` — Linkerd's default. Every SPIFFE ID and every config's
`trust_domain` must match it.

## Identities

| Workload | Identity | Issued by |
|---|---|---|
| `store-pos` (off-cluster) | `spiffe://root.linkerd.cluster.local/store-pos` | SPIRE (Workload API) |
| `retail-cloud` (in-cluster) | `retail-cloud.mixed-env.serviceaccount.identity.linkerd.cluster.local` | Linkerd identity |

## SPIRE server — the load-bearing block

The `UpstreamAuthority` is what makes cross-machine trust work: it signs with
Linkerd's root, so SVIDs chain to the same anchor.

```hcl
UpstreamAuthority "disk" {
  plugin_data {
    cert_file_path = "/opt/spire/certs/ca.crt"
    key_file_path  = "/opt/spire/certs/ca.key"
  }
}
NodeAttestor "join_token" { plugin_data {} }
```

## Registration entry

Grants a SPIFFE ID to whatever process matches the selector (the proxy runs as root).

```bash
spire-server entry create \
  -parentID spiffe://root.linkerd.cluster.local/agent \
  -spiffeID spiffe://root.linkerd.cluster.local/store-pos \
  -selector unix:uid:0
```

## The standalone proxy — key env vars

```bash
LINKERD2_PROXY_IDENTITY_SERVER_ID="spiffe://root.linkerd.cluster.local/store-pos"
# fetch identity from SPIRE instead of the in-cluster identity service:
LINKERD2_PROXY_IDENTITY_SPIRE_WORKLOAD_API_ADDRESS="unix:///tmp/spire-agent/public/api.sock"
LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"
# reach the control plane:
LINKERD2_PROXY_DESTINATION_SVC_ADDR="linkerd-dst-headless.linkerd.svc.cluster.local.:8086"
LINKERD2_PROXY_POLICY_SVC_ADDR="linkerd-policy.linkerd.svc.cluster.local.:8090"
```

The `iptables` `--uid-owner 0 -j RETURN` rule means the proxy's own traffic isn't
redirected — so a **client** workload must run **non-root** or its outbound bypasses
the proxy.

## ExternalWorkload

Gives the off-cluster workload a place in the mesh's model of the world.

```yaml
apiVersion: workload.linkerd.io/v1beta1
kind: ExternalWorkload
metadata: { name: store-pos, namespace: mixed-env, labels: { app: store-pos } }
spec:
  meshTLS:
    identity: "spiffe://root.linkerd.cluster.local/store-pos"
    serverName: "store-pos.cluster.local"
  workloadIPs: [{ ip: "<store-host-ip>" }]
  ports: [{ port: 80, name: http }]
```

## Authorization — allow only the store's identity

```yaml
kind: MeshTLSAuthentication
spec:
  identities:
    - "spiffe://root.linkerd.cluster.local/store-pos"
```

Bound to a `Server` (which flips the ingest port default-deny) via an
`AuthorizationPolicy`. Swap that identity for a different one and the store's pushes
get a 403 — the "Void" moment.
