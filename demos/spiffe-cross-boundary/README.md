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

The demo assumes two Linux hosts that can reach each other at L3. The **recommended
and verified setup is one Linux host running both as local VMs**, which the repo
provisions for you.

- One Linux host with KVM (Ubuntu 26.04 verified), ~10 GiB free RAM and ~30 GiB disk.
- A checkout of this repo, and [`just`](https://github.com/casey/just).

```bash
cd <repo>
cp demos/spiffe-cross-boundary/config.example.env demos/spiffe-cross-boundary/config.local.env
just demo spiffe-cross-boundary host-setup
```

`host-setup` is a one-time step and needs `sudo`: it installs libvirt/KVM and the
emulator for your host's architecture, and adds you to the `libvirt` group.

> **Log out and log back in before continuing.** `host-setup` adds you to the
> `libvirt` group, and group membership only applies to a **new login session** —
> a new terminal window is not enough. Until you do, every command fails with
> `Permission denied` on `/var/run/libvirt/libvirt-sock`. Verify with
> `virsh -c qemu:///system list --all`.

Then bring up both boxes:

```bash
just demo spiffe-cross-boundary cluster-up &&
just demo spiffe-cross-boundary edge-up
```

That gives you Box A at `192.168.122.10` and Box B at `192.168.122.11`.
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

<!--
Keep the pasteable code blocks free of trailing "# ..." comments.
Interactive zsh (the macOS default shell) does not treat # as a comment, so a
pasted line runs the comment text as arguments or, where the comment contains
";", as a second command -- and backticks inside it execute on the reader's host.
Put the explanation in prose under the block instead.
-->

## Build it

The steps below use the repo's scripts and are the **verified path**. To understand
every piece instead — each config file and command, with the *why* behind them —
follow the from-scratch manual: [`MANUAL.md`](MANUAL.md).

Each block runs **on the box named in its heading**. Shown here driven over ssh
from your host, with `S` as a shorthand:

```bash
S() { ssh -F "$HOME/.ssh/linkerd-playground.conf" "$@"; }
D='~/linkerd-playground/demos/spiffe-cross-boundary'
```

> Copy those two lines exactly, tildes and quotes included.
>
> `S` is a **function**, not a string, so that this works in `zsh` as well as
> `bash`. Written as `S="ssh -F …"` and called as `$S linkerd-cluster …`, it would
> rely on the shell splitting an unquoted variable into separate words — `bash`
> does that, `zsh` does not. Since `zsh` is the default macOS shell, the string
> form fails there on the very first command:
> `no such file or directory: ssh -F …`.
>
> `$HOME` inside `S` because a `~` in double quotes is never expanded — `ssh`
> would take it literally and fail with `Can't open user config file`. `D` is
> single-quoted for the opposite reason: it must reach the **guest** shell
> unexpanded, since your home on the host is not the VM user's home.

> **On OrbStack**, `S` points at OrbStack's ssh proxy rather than a VM address.
> [`README-ORBSTACK.md`](README-ORBSTACK.md) creates the machines, writes that
> config, and returns you here — nothing else in this section changes.

### Step 1 — Box A: Kubernetes cluster

```bash
S linkerd-cluster "bash $D/cluster/gen-certs.sh" &&
S linkerd-cluster "bash $D/cluster/install-k3s.sh" &&
S linkerd-cluster "bash $D/cluster/install-linkerd.sh"
```

`gen-certs.sh` writes the trust anchor and issuer certificates.
`install-k3s.sh` ends by printing the `kube-dns` ClusterIP — confirm it matches
`COREDNS_ADDR` (default `10.43.0.10`). `install-linkerd.sh` ends with
`Status check results are √`.

> **`install-linkerd.sh` goes quiet twice. Both are normal.** It runs
> `linkerd check` after installing the control plane, and again after installing
> viz. Each run polls while pods pull images and become ready, printing nothing
> until they do — on a first run that is typically a minute or two per pause,
> longer on a slow connection.
>
> The first pause is at `√ control plane pods are ready`, right after the
> `linkerd-existence` block. The second is at `√ viz extension pods are running`,
> and is usually the longer of the two — viz pulls five more images
> (`prometheus`, `tap`, `tap-injector`, `web`, `metrics-api`).
>
> When it finishes you will also see several `‼ proxies are up-to-date` warnings
> listing pods at the pinned `edge-26.7.2`. Those note that a newer Linkerd edge
> exists than this demo pins; they are expected and not failures. The run is good
> if the last line is `Status check results are √`.

### Step 2 — Box A: deploy the SPIRE server (root stays in the cluster)

```bash
S linkerd-cluster "bash $D/cluster/spire/apply.sh"
```

It mounts the root (`ca.crt`+`ca.key`) into the server as a read-only Secret,
registers the store's workload identity (selectors `unix:uid:2102` + the proxy
path), restricts the SPIRE NodePort to the interface the edge reaches this host on
(derived from `EDGE_ADDR`; override with `SPIRE_NODEPORT_IFACE`), and prints a
one-time **join token** plus a trust **bundle** (`~/spire-bundle.pem`).

**Copy the join token somewhere before it scrolls away** — step 4 takes it as an
argument, and it is one-time. Lost it? Re-running this step is safe: it keeps the
existing registration entry and prints a fresh token.

### Step 3 — relay the bootstrap material to Box B

Copy the trust bundle, the public root cert, and the join token to the store — the
root **key** never leaves the cluster. The two boxes have no SSH access to each
other, so relay through your host:

```bash
S linkerd-edge 'sudo mkdir -p /opt/spire/certs' &&
S linkerd-cluster 'cat ~/spire-bundle.pem'      | S linkerd-edge 'sudo tee /opt/spire/certs/bundle.pem >/dev/null' &&
S linkerd-cluster 'cat ~/linkerd-certs/ca.crt'  | S linkerd-edge 'sudo tee /opt/spire/certs/ca.crt >/dev/null' &&
S linkerd-cluster 'cat ~/spire-join-token'      | S linkerd-edge 'sudo tee /opt/spire/join-token >/dev/null'
```

That last line is why step 4 needs nothing typed in by hand: the join token is
bootstrap material like the bundle, so it travels the same way.
`install-spire-agent.sh` reads `/opt/spire/join-token` when given no argument.

> **Check what landed before moving on.** The `&&` between these lines stops the
> chain if a command fails, but each line here is a *pipeline*, and a pipeline's
> exit status is its last command's. If a `cat` finds nothing, the `tee` still
> succeeds and writes an **empty** file — reported as success. The failure then
> surfaces much later, as an agent that cannot attest. So confirm all three
> arrived non-empty:
>
> ```bash
> S linkerd-edge 'sudo ls -l /opt/spire/certs/bundle.pem /opt/spire/certs/ca.crt /opt/spire/join-token'
> ```

### Step 4 — Box B: on-prem store (SPIRE agent + proxy + store-pos)

```bash
S linkerd-edge "bash $D/net/shim.sh" &&
S linkerd-edge "bash $D/edge/install-spire-agent.sh" &&
S linkerd-edge "bash $D/edge/extract-proxy.sh" &&
S linkerd-edge "bash $D/edge/iptables.sh" &&
S linkerd-edge "bash $D/store-pos/run-store-pos.sh"
```

> `net/shim.sh` picks the resolver mechanism the box actually uses — a
> `systemd-resolved` drop-in where that is running, or `/etc/resolv.conf` directly
> where it is masked or absent (OrbStack, minimal images). Either way it then
> resolves a real cluster name before reporting success, and stops with a
> diagnosis if it cannot. Stopping there usually means Box A has not run yet.

`install-spire-agent.sh` ends with `Agent is healthy.` `extract-proxy.sh` ends by
reporting the proxy release it extracted, and fails if it cannot confirm one —
that version has to match the control plane.

`store-pos` will log `push error: ECONNREFUSED` until step 5 starts the proxy. That
is expected: `iptables.sh` has already redirected this app's outbound TCP to port
4140, and nothing is listening there until `run-proxy.sh` runs.

### Step 5 — Box A: deploy RetailCloud, THEN Box B: start the proxy

`cluster/retail/apply.sh` creates the `mixed-env` namespace (annotated for
injection), registers `store-pos` as an `ExternalWorkload` (and marks it Ready),
deploys the `retail-cloud` app, and applies the authorization policy.

> Do Box A first, so the `retail-cloud` Service exists when the store starts
> pushing. The `ExternalWorkload` itself is **not** required for the push path —
> the store's identity comes from SPIRE and the policy matches the SPIFFE ID
> directly, so pushes are authorized even with no `ExternalWorkload` present. It is
> what lets the mesh reach the store *as a server*.

```bash
S linkerd-cluster "bash $D/cluster/retail/apply.sh" &&
S linkerd-edge    "bash $D/edge/run-proxy.sh"
```

`run-proxy.sh` confirms the identity it received:

```
proxy has identity (uid 2102)
```

Open the dashboard. Both `retail/apply.sh` and `run-proxy.sh` print its URL, and
you can ask for it again at any time:

```bash
S linkerd-cluster "bash $D/cluster/retail/url.sh"
```

Neither half of that URL is written down here on purpose: the address depends on
your topology, and the port is a NodePort Kubernetes assigns. The script asks the
cluster for both. The store is now pushing its inventory and sales to the cloud
over the mesh, and

```bash
S linkerd-edge 'sudo docker logs -f store-pos'
```

shows `push -> 200`. Click **Void authorization** to watch identity-based authz
refuse the store's pushes for real (`push -> 403 (authorization voided by cloud)`).

## If a step goes wrong

**`[error] cluster node <address> not reachable — fix your base network first`** —
`net/shim.sh` is refusing to route to an address nothing answers on. Your
`config.local.env` is missing or holds the wrong addresses: without that file the
scripts fall back to `config.example.env`, whose defaults are the **libvirt**
addresses (`192.168.122.10`/`.11`). Put the addresses your boxes actually have in
`config.local.env` — `cluster-up`/`edge-up` print them on the Lima path, `orb list`
shows them on OrbStack — and copy that file into **both** guests, since the scripts
run there and read it there.

**Re-running steps.** These are safe to run again:

| Step | On a re-run |
|---|---|
| `gen-certs.sh` | keeps existing certs (guarded by `if [ ! -f ca.crt ]`) |
| `spire/apply.sh` | keeps the existing registration entry, prints a **fresh join token** |
| `net/shim.sh` | idempotent; skips routes already present |
| `extract-proxy.sh`, `iptables.sh` | report `already configured` and do nothing |
| `retail/apply.sh` | re-applies the manifests |

`install-spire-agent.sh` is the exception: each run needs a **new** join token.
Getting one takes **two** steps, not one — re-run step 2 to issue it, then **step 3
to relay it**. Step 2 writes the new token to `~/spire-join-token` on the cluster;
until step 3 copies it across, the edge still holds the previous one and the agent
fails with:

```
failed to attest: join token does not exist or has already been used
```

That message means the token the edge has was already consumed, not that anything
is misconfigured. The agent keeps retrying in the background after the script
exits; the next successful run replaces it.

**The proxy panics with a Rust stack trace.**

```
thread 'admin' panicked at .../spire-client/src/lib.rs:35:14:
spire client must gracefully handle errors: ... ConnectError(Os { code: 2, kind: NotFound ...
```

That is the proxy failing to open the SPIRE agent's socket at
`/tmp/spire-agent/public/api.sock`, because no agent is running to create it — the
proxy has no identity source and cannot start. It means step 4's
`install-spire-agent.sh` did not take effect, not that the proxy is broken. Check
with `S linkerd-edge 'ls /opt/spire/'`: a `bin/` directory and `agent.cfg` should
be there alongside `certs/`.

**Nothing is pushing.** The `store-pos` log says where it stopped.
`ENOTFOUND` means cluster DNS is not configured — `net/shim.sh` has not run, or did
not take effect. `ECONNREFUSED` means DNS resolves but the connection is refused
locally: `iptables.sh` redirects this app's outbound TCP to port 4140 and the proxy
is not listening there, so run step 5's `run-proxy.sh`. Note that the redirect
makes `ECONNREFUSED` the expected symptom whether or not `retail-cloud` exists yet
— the app never reaches the cluster to find out.

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

The Linux single-host setup above is the path the scripts drive by default. Two of
the alternatives below have their own end-to-end runlogs — macOS/OrbStack
([`runlog-orbstack.md`](runlog-orbstack.md)) and macOS/Lima
([`runlog.md`](runlog.md)); the rest are config-driven but not independently
verified. If one of them breaks, please file an issue.

**Two physical Linux hosts.** Skip `host-setup`/`cluster-up`/`edge-up` entirely.
Put the repo and a matching `config.local.env` on both, set `CLUSTER_NODE_ADDR`
and `EDGE_ADDR` to their real addresses, and run the **Build it** steps on each
box directly (`bash <demo>/cluster/gen-certs.sh`, etc.). Mind `APP_UID` on Box B.

**macOS — Lima.** `cluster-up`/`edge-up` fall back to Lima off Linux, and on Apple
Silicon they create native arm64 guests (Lima picks the image by host
architecture). Each script prints the address its VM came up on, for
`config.local.env`:

```
[cluster-up.sh] linkerd-cluster is at 192.168.104.1 -- set CLUSTER_NODE_ADDR=192.168.104.1 in config.local.env
[edge-up.sh]    linkerd-edge is at 192.168.104.3 -- set EDGE_ADDR=192.168.104.3 in config.local.env
```

The VM-to-VM network is declared in `provisioners/lima/*.yaml` and applied at
creation, so no `limactl edit` step is needed. (Stock Lima gives every guest the
same `192.168.5.15` on an isolated NAT; without that declaration the two boxes come
up "ready" and unable to see each other.)

Then copy the **repo root** into each guest:

```bash
tar --no-xattrs --exclude=.git -C <repo> -czf - . \
  | limactl shell <vm> -- bash -c 'mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
limactl shell <vm> bash -lc 'bash ~/linkerd-playground/demos/spiffe-cross-boundary/<script>'
```

> Quote the path as shown. Written unquoted, `~` expands on the **host**, and the
> guest home is never the host's — the guest then gets a path that doesn't exist.

> `--no-xattrs` stops macOS packing its extended attributes into the archive.
> Without it the guest's GNU tar prints
> `Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.provenance'`
> once per file. That warning is harmless — it is a macOS Gatekeeper tag with no
> meaning on Linux, and nothing about the file contents is lost — but there is no
> reason to ship it.

**macOS — OrbStack.** Two native arm64 machines, each a box, reachable from each
other with no network setup. Full recipe in
[`README-ORBSTACK.md`](README-ORBSTACK.md): it creates the machines, wires `S` to
them, and hands you back to **Build it**. Verified end to end —
[`runlog-orbstack.md`](runlog-orbstack.md).

**Lima on Linux is not recommended.** Its only VM-to-VM network (`user-v2`) rides
a QEMU socket netdev that aborts the VM under sustained download load
(`net_fill_rstate: Assertion 'size == 0' failed`), which the Linkerd install
reliably triggers. See [`runlog-linux.md`](runlog-linux.md) F4b. This is why the
Linux path uses libvirt.

**Across networks / NAT.** An optional Tailscale overlay recipe is in
[`connectivity-tailscale.md`](connectivity-tailscale.md).

## Teardown

```bash
just demo spiffe-cross-boundary down
```

That destroys both VMs and their disks.

If you ran the boxes on hardware instead: Box A `k3s-uninstall.sh`; Box B remove
the `PROXY_APP_OUTPUT` iptables chain, `/opt/spire`, `/opt/linkerd-proxy`, the
`store-pos` container and `/etc/systemd/resolved.conf.d/cluster.conf`.

## Scope — this is a teaching demo

Built for explanatory clarity, not production practice. It takes deliberate shortcuts —
the app holding RBAC to change its own policy, `join_token` attestation, processes run
without supervision, and more.
[`PRODUCTION-NOTES.md`](PRODUCTION-NOTES.md) catalogues each shortcut and the production
practice that should replace it.

- **Verified end-to-end on both x86_64 and arm64.** Nothing here needs a particular
  architecture: every artifact the demo installs resolves its own build. Three
  independent runs:
  - **Linux/x86_64, libvirt** — an Ubuntu 26.04 host running both boxes as libvirt
    VMs (Ubuntu 24.04 guests) on the static-route path, the setup this README
    describes, built from scratch with these scripts:
    [`runlog-linux.md`](runlog-linux.md).
  - **macOS/Apple Silicon (arm64), OrbStack** — both boxes as native arm64
    machines, using the two-hosts topology: [`runlog-orbstack.md`](runlog-orbstack.md).
  - **macOS/Apple Silicon (arm64), Lima** — twice: once following `MANUAL.md` by
    hand over the optional Tailscale overlay ([`runlog.md`](runlog.md)), and once
    through the scripted path above (`cluster-up`/`edge-up` then **Build it**),
    ending at `push -> 200` with the store's SPIFFE identity on the wire.

  On an Apple Silicon Mac, run the guests as **arm64**. Deliberately choosing an
  x86_64 guest (`orb create -a amd64`, an Intel Lima VM, a cross-arch
  `VM_IMAGE_URL`) means emulation, and the demo becomes unusably slow. The scripts
  now make that the default rather than something you have to know: `host-setup.sh`
  installs the emulator for the host's architecture, `cluster-up`/`edge-up` derive
  the guest image from it, and a cross-architecture `VM_IMAGE_URL` is refused
  instead of quietly emulated.

  **What that last part has and has not been run against:** the arch selection and
  the refusal are verified on a real arm64 Linux host, and the x86_64 libvirt path
  is unchanged in behaviour and covered by [`runlog-linux.md`](runlog-linux.md).
  Nobody has yet *booted* an arm64 libvirt guest with these scripts — that needs an
  arm64 Linux host with KVM, which none of the three runs above provide. The UEFI
  firmware flag arm64 guests require (`--boot uefi`, since aarch64 has no BIOS) is
  therefore written but unexercised. If you run the libvirt path on arm64 Linux,
  that is the step most likely to need adjusting — please file an issue.
- **Implementation note:** the `Server` uses `policy.linkerd.io/v1beta3` and targets the
  store-pos workload via `externalWorkloadSelector`; the `retail-cloud` app is granted a
  small RBAC Role to patch the `MeshTLSAuthentication` (that is what the Void button uses).
