# Onboarding an external workload into a Linkerd mesh with SPIFFE

This demo shows how Linkerd uses **SPIFFE** and **SPIRE** to onboard a workload that does not
run in Kubernetes into the mesh. In the cluster, a pod's identity comes from its Kubernetes
ServiceAccount; off-cluster there is no Kubernetes, so **SPIRE** issues the workload a
cryptographic identity that chains to the same trust anchor Linkerd already uses — what Linkerd
calls **mesh expansion**. With that identity the external process does mutual TLS and is
authorized by *who it is* rather than its IP or network location, just like any in-cluster pod.
The **RetailCloud** example below makes it concrete.

A store's point-of-sale system (`store-pos`) runs on a machine outside Kubernetes and
sends live inventory and sales to a cloud dashboard (`retail-cloud`). The cloud accepts
the data based on cryptographic SPIFFE identity rather than IP or network.

`store-pos` runs on an edge machine that is not part of the cluster; Linkerd **mesh
expansion** joins it to the mesh with a SPIRE-issued identity
(`spiffe://root.linkerd.cluster.local/store/042/inventory-sync`) chained to the cluster's trust anchor.
It sends its data to `retail-cloud` over mTLS; the store initiates the connection,
because the cloud cannot assume the store is reachable. A **Void authorization** button
changes the Linkerd policy so the store's requests are refused with a 403, with no change
to the network.

> **This is a teaching demo, not a production blueprint.** It takes deliberate shortcuts
> — for example, the dashboard app holds permission to change its own authorization policy — to keep the
> mechanics legible. Do not run this configuration in a real environment.
> [`PRODUCTION-NOTES.md`](PRODUCTION-NOTES.md) lists every shortcut and what to do instead.

> **Made with [Claude Code](https://claude.com/claude-code).** This demo and its
> documentation were built with Anthropic's agentic coding tool.

Design spec: [`docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md`](../../docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md).

## See it

Once built, open (at your cluster's address, port `30080`):

- **`/`** — the RetailCloud dashboard: the cloud↔store link with both identities, a
  live **network topology** (Cytoscape.js) that renders `store-pos` on the edge
  machine, inventory as price tags, sales as receipt tape, and the **Void** button.
- **`/tutorial`** — a self-teaching page: **Learn** (the SPIFFE concepts), **Try it**
  (five guided steps with the live dashboard embedded), **Build it** (the runbook).

Click **Void** to see the store data marked VOID and the topology link turn red, while
both identities remain on screen.

## What runs where

| | Box A — Kubernetes cluster | Box B — on-prem store |
|---|---|---|
| Physical | one machine | a **different** machine |
| VM (Lima, optional) | `linkerd-cluster` | `linkerd-edge` |
| Runs | k3s + Linkerd + viz + trust anchor + **SPIRE server** + **`retail-cloud`** app | **SPIRE agent** + `linkerd2-proxy` (non-root) + **`store-pos`** service |

The **SPIRE server runs in the cluster** — the root key never leaves it. The store runs
only the **SPIRE agent**, which enrolls with a one-time join token and authenticates the
server with a pinned trust bundle. The agent hands the store's SVID
(`spiffe://root.linkerd.cluster.local/store/042/inventory-sync`) to a **non-root**
`linkerd2-proxy` (attested by uid + binary path), so the edge identity chains to the same
root as in-cluster identities — one trust domain, no federation. `store-pos` pushes to
`retail-cloud`'s ingest endpoint over mTLS; an `AuthorizationPolicy` allows only that
identity, and the Void button patches the policy.

## Prerequisites

- **Two Linux hosts** (bare metal, VMs, or [Lima](https://lima-vm.io) VMs) that can
  reach each other by any means you already run.
- Checkout of this repo on both; a `config.local.env` in this directory on both:

```bash
cp config.example.env config.local.env
# then edit:
CLUSTER_NODE_ADDR=<address the store uses to reach the cluster>
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

The steps below use the repo's scripts. To understand every piece instead — each
config file and command, with the *why* behind them — follow the from-scratch
manual: [`MANUAL.md`](MANUAL.md).

### Box A — Kubernetes cluster

```bash
just demo spiffe-cross-boundary cluster-up          # (Lima) create the linkerd-cluster VM
limactl shell linkerd-cluster -- bash <demo>/cluster/gen-certs.sh        # trust anchor + issuer
limactl shell linkerd-cluster -- bash <demo>/cluster/install-k3s.sh
limactl shell linkerd-cluster -- bash <demo>/cluster/install-linkerd.sh  # + Gateway API CRDs + viz
```

Confirm the printed `kube-dns` ClusterIP matches `COREDNS_ADDR` (default `10.43.0.10`).

### Box A → deploy the SPIRE server (root stays in the cluster)

```bash
limactl shell linkerd-cluster -- bash <demo>/cluster/spire/apply.sh   # StatefulSet + NodePort + register; prints a join token
```

`apply.sh` mounts the root (`ca.crt`+`ca.key`) into the server as a read-only Secret,
registers the store's workload identity (selectors `unix:uid:2102` + the proxy path), and
prints a one-time **join token** plus a trust **bundle** (`~/spire-bundle.pem`). Copy only
the bundle and the public root cert to the store — the root **key** never leaves the
cluster:

```bash
limactl shell linkerd-cluster -- cat spire-bundle.pem > /tmp/bundle.pem
limactl shell linkerd-cluster -- cat linkerd-certs/ca.crt > /tmp/ca.crt
limactl shell linkerd-edge -- sudo mkdir -p /opt/spire/certs
cat /tmp/bundle.pem | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/bundle.pem >/dev/null
cat /tmp/ca.crt    | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/ca.crt    >/dev/null
```

### Box B — on-prem store (SPIRE agent + proxy + store-pos)

```bash
just demo spiffe-cross-boundary edge-up
limactl shell linkerd-edge -- bash <demo>/net/shim.sh
limactl shell linkerd-edge -- bash <demo>/edge/install-spire-agent.sh <join-token>   # agent-only; pinned bundle
limactl shell linkerd-edge -- bash <demo>/edge/extract-proxy.sh
limactl shell linkerd-edge -- bash <demo>/edge/iptables.sh
limactl shell linkerd-edge -- bash <demo>/store-pos/run-store-pos.sh     # the POS — pushes to the cloud
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

Open `http://<CLUSTER_NODE_ADDR>:30080/` — the store is now pushing its inventory
and sales to the cloud over the mesh. Click **Void authorization** to watch
identity-based authz refuse the store's pushes for real.

## Inspect the traffic

The dashboard is a wrapper; the CLI shows the same facts directly. On the cluster, tap
the traffic while the dashboard polls:

```bash
linkerd -n mixed-env viz tap deploy/retail-cloud
```

Each inbound row shows `tls=true` and `client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`
(with `src_external_workload=store-pos`) — a workload outside Kubernetes, on another
machine, authenticated by SPIFFE identity as it pushes. Click **Void** and the
store's pushes become 403; `linkerd viz stat` shows them fail. Nothing about the
network changed — only the allowed identity.

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

## Scope — this is a teaching demo

Built for explanatory clarity, not production practice. It takes deliberate shortcuts —
the app holding RBAC to change its own policy, `join_token` attestation, processes run without supervision,
the app holding RBAC to change its own policy, and more.
[`PRODUCTION-NOTES.md`](PRODUCTION-NOTES.md) catalogues each shortcut and the production
practice that should replace it.

- **Verified end-to-end on Lima/Apple-Silicon (arm64)** over the optional overlay recipe;
  the default LAN path uses the same `net/shim.sh` mechanism. Other providers/arches are
  config-driven and arch-aware but not independently verified.
- **Implementation note:** the `Server` uses `policy.linkerd.io/v1beta3` and targets the
  store-pos workload via `externalWorkloadSelector`; the `retail-cloud` app is granted a
  small RBAC Role to patch the `MeshTLSAuthentication` (that is what the Void button uses).
