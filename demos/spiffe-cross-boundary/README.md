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

> Scripts under `cluster/` and `edge/` run **inside** the respective VM. Lima
> mounts the repo path through to the guest, so invoke them with
> `limactl shell <vm> -- bash <repo>/demos/spiffe-cross-boundary/<script>`.

## Run it

### Box A — cluster

```bash
just demo spiffe-cross-boundary cluster-up          # create the linkerd-cluster VM
limactl shell linkerd-cluster -- bash "$PWD/cluster/gen-certs.sh"
limactl shell linkerd-cluster -- bash "$PWD/cluster/install-k3s.sh"
limactl shell linkerd-cluster -- bash "$PWD/cluster/install-linkerd.sh"
limactl shell linkerd-cluster -- bash "$PWD/cluster/apply-echo.sh"
```

Confirm the printed `kube-dns` ClusterIP matches `COREDNS_ADDR` (default
`10.43.0.10`); update `config.local.env` if not.

### Copy the trust anchor to the edge

The root CA must reach the edge (over whatever connectivity you have). From Box A:

```bash
limactl shell linkerd-cluster -- cat '~/linkerd-certs/ca.crt' > /tmp/ca.crt
limactl shell linkerd-cluster -- cat '~/linkerd-certs/ca.key' > /tmp/ca.key
scp /tmp/ca.crt /tmp/ca.key <box-b>:/tmp/            # or any transport you trust
```

On Box B, place them where SPIRE expects:

```bash
limactl shell linkerd-edge -- sudo mkdir -p /opt/spire/certs
limactl shell linkerd-edge -- sudo cp /tmp/ca.crt /tmp/ca.key /opt/spire/certs/
```

### Box B — edge

```bash
just demo spiffe-cross-boundary edge-up             # create the linkerd-edge VM
limactl shell linkerd-edge -- bash "$PWD/net/shim.sh"
limactl shell linkerd-edge -- bash "$PWD/edge/install-spire.sh"
limactl shell linkerd-edge -- bash "$PWD/edge/register-workload.sh"
limactl shell linkerd-edge -- bash "$PWD/edge/extract-proxy.sh"
limactl shell linkerd-edge -- bash "$PWD/edge/iptables.sh"
limactl shell linkerd-edge -- bash "$PWD/edge/run-app.sh"
limactl shell linkerd-edge -- bash "$PWD/edge/run-proxy.sh"
```

Then register the edge in the cluster (on Box A):

```bash
limactl shell linkerd-cluster -- bash "$PWD/cluster/apply-externalworkload.sh"
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

**Beat 2 — identity-based authz, 200 → 403** (the money shot, on Box A). Allow
only the edge's SPIFFE ID, then flip to a different ID; the edge's call goes from
200 to 403 with **nothing about the network changed**:

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
- **`MeshTLSAuthentication.identities`** is set to the edge's `spiffe://` URI —
  the most likely value. If Beat 2 doesn't flip to 403, read the exact client
  identity via `linkerd viz tap` (command printed by `beat2`) and use it verbatim.
- **`join_token` attestation** is chosen for portability across any
  infrastructure — swap for cloud/x509 attestation on real infra.
- **Only the Lima-on-Apple-Silicon path is verified.** Other providers/arches are
  config-driven and arch-aware but not CI-verified.
- **Beat 3's `Server` selector** for an ExternalWorkload is flagged in
  `cluster/authz-edge-server.yaml` to confirm against `kubectl explain server.spec`.
