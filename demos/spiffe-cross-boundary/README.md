# spiffe-cross-boundary — RetailCloud

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

- **Two Linux hosts** — bare metal or VMs — that can already reach each other at
  L3. Ubuntu 24.04 is what the demo is verified on.
- A checkout of **this whole repo** on both boxes (not just this directory — every
  script sources `lib/common.sh` from the repo root).
- A matching `config.local.env` in this directory on **both** boxes:

```bash
cp config.example.env config.local.env
# then edit:
CLUSTER_NODE_ADDR=<address the store uses to reach the cluster>
EDGE_ADDR=<address the cluster uses to reach the store>
```

`config.example.env` defaults to the RetailCloud (`store-pos`) identity; everything
else (CIDRs, Linkerd version, uids) has working defaults.

> **`APP_UID` on a bare-metal edge.** `edge/iptables.sh` redirects all outbound TCP
> from `APP_UID` (default `1000`) through the proxy. On most Linux installs uid 1000
> is the primary human user, so on a box you care about, set `APP_UID` to an unused
> uid before running the edge steps. Throwaway VMs can leave it alone.

Scripts under `cluster/`, `edge/`, `net/`, `store-pos/` run **on the box they name**.
Paths below are abbreviated `<demo>/` = `<repo>/demos/spiffe-cross-boundary`.

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

The steps below use the repo's scripts and are the **verified path**: two Linux
hosts on a flat network, running the scripts directly. To understand every piece
instead — each config file and command, with the *why* behind them — follow the
from-scratch manual: [`MANUAL.md`](MANUAL.md).

Run each block **on the box named in its heading** (or drive it over ssh, e.g.
`ssh cluster 'bash <demo>/cluster/gen-certs.sh'`).

### Box A — Kubernetes cluster

```bash
bash <demo>/cluster/gen-certs.sh        # trust anchor + issuer
bash <demo>/cluster/install-k3s.sh
bash <demo>/cluster/install-linkerd.sh  # + Gateway API CRDs + viz; ends with `linkerd check`
```

Confirm the `kube-dns` ClusterIP matches `COREDNS_ADDR` (default `10.43.0.10`):

```bash
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
```

> `install-k3s.sh` tries to print this itself, but queries the cluster before
> CoreDNS exists, so on a fresh install it reports `services "kube-dns" not found`
> and exits non-zero. k3s is fine; run the command above once the pod is up.

### Box A → deploy the SPIRE server (root stays in the cluster)

`apply.sh` also restricts the SPIRE NodePort to one interface, and **needs to be
told which one** — the interface the edge box reaches this host on. It otherwise
defaults to `tailscale0` and aborts before printing the join token:

```bash
SPIRE_NODEPORT_IFACE=$(ip -o route get "$EDGE_ADDR" | grep -oP 'dev \K\S+') \
  bash <demo>/cluster/spire/apply.sh   # StatefulSet + NodePort + register; prints a join token
```

It mounts the root (`ca.crt`+`ca.key`) into the server as a read-only Secret,
registers the store's workload identity (selectors `unix:uid:2102` + the proxy path), and
prints a one-time **join token** plus a trust **bundle** (`~/spire-bundle.pem`). Copy only
the bundle and the public root cert to the store — the root **key** never leaves the
cluster:

```bash
# on Box A:
scp ~/spire-bundle.pem ~/linkerd-certs/ca.crt <edge-host>:/tmp/
# on Box B:
sudo mkdir -p /opt/spire/certs
sudo cp /tmp/spire-bundle.pem /opt/spire/certs/bundle.pem
sudo cp /tmp/ca.crt          /opt/spire/certs/ca.crt
```

### Box B — on-prem store (SPIRE agent + proxy + store-pos)

```bash
bash <demo>/net/shim.sh
bash <demo>/edge/install-spire-agent.sh <join-token>   # agent-only; pinned bundle
bash <demo>/edge/extract-proxy.sh
bash <demo>/edge/iptables.sh
bash <demo>/store-pos/run-store-pos.sh     # the POS — pushes to the cloud
```

`store-pos` will log `push error: ENOTFOUND` until the next step creates the
`retail-cloud` Service. That is expected.

### Box A → deploy RetailCloud, THEN Box B → start the proxy

The proxy fetches its inbound policy from the cluster, so the `ExternalWorkload`
must exist before it starts. `cluster/retail/apply.sh` creates the `mixed-env`
namespace (annotated for injection), registers `store-pos` (and marks it Ready),
deploys the `retail-cloud` app, and applies the authorization policy.

```bash
# Box A:
bash <demo>/cluster/retail/apply.sh   # prints the dashboard URL
# Box B:
bash <demo>/edge/run-proxy.sh
```

`run-proxy.sh` confirms the identity it received:

```
proxy has identity (uid 2102)
```

Open `http://<CLUSTER_NODE_ADDR>:30080/` — the store is now pushing its inventory
and sales to the cloud over the mesh, and `sudo docker logs -f store-pos` on Box B
shows `push -> 200`. Click **Void authorization** to watch identity-based authz
refuse the store's pushes for real (`push -> 403`).

## Inspect the traffic

The dashboard is a wrapper; the CLI shows the same facts directly. On the cluster, tap
the traffic while the dashboard polls. **`-o wide` is required** — the default output
stops at `tls=true` and shows no identity:

```bash
linkerd -n mixed-env viz tap deploy/retail-cloud -o wide
```

```
req id=1:0 proxy=in src=<edge-addr>:47914 dst=10.42.0.15:8090 tls=true
  :method=POST :path=/ingest
  src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
  src_tls=true dst_authz_kind=authorizationpolicy dst_authz_name=ingest-allow-store
```

`src_client_id` is the whole point — a workload outside Kubernetes, on another
machine, authenticated by SPIFFE identity as it pushes; `dst_authz_name` names the
policy that admitted it. Click **Void** and the store's pushes become 403;
`linkerd viz stat` shows them fail. Nothing about the network changed — only the
allowed identity.

## Running both boxes on one machine

Neither is required, and neither is the verified path above; both are ways to get
two mutually-reachable Linux boxes out of one physical machine.

### Linux — libvirt

Two VMs on libvirt's default `virbr0` network reach each other (and the host)
natively, with no overlay. Give each a static address, put the repo on both, and
follow **Build it** unchanged.

> Lima on Linux is **not** recommended for this demo: its only VM-to-VM network
> (`user-v2`) rides a QEMU socket netdev that aborts the VM under sustained
> download load (`net_fill_rstate: Assertion 'size == 0' failed`), which the
> Linkerd install reliably triggers. See [`runlog-linux.md`](runlog-linux.md) F4b.

### macOS — Lima

```bash
just demo spiffe-cross-boundary cluster-up   # create the linkerd-cluster VM
just demo spiffe-cross-boundary edge-up      # create the linkerd-edge VM
```

The stock Lima network gives every VM the same address, so attach one that allows
VM-to-VM — `limactl edit <vm> --network lima:user-v2`, while stopped. Then copy
the **repo root** into each guest and run the same scripts:

```bash
tar --exclude=.git -C <repo> -czf - . \
  | limactl shell <vm> -- bash -c 'mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
limactl shell <vm> bash -lc 'bash ~/linkerd-playground/demos/spiffe-cross-boundary/<script>'
```

> Quote the path as shown. Written unquoted, `~` expands on the **host**, and the
> guest home is never the host's — the guest then gets a path that doesn't exist.

## Teardown

Box A: `k3s-uninstall.sh`. Box B: remove the `PROXY_APP_OUTPUT` iptables chain,
`/opt/spire`, `/opt/linkerd-proxy`, the `store-pos` container and
`/etc/systemd/resolved.conf.d/cluster.conf`. For Lima VMs, `just demo
spiffe-cross-boundary down` deletes both.

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
the app holding RBAC to change its own policy, `join_token` attestation, processes run
without supervision, and more.
[`PRODUCTION-NOTES.md`](PRODUCTION-NOTES.md) catalogues each shortcut and the production
practice that should replace it.

- **Verified end-to-end on Linux/x86_64** (Ubuntu 24.04, two hosts on a flat
  network, static-route path) — see [`runlog-linux.md`](runlog-linux.md), which
  drives the scripts; and on **Lima/Apple-Silicon (arm64)** over the optional
  Tailscale overlay — see [`runlog.md`](runlog.md), which follows `MANUAL.md` by
  hand. Other providers/arches are config-driven and arch-aware but not
  independently verified.
- **Implementation note:** the `Server` uses `policy.linkerd.io/v1beta3` and targets the
  store-pos workload via `externalWorkloadSelector`; the `retail-cloud` app is granted a
  small RBAC Role to patch the `MeshTLSAuthentication` (that is what the Void button uses).

---

_Made with [Claude Code](https://claude.com/claude-code)._
