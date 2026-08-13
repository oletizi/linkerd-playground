---
title: Reference
description: The key configuration artifacts for the SPIFFE external-workload setup, in one place.
---

A summary of the configuration this demo depends on. Each section links to the part
of the **[manual](/demos/spiffe-cross-boundary/manual/)** that covers it in full.

:::note[Made with Claude Code]
This demo and its documentation were built with [Claude Code](https://claude.com/claude-code), Anthropic's agentic coding tool.
:::

## Trust domain

`root.linkerd.cluster.local` — Linkerd's default. Every SPIFFE ID and every config's
`trust_domain` must match it.

## Identities

| Workload | Identity | Issued by |
|---|---|---|
| `store-pos` (off-cluster) | `spiffe://root.linkerd.cluster.local/store/042/inventory-sync` | SPIRE (Workload API) |
| `retail-cloud` (in-cluster) | `retail-cloud.mixed-env.serviceaccount.identity.linkerd.cluster.local` | Linkerd identity |

## SPIRE server — upstream authority

The `UpstreamAuthority` block is what allows trust to span machines. SPIRE signs
SVIDs with Linkerd's root certificate, so identities issued off-cluster chain to the
same trust anchor the cluster uses.

```hcl
UpstreamAuthority "disk" {
  plugin_data {
    cert_file_path = "/run/spire/secret/ca.crt"
    key_file_path  = "/run/spire/secret/ca.key"
  }
}
NodeAttestor "join_token" { plugin_data {} }
```

## Registration entry

Grants a SPIFFE ID to whatever process matches the selectors — here the non-root proxy
(uid 2102) at its exact binary path.

```bash
spire-server entry create \
  -parentID spiffe://root.linkerd.cluster.local/store/042/agent \
  -spiffeID spiffe://root.linkerd.cluster.local/store/042/inventory-sync \
  -selector unix:uid:2102 \
  -selector unix:path:/opt/linkerd-proxy/linkerd-proxy
```

## The standalone proxy — key env vars

```bash
LINKERD2_PROXY_IDENTITY_SERVER_ID="spiffe://root.linkerd.cluster.local/store/042/inventory-sync"
# fetch identity from SPIRE instead of the in-cluster identity service:
LINKERD2_PROXY_IDENTITY_SPIRE_WORKLOAD_API_ADDRESS="unix:///tmp/spire-agent/public/api.sock"
LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"
# reach the control plane:
LINKERD2_PROXY_DESTINATION_SVC_ADDR="linkerd-dst-headless.linkerd.svc.cluster.local.:8086"
LINKERD2_PROXY_POLICY_SVC_ADDR="linkerd-policy.linkerd.svc.cluster.local.:8090"
```

The `iptables` rule redirects **only the app's uid** (`--uid-owner 1000 … REDIRECT
--to-port 4140`) into the proxy; the proxy (uid 2102) and all other host traffic are
left alone. So the client workload runs as the redirected uid, and the proxy runs as a
separate, non-root uid.

## ExternalWorkload

Gives the off-cluster workload a place in the mesh's model of the world.

```yaml
apiVersion: workload.linkerd.io/v1beta1
kind: ExternalWorkload
metadata: { name: store-pos, namespace: mixed-env, labels: { app: store-pos, workload_name: store-pos } }
spec:
  meshTLS:
    identity: "spiffe://root.linkerd.cluster.local/store/042/inventory-sync"
    serverName: "inventory-sync.cluster.local"
  workloadIPs: [{ ip: "<store-host-ip>" }]
  ports: [{ port: 80, name: http }]
```

## Authorization — allow only the store's identity

```yaml
kind: MeshTLSAuthentication
spec:
  identities:
    - "spiffe://root.linkerd.cluster.local/store/042/inventory-sync"
```

Bound to a `Server` (which sets the ingest port to default-deny) through an
`AuthorizationPolicy`. If the allowed identity is changed, requests from the store
are rejected with HTTP 403.
