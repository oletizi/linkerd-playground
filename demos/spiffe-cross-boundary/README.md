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
| Recommended setup | a local VM (`linkerd-cluster`, `192.168.122.10`) | a **separate** local VM (`linkerd-edge`, `192.168.122.11`) |
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

The demo needs two Linux boxes that can reach each other at L3. The **recommended
and verified setup is one Linux host running both as local VMs**, which the repo
provisions for you.

- One Linux host with KVM (Ubuntu 26.04 verified), ~10 GiB free RAM and ~30 GiB disk.
- A checkout of this repo, and [`just`](https://github.com/casey/just).

```bash
cd <repo>
cp demos/spiffe-cross-boundary/config.example.env demos/spiffe-cross-boundary/config.local.env
just demo spiffe-cross-boundary host-setup     # one time; installs libvirt, needs sudo
```

> **Log out and log back in before continuing.** `host-setup` adds you to the
> `libvirt` group, and group membership only applies to a **new login session** —
> a new terminal window is not enough. Until you do, every command fails with
> `Permission denied` on `/var/run/libvirt/libvirt-sock`. Verify with
> `virsh -c qemu:///system list --all`.

Then bring up both boxes:

```bash
just demo spiffe-cross-boundary cluster-up     # Box A at 192.168.122.10
just demo spiffe-cross-boundary edge-up        # Box B at 192.168.122.11
```

Each creates a libvirt VM on `virbr0` pinned to a fixed address by DHCP
reservation, waits for cloud-init, copies this repo into the guest, and writes
`~/.ssh/linkerd-playground.conf`. The first run downloads an Ubuntu cloud image
(~600 MB) into `~/.cache/linkerd-playground`. No editing of `config.local.env` is
needed — its defaults are the addresses these two commands assign.

Reach either box with that generated config:

```bash
ssh -F ~/.ssh/linkerd-playground.conf linkerd-cluster '<command>'
ssh -F ~/.ssh/linkerd-playground.conf linkerd-edge    '<command>'
```

**Running it somewhere else** — two physical machines, or macOS — is supported but
not the verified path: see [Other topologies](#other-topologies) below, and set
`CLUSTER_NODE_ADDR`/`EDGE_ADDR` in `config.local.env` to those boxes' real
addresses. Both boxes need the **whole repo** (every script sources
`lib/common.sh` from the repo root) and the same `config.local.env`.

> **`APP_UID` on a bare-metal edge.** `edge/iptables.sh` redirects all outbound TCP
> from `APP_UID` (default `1000`) through the proxy. On most Linux installs uid 1000
> is the primary human user, so if Box B is a machine you care about, set `APP_UID`
> to an unused uid first. The provisioned VMs are throwaway, so they leave it alone.

Scripts under `cluster/`, `edge/`, `net/`, `store-pos/` run **on the box they name**.
Paths below are abbreviated `<demo>/` = `~/linkerd-playground/demos/spiffe-cross-boundary`
(where `cluster-up`/`edge-up` put the repo inside each guest).

## Connectivity

The demo needs the two boxes to reach each other at L3, plus the minimal generic
plumbing Linkerd's data plane requires:

- the edge reaches the cluster **pod + service CIDRs** (`10.42.0.0/16`, `10.43.0.0/16`), and
- the edge resolves `*.cluster.local` via CoreDNS.

In the recommended setup the first part is handled for you: both VMs sit on
libvirt's `virbr0`, a real host bridge, so VM↔VM and host↔VM are ordinary kernel
routing with no overlay. `net/shim.sh` (a Box B step below) adds the second part —
a static route for the two CIDRs via `CLUSTER_NODE_ADDR` and a resolver entry
pointing `*.cluster.local` at CoreDNS. It detects routes an overlay already
provides and only fills in what's missing.

On any other topology, L3 reachability between the boxes is **yours to provide**;
the playground does not prescribe a network. For machines not on the same LAN, an
optional overlay recipe is in
[`connectivity-tailscale.md`](connectivity-tailscale.md) (strictly optional; the
demo doesn't depend on it).

## Build it

The steps below use the repo's scripts and are the **verified path**. To understand
every piece instead — each config file and command, with the *why* behind them —
follow the from-scratch manual: [`MANUAL.md`](MANUAL.md).

Each block runs **on the box named in its heading**. Shown here driven over ssh
from your host, with `S` as a shorthand:

```bash
S="ssh -F ~/.ssh/linkerd-playground.conf"
D=~/linkerd-playground/demos/spiffe-cross-boundary
```

### Box A — Kubernetes cluster

```bash
$S linkerd-cluster "bash $D/cluster/gen-certs.sh"        # trust anchor + issuer
$S linkerd-cluster "bash $D/cluster/install-k3s.sh"      # prints the kube-dns ClusterIP
$S linkerd-cluster "bash $D/cluster/install-linkerd.sh"  # + Gateway API CRDs + viz; ends with `linkerd check`
```

`install-k3s.sh` ends by printing the `kube-dns` ClusterIP — confirm it matches
`COREDNS_ADDR` (default `10.43.0.10`). `install-linkerd.sh` ends with
`Status check results are √`.

### Box A → deploy the SPIRE server (root stays in the cluster)

```bash
$S linkerd-cluster "bash $D/cluster/spire/apply.sh"   # StatefulSet + NodePort + register; prints a join token
```

It mounts the root (`ca.crt`+`ca.key`) into the server as a read-only Secret,
registers the store's workload identity (selectors `unix:uid:2102` + the proxy
path), restricts the SPIRE NodePort to the interface the edge reaches this host on
(derived from `EDGE_ADDR`; override with `SPIRE_NODEPORT_IFACE`), and prints a
one-time **join token** plus a trust **bundle** (`~/spire-bundle.pem`).

Copy only the bundle and the public root cert to the store — the root **key** never
leaves the cluster. The two boxes have no SSH access to each other, so relay
through your host:

```bash
$S linkerd-edge 'sudo mkdir -p /opt/spire/certs'
$S linkerd-cluster 'cat ~/spire-bundle.pem'      | $S linkerd-edge 'sudo tee /opt/spire/certs/bundle.pem >/dev/null'
$S linkerd-cluster 'cat ~/linkerd-certs/ca.crt'  | $S linkerd-edge 'sudo tee /opt/spire/certs/ca.crt >/dev/null'
```

### Box B — on-prem store (SPIRE agent + proxy + store-pos)

```bash
$S linkerd-edge "bash $D/net/shim.sh"
$S linkerd-edge "bash $D/edge/install-spire-agent.sh <join-token>"   # agent-only; pinned bundle
$S linkerd-edge "bash $D/edge/extract-proxy.sh"
$S linkerd-edge "bash $D/edge/iptables.sh"
$S linkerd-edge "bash $D/store-pos/run-store-pos.sh"     # the POS — pushes to the cloud
```

`install-spire-agent.sh` ends with `Agent is healthy.` `extract-proxy.sh` ends by
running the proxy binary once, which exits with `Invalid configuration: no
destination service configured` — that is expected; it is just a version check.

`store-pos` will log `push error: ENOTFOUND` until the next step creates the
`retail-cloud` Service. That is expected.

### Box A → deploy RetailCloud, THEN Box B → start the proxy

`cluster/retail/apply.sh` creates the `mixed-env` namespace (annotated for
injection), registers `store-pos` as an `ExternalWorkload` (and marks it Ready),
deploys the `retail-cloud` app, and applies the authorization policy.

> Do Box A first, so the `retail-cloud` Service exists when the store starts
> pushing. The `ExternalWorkload` itself is **not** required for the push path —
> the store's identity comes from SPIRE and the policy matches the SPIFFE ID
> directly, so pushes are authorized even with no `ExternalWorkload` present. It is
> what lets the mesh reach the store *as a server* (the appendix's beat3).

```bash
$S linkerd-cluster "bash $D/cluster/retail/apply.sh"   # prints the dashboard URL
$S linkerd-edge    "bash $D/edge/run-proxy.sh"
```

`run-proxy.sh` confirms the identity it received:

```
proxy has identity (uid 2102)
```

Open **`http://192.168.122.10:30080/`** — the store is now pushing its inventory
and sales to the cloud over the mesh, and

```bash
$S linkerd-edge 'sudo docker logs -f store-pos'
```

shows `push -> 200`. Click **Void authorization** to watch identity-based authz
refuse the store's pushes for real (`push -> 403 (authorization voided by cloud)`).

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

## Other topologies

Everything below works but is **not** the verified path. Only the Linux
single-host setup above is tested end to end; if one of these breaks, please file
an issue.

**Two physical Linux hosts.** Skip `host-setup`/`cluster-up`/`edge-up` entirely.
Put the repo and a matching `config.local.env` on both, set `CLUSTER_NODE_ADDR`
and `EDGE_ADDR` to their real addresses, and run the **Build it** steps on each
box directly (`bash <demo>/cluster/gen-certs.sh`, etc.). Mind `APP_UID` on Box B.

**macOS — Lima.** `cluster-up`/`edge-up` fall back to Lima off Linux. The stock
Lima network gives every VM the same address, so attach one that allows VM-to-VM —
`limactl edit <vm> --network lima:user-v2`, while stopped — then copy the **repo
root** into each guest:

```bash
tar --exclude=.git -C <repo> -czf - . \
  | limactl shell <vm> -- bash -c 'mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
limactl shell <vm> bash -lc 'bash ~/linkerd-playground/demos/spiffe-cross-boundary/<script>'
```

> Quote the path as shown. Written unquoted, `~` expands on the **host**, and the
> guest home is never the host's — the guest then gets a path that doesn't exist.

**Lima on Linux is not recommended.** Its only VM-to-VM network (`user-v2`) rides
a QEMU socket netdev that aborts the VM under sustained download load
(`net_fill_rstate: Assertion 'size == 0' failed`), which the Linkerd install
reliably triggers. See [`runlog-linux.md`](runlog-linux.md) F4b. This is why the
Linux path uses libvirt.

**Across networks / NAT.** An optional Tailscale overlay recipe is in
[`connectivity-tailscale.md`](connectivity-tailscale.md).

## Teardown

```bash
just demo spiffe-cross-boundary down     # destroys both VMs and their disks
```

If you ran the boxes on hardware instead: Box A `k3s-uninstall.sh`; Box B remove
the `PROXY_APP_OUTPUT` iptables chain, `/opt/spire`, `/opt/linkerd-proxy`, the
`store-pos` container and `/etc/systemd/resolved.conf.d/cluster.conf`.

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

- **Verified end-to-end on Linux/x86_64**: an Ubuntu 26.04 host running both boxes
  as libvirt VMs (Ubuntu 24.04 guests) on the static-route path — the setup this
  README describes, built from scratch with these scripts. See
  [`runlog-linux.md`](runlog-linux.md). Also verified on **Lima/Apple-Silicon
  (arm64)** over the optional Tailscale overlay, following `MANUAL.md` by hand —
  see [`runlog.md`](runlog.md). Other topologies are config-driven and arch-aware
  but not independently verified.
- **Implementation note:** the `Server` uses `policy.linkerd.io/v1beta3` and targets the
  store-pos workload via `externalWorkloadSelector`; the `retail-cloud` app is granted a
  small RBAC Role to patch the `MeshTLSAuthentication` (that is what the Void button uses).

---

_Made with [Claude Code](https://claude.com/claude-code)._
