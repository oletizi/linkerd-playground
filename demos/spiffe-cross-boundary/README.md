# spiffe-cross-boundary — RetailCloud

**A cloud dashboard reads live inventory and sales from a store's point-of-sale
system running on a *different machine*, outside Kubernetes — and access is gated
on cryptographic SPIFFE identity, not on IP or network.**

This is SPIFFE-in-Linkerd made tangible. `store-pos` runs on an edge machine that
Kubernetes has never heard of; Linkerd **mesh expansion** brings it into the mesh
with a SPIRE-issued identity (`spiffe://root.linkerd.cluster.local/store-pos`)
chained to the cluster's trust anchor. The cloud app (`retail-cloud`) calls it over
mTLS. A **Void authorization** button flips the real Linkerd policy so the cloud
app is refused with a genuine 403 — with nothing about the network changing.

Design spec: [`docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md`](../../docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md).

## See it

Once built, open (at your cluster's address, port `30080`):

- **`/`** — the RetailCloud dashboard: the cloud↔store link with both identities, a
  live **network topology** (Cytoscape.js) that renders `store-pos` on the edge
  machine, inventory as price tags, sales as receipt tape, and the **Void** button.
- **`/tutorial`** — a self-teaching page: **Learn** (the SPIFFE concepts), **Try it**
  (five guided steps with the live dashboard embedded), **Build it** (the runbook).

The whole story lands in one place: hit **Void**, watch the store data stamp VOID
and the topology link turn red — while both identities stay on screen.

## What runs where

| | Box A — cloud cluster | Box B — on-prem store |
|---|---|---|
| Physical | one machine | a **different** machine |
| VM (Lima, optional) | `linkerd-cluster` | `linkerd-edge` |
| Runs | k3s + Linkerd + viz + SPIRE **trust anchor** + **`retail-cloud`** app | SPIRE server+agent + `linkerd2-proxy` + **`store-pos`** service |

**SPIRE runs on the edge**, rooted at Linkerd's trust anchor (copied over), so the
edge's SVID chains to the same root as in-cluster identities — one trust domain,
no federation. `retail-cloud` calls `store-pos` over mTLS; an `AuthorizationPolicy`
on `store-pos` allows only the `retail-cloud` identity, and the Void button patches
that policy.

## Prerequisites

- **Two Linux hosts** (bare metal, VMs, or [Lima](https://lima-vm.io) VMs) that can
  reach each other by any means you already run.
- Checkout of this repo on both; a `config.local.env` in this directory on both:

```bash
cp config.example.env config.local.env
# then edit:
CLUSTER_NODE_ADDR=<address the store uses to reach the cloud cluster>
EDGE_ADDR=<address the cluster uses to reach the store>
```

`config.example.env` defaults to the RetailCloud (`store-pos`) identity; everything
else (VM sizing, CIDRs, Linkerd version) has working defaults.

> Scripts under `cluster/`, `edge/`, `net/`, `store-pos/` run **inside** the
> respective host/VM. With Lima, copy the repo into the guest first
> (`tar -C <repo> -czf - . | limactl shell <vm> -- bash -c 'mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'`)
> and invoke as `limactl shell <vm> -- bash ~/linkerd-playground/demos/spiffe-cross-boundary/<script>`.
> Paths below are abbreviated `<demo>/`.

## Connectivity (a precondition — bring your own)

The playground **does not provision or prescribe a network**. It needs only that
the two machines already reach each other at L3, and it adds the minimal generic
plumbing Linkerd's data plane requires:

- the edge reaches the cluster **pod + service CIDRs** (`10.42.0.0/16`, `10.43.0.0/16`), and
- the edge resolves `*.cluster.local` via CoreDNS.

`net/shim.sh` does both: on a flat LAN it installs a static route via
`CLUSTER_NODE_ADDR` and points cluster DNS at CoreDNS; it detects routes an overlay
already provides and only fills in what's missing. For machines not on the same LAN,
an optional overlay recipe is in [`connectivity-tailscale.md`](connectivity-tailscale.md)
(strictly optional; the demo doesn't depend on it).

## Build it

### Box A — cloud cluster

```bash
just demo spiffe-cross-boundary cluster-up          # (Lima) create the linkerd-cluster VM
limactl shell linkerd-cluster -- bash <demo>/cluster/gen-certs.sh        # trust anchor + issuer
limactl shell linkerd-cluster -- bash <demo>/cluster/install-k3s.sh
limactl shell linkerd-cluster -- bash <demo>/cluster/install-linkerd.sh  # + Gateway API CRDs + viz
```

Confirm the printed `kube-dns` ClusterIP matches `COREDNS_ADDR` (default `10.43.0.10`).

### Copy the trust anchor to the store

```bash
limactl shell linkerd-cluster -- cat linkerd-certs/ca.crt > /tmp/ca.crt
limactl shell linkerd-cluster -- cat linkerd-certs/ca.key > /tmp/ca.key
# transport both to Box B, then on Box B:
limactl shell linkerd-edge -- sudo mkdir -p /opt/spire/certs
cat /tmp/ca.crt | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/ca.crt >/dev/null
cat /tmp/ca.key | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/ca.key >/dev/null
```

### Box B — on-prem store (SPIRE + proxy + store-pos)

```bash
just demo spiffe-cross-boundary edge-up
limactl shell linkerd-edge -- bash <demo>/net/shim.sh
limactl shell linkerd-edge -- bash <demo>/edge/install-spire.sh
limactl shell linkerd-edge -- bash <demo>/edge/register-workload.sh      # registers store-pos identity
limactl shell linkerd-edge -- bash <demo>/edge/extract-proxy.sh
limactl shell linkerd-edge -- bash <demo>/edge/iptables.sh
limactl shell linkerd-edge -- bash <demo>/store-pos/run-store-pos.sh     # the POS service on :80
```

### Box A → deploy RetailCloud, THEN Box B → start the proxy

The proxy fetches its inbound policy from the cluster, so the `ExternalWorkload`
must exist before it starts. `cluster/retail/apply.sh` registers `store-pos` (and
marks it Ready), deploys the `retail-cloud` app, and applies the authorization
policy.

```bash
# Box A:
limactl shell linkerd-cluster -- bash <demo>/cluster/retail/apply.sh   # prints the dashboard URL
# Box B:
limactl shell linkerd-edge -- bash <demo>/edge/run-proxy.sh
```

Open `http://<CLUSTER_NODE_ADDR>:30080/` — inventory and sales are now flowing from
the store over the mesh. Click **Void authorization** to watch identity-based
authz refuse the cloud app for real.

## Under the hood — see the raw evidence

The dashboard is a friendly wrapper; the CLI shows the same facts unadorned. On the
cluster, tap the traffic while the dashboard polls:

```bash
linkerd -n mixed-env viz tap deploy/retail-cloud
```

Each row shows `tls=true`, `dst_server_id=spiffe://root.linkerd.cluster.local/store-pos`,
and `dst_external_workload=store-pos` — a workload outside Kubernetes, on another
machine, authenticated by SPIFFE identity. Click **Void** and the same call becomes
a 403; `linkerd viz stat` shows the success rate drop. Nothing about the network
changed — only the allowed identity.

## Teardown

```bash
just demo spiffe-cross-boundary down     # on each box
```

## Appendix — the original CLI beats (abstract variant)

Before RetailCloud, this demo proved the same mechanics at the CLI with a plain
`echo` server and an `edge-echo` identity, in four "beats" (cross-boundary mTLS,
edge-as-client, identity authz 200→403, and authorized mTLS to the edge). Those
scripts still live here: `cluster/echo.yaml`, `cluster/apply-echo.sh`,
`cluster/externalworkload.yaml`, `cluster/authz*.yaml`, `edge/run-app.sh`, and
`scripts/beat*.sh` (`just demo spiffe-cross-boundary beat1|beat2|beat3`).

They use the **`edge-echo`** identity rather than `store-pos`, so to run them set the
three identity vars in `config.local.env` back to the `edge-echo` values
(`EDGE_WORKLOAD_NAME=edge-echo`, `EDGE_SPIFFE_ID=spiffe://…/edge-echo`,
`EDGE_SERVER_NAME=edge-echo.cluster.local`) and use `apply-echo.sh` +
`apply-externalworkload.sh` instead of `store-pos` + `cluster/retail/apply.sh`.
RetailCloud and the beats share one edge proxy (one identity), so run one or the other.

## Caveats (honest scope)

- **The root CA key lives on the edge.** SPIRE's `UpstreamAuthority` uses the Linkerd
  trust anchor `ca.key`, copied to the edge. Fine for a playground; a real deployment
  would use an intermediate instead.
- **`join_token` attestation** is chosen for portability across any infrastructure —
  swap for cloud/x509 attestation on real infra.
- **Verified end-to-end on Lima/Apple-Silicon (arm64)** over the optional overlay
  recipe; the default LAN path uses the same `net/shim.sh` mechanism. Other
  providers/arches are config-driven and arch-aware but not independently verified.
- **`Server` uses `policy.linkerd.io/v1beta3`**; the store-pos Server targets the
  workload via `externalWorkloadSelector`. The RetailCloud app is granted a small RBAC
  Role to patch the `MeshTLSAuthentication` (that's what the Void button uses).
