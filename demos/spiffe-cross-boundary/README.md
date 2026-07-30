# spiffe-cross-boundary

**Prove that SPIFFE gives a shared trust domain and workload identity to a
non-Kubernetes workload — across a real boundary between two physical machines —
using Linkerd mesh expansion.**

A process Kubernetes has never heard of, running on a *separate machine*,
authenticates to in-cluster services with a cryptographic SPIFFE identity, and
access is gated on **that identity, not on IP or network location**.

Design spec: [`docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md`](../../docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md).

---

## What runs where

| | Box A — cluster | Box B — edge |
|---|---|---|
| Physical | one machine | a **different** machine |
| VM (Lima) | `linkerd-cluster` | `linkerd-edge` |
| Runs | k3s + Linkerd + viz + SPIRE **trust anchor** | SPIRE server+agent + `linkerd2-proxy` + echo app |

The two VMs are distinct network nodes. **SPIRE runs on the edge**, rooted at
Linkerd's trust anchor (copied over), so the edge's SVID chains to the same root
as in-cluster identities — one trust domain, no federation.

## Prerequisites

- **Two physical machines**, each with [Lima](https://lima-vm.io) (`brew install lima`) and IP reachability to each other **by any means you already run** (LAN, VPN, Tailscale, …). The playground does **not** set up networking.
- The repo checked out on **both** machines.
- A `config.local.env` in this directory on both machines:

```bash
cp config.example.env config.local.env
# then edit:
CLUSTER_NODE_ADDR=<address Box B uses to reach Box A>
EDGE_ADDR=<address Box A uses to reach Box B>
```

Everything else in `config.example.env` (VM sizing, CIDRs, Linkerd version,
identity strings) has working defaults.

> Scripts under `cluster/` and `edge/` run **inside** the respective VM. Lima does
> **not** mount the host repo into the guest by default, so copy it in first:
> ```bash
> tar -C <repo> -czf - . | limactl shell <vm> -- bash -c \
>   'rm -rf ~/linkerd-playground && mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
> ```
> then invoke scripts as
> `limactl shell <vm> -- bash ~/linkerd-playground/demos/spiffe-cross-boundary/<script>`.
> Paths below are abbreviated to `<demo>/` for that prefix.

## Connectivity (a precondition — bring your own)

Per the design, the playground **does not provision or prescribe a network**. It
requires only that the two machines already have L3 reachability to each other, and
it adds the minimal generic plumbing Linkerd's data plane needs:

- the edge can reach the cluster **pod + service CIDRs** (`10.42.0.0/16`,
  `10.43.0.0/16`), and
- the edge resolves `*.cluster.local` via CoreDNS.

`net/shim.sh` sets both up: on a **flat LAN** it installs a static route to the
CIDRs via `CLUSTER_NODE_ADDR` and points cluster DNS at CoreDNS. Set
`CLUSTER_NODE_ADDR` and `EDGE_ADDR` in `config.local.env` to the addresses the two
machines already use to reach each other. Any reachability that satisfies the
contract works — the shim detects routes that already exist and only fills in
what's missing.

> Putting Lima VMs directly on a physical LAN requires bridged networking
> (`socket_vmnet`, a one-time `sudo` setup per host); see Lima's networking docs.

For machines that are **not** on the same flat LAN (across NAT/networks), an
optional overlay recipe is in [`connectivity-tailscale.md`](connectivity-tailscale.md).
It is strictly optional — the demo does not depend on it.

## Run it

### Box A — cluster

```bash
just demo spiffe-cross-boundary cluster-up          # create the linkerd-cluster VM
limactl shell linkerd-cluster -- bash <demo>/cluster/gen-certs.sh
limactl shell linkerd-cluster -- bash <demo>/cluster/install-k3s.sh
limactl shell linkerd-cluster -- bash <demo>/cluster/install-linkerd.sh   # also installs Gateway API CRDs
limactl shell linkerd-cluster -- bash <demo>/cluster/apply-echo.sh
```

Confirm the printed `kube-dns` ClusterIP matches `COREDNS_ADDR` (default
`10.43.0.10`); update `config.local.env` if not.

### Copy the trust anchor to the edge

The root CA (`ca.crt` **and** `ca.key`) must reach the edge over whatever
connectivity you have:

```bash
limactl shell linkerd-cluster -- cat linkerd-certs/ca.crt > /tmp/ca.crt
limactl shell linkerd-cluster -- cat linkerd-certs/ca.key > /tmp/ca.key
# transport /tmp/ca.crt + /tmp/ca.key to Box B, then on Box B:
limactl shell linkerd-edge -- sudo mkdir -p /opt/spire/certs
cat /tmp/ca.crt | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/ca.crt >/dev/null
cat /tmp/ca.key | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/ca.key >/dev/null
```

### Box B — edge (SPIRE + proxy prep)

```bash
just demo spiffe-cross-boundary edge-up
limactl shell linkerd-edge -- bash <demo>/net/shim.sh
limactl shell linkerd-edge -- bash <demo>/edge/install-spire.sh
limactl shell linkerd-edge -- bash <demo>/edge/register-workload.sh
limactl shell linkerd-edge -- bash <demo>/edge/extract-proxy.sh
limactl shell linkerd-edge -- bash <demo>/edge/iptables.sh
limactl shell linkerd-edge -- bash <demo>/edge/run-app.sh
```

### Box A → register the edge, THEN Box B → start the proxy

**Order matters:** the proxy fetches its inbound policy from the cluster, so the
`ExternalWorkload` must exist (and be marked Ready — the apply script does this)
*before* the proxy starts.

```bash
# Box A:
limactl shell linkerd-cluster -- bash <demo>/cluster/apply-externalworkload.sh
# Box B:
limactl shell linkerd-edge -- bash <demo>/edge/run-proxy.sh
```

## The three beats

**Beat 1 — cross-boundary mTLS + SPIFFE identity** (on Box A). In-cluster client
calls the VM-hosted echo; the response comes from the edge and `tap` shows
`tls=true`:

```bash
just demo spiffe-cross-boundary beat1
```

**Beat 1b — edge as client** (on Box B). The edge calls an in-cluster service and
presents its SPIFFE identity:

```bash
limactl shell linkerd-edge -- bash "$PWD/scripts/beat1b-edge-client.sh"
# on Box A, read the identity the server saw:
limactl shell linkerd-cluster -- linkerd -n mixed-env viz tap deploy/echo | grep -m1 client_id
```

**Beat 2 — identity-based authz, 200 → 403** (the core demonstration, on Box A).
Allow only the edge's SPIFFE ID, then flip to a different ID; the edge's call goes
from 200 to 403 with **nothing about the network changed**:

```bash
just demo spiffe-cross-boundary beat2
# run the printed curl FROM the edge VM at each step
```

**Beat 3 (stretch) — authorized mTLS *to* the edge** (on Box A):

```bash
just demo spiffe-cross-boundary beat3
```

## Teardown

```bash
just demo spiffe-cross-boundary down     # on each box
```

## Caveats (honest scope)

- **The root CA key lives on the edge.** SPIRE's `UpstreamAuthority` uses the
  Linkerd trust anchor `ca.key`, copied to the edge. Fine for a playground; a
  real deployment (e.g. `stack-control`) would use an intermediate instead.
- **`MeshTLSAuthentication.identities`** uses the edge's `spiffe://` URI verbatim
  (confirmed working). If a policy doesn't flip to 403, read the exact client
  identity via `linkerd viz tap` (command printed by `beat2`) and use it verbatim.
- **`join_token` attestation** is chosen for portability across any
  infrastructure — swap for cloud/x509 attestation on real infra.
- **Verified end-to-end on Lima/Apple-Silicon (arm64).** All four beats were run
  and pass. That run used the optional overlay recipe
  ([`connectivity-tailscale.md`](connectivity-tailscale.md)) for reachability; the
  default LAN path uses the same `net/shim.sh` static-route mechanism. Other
  providers/arches are config-driven and arch-aware but not independently verified.
- **`Server` uses `policy.linkerd.io/v1beta3`**; the edge-facing Server targets the
  workload via `externalWorkloadSelector` (confirmed available in v1beta3).
