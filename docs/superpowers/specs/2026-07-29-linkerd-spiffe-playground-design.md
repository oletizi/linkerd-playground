---
title: Linkerd + SPIFFE Cross-Boundary Playground — Design
date: 2026-07-29
status: approved
---

# Linkerd + SPIFFE Cross-Boundary Playground

## Purpose

Build a reproducible, **machine-agnostic** playground that demonstrates how
SPIFFE provides a **shared trust domain** and **workload identities** across an
infrastructure boundary, using **Linkerd mesh expansion** to bring a
**non-Kubernetes workload** into the mesh. It is the backing artifact for a blog
post on SPIFFE in Linkerd, is intended to grow into a **public demo** others can
run on their own hardware, and is a first rehearsal for a later `stack-control`
fleet control plane that needs a multi-infrastructure shared trust domain.

The headline demonstration: a process Kubernetes has never heard of, running on a
separate machine, authenticates to in-cluster services with a cryptographic
SPIFFE identity, and access is gated on that identity rather than on network
location.

## Background (why this is feasible)

Linkerd 2.15+ ships **mesh expansion**: workloads outside Kubernetes join the
mesh by running a standalone `linkerd2-proxy` whose identity is issued by
**SPIRE** (via the SPIFFE Workload API) instead of Linkerd's in-cluster identity
service. Because SPIRE is configured with **Linkerd's trust anchor as its
upstream CA**, SPIRE-issued SVIDs and Linkerd's ServiceAccount-based certs chain
to the same root — so mTLS works across the boundary with no federation.

References:
- Announcing Linkerd 2.15 — VM workloads, native sidecars, SPIFFE:
  https://linkerd.io/2024/02/21/announcing-linkerd-2.15/
- Adding non-Kubernetes workloads to your mesh:
  https://linkerd.io/2-edge/tasks/adding-non-kubernetes-workloads/

## Host contract (OS-neutral)

The playground targets **two Linux hosts, each its own Tailscale node**. Nearly
everything in the stack (k3s, Linkerd, SPIRE, the Tailscale subnet router,
iptables, `ExternalWorkload`) is pure Linux and ships both `arm64` and `amd64`,
so the core is portable. Only the way you *produce* the two Linux hosts varies by
hardware — that is the swappable **provisioner** layer.

| Box | Must provide |
|---|---|
| **Box A — cluster** | A Linux tailnet node that can run k3s, advertise routes (IP forwarding), and reach Box B |
| **Box B — edge** | A Linux tailnet node that can run iptables redirection + a standalone `linkerd2-proxy`, and reach Box A's advertised routes |

Design intent: the demo runs in **disposable VMs on every host** (isolation +
easy teardown), even on Linux. Because the bootstrap always runs inside a Linux
VM, there is a single uniform Linux path everywhere — no separate bare-metal
branch to maintain. `tailscaled` runs **inside** each VM, so each VM is a
first-class tailnet node, not hidden behind a host's Tailscale.

## Portability: provisioners & architecture

A **provisioner** produces one Linux VM that satisfies the host contract. The
core bootstrap is identical across all of them.

| Host OS | Provisioner | Status |
|---|---|---|
| macOS (Apple Silicon) | **Lima** (arm64 guest) | **Reference — tested** |
| macOS (Intel) | Lima (amd64 guest) | Portable by construction |
| Linux (arm64 / amd64) | Lima (QEMU backend) | Portable by construction |
| Windows | multipass or WSL2 | Documented |
| Cloud (any) | a Linux instance in a VPC, joined to the tailnet | Documented |

- **Lima is the default provider** because it runs on both macOS and Linux, and
  its VM definitions are committable YAML (CPUs, memory, mounts, provisioning).
- **Architecture-aware bootstrap:** scripts detect `uname -m` and pull the
  matching `linkerd2-proxy` binary and container images (`arm64` vs `amd64`).
- **Config-driven, not hardcoded:** a `config.example.env` declares the two
  target hosts, provider, VM sizing, and pod/service CIDRs. Real values live in a
  gitignored local override. The two-Mac setup below is the *example*, not baked
  into the code.

### Reference environment (what this was authored on)

Two Apple Silicon Macs, each already a Tailscale node, each hosting a Lima VM
that is its own tailnet node. The crossed boundary is orion-m1 ↔ orion-m4: two
physical machines with WireGuard between them.

| Role | Physical host | Linux VM (tailnet node) | Runs |
|---|---|---|---|
| **Box A — cluster** | orion-m1 (M1, 16 GB, `100.96.71.14`) | `linkerd-cluster` (~8 GB) | k3s + Linkerd control plane + `linkerd viz` + SPIRE server + Tailscale **subnet router** |
| **Box B — edge** | orion-m4 (M4, 16 GB, `100.65.31.54`) | `linkerd-edge` (~4 GB) | tailscaled + SPIRE agent + standalone `linkerd2-proxy` + demo app |

### Why these choices

- **VM per host, not bare-metal.** Even on Linux, a disposable VM keeps the demo
  isolated and tear-down clean, and yields one uniform bootstrap path.
- **Lima, not Docker/k3d.** k3d nests pod IPs on a Docker bridge inside Docker's
  own Linux VM; advertising that CIDR across Tailscale means several NAT layers —
  the fragile path. A real Linux VM host network stack makes advertising the pod
  CIDR the documented, textbook case.
- **k3s, not kind/k3d.** Runs on the VM host directly, so pod CIDR
  (`10.42.0.0/16`) and service CIDR (`10.43.0.0/16`, both config-overridable) are
  host-visible and advertisable by a subnet router.
- **Host subnet router, not the Tailscale K8s operator.** Mesh expansion needs
  the edge proxy to reach real **pod IPs** (`linkerd-dst-headless` is headless —
  no VIP). A subnet router advertising the pod+service CIDRs delivers that.

## Trust wiring

- **One SPIFFE trust domain.** Linkerd's trust anchor (`ca.crt`/`ca.key`) is the
  root.
- **SPIRE server** (in-cluster) runs with `UpstreamAuthority` = disk plugin
  loaded with the Linkerd trust anchor, so SPIRE-issued SVIDs chain to the same
  root as Linkerd's in-cluster ServiceAccount identities.
- **SPIRE agent** on the edge VM.
- **Attestation:**
  - Node (agent → server): **`join_token`** — portable over the tailnet, no
    cloud metadata. The natural thing to swap for real infra attestation later in
    `stack-control`.
  - Workload (on edge): **`unix`** attestor — maps the `linkerd2-proxy`
    process's uid/path to its registration entry.
- **Binding:** a SPIRE registration entry → `spiffe://<trust-domain>/edge/echo`,
  plus an `ExternalWorkload` CRD in-cluster carrying that SPIFFE ID, the edge
  VM's tailnet IP, and its ports.

> The exact SPIFFE ID string scheme (trust-domain value + `ExternalWorkload`
> path convention) is to be pinned against the Linkerd/SPIRE docs during
> planning; strings here are illustrative examples.

## Networking

- **Box A VM:** `tailscale ... --advertise-routes=<pod-cidr>,<service-cidr>`
  (defaults `10.42.0.0/16,10.43.0.0/16`) + IP forwarding; routes approved in the
  tailnet.
- **Box B VM:** `tailscale up --accept-routes`.
- **Split-DNS:** tailnet rule mapping `cluster.local` → CoreDNS ClusterIP, so the
  edge resolves `linkerd-dst-headless…` / `linkerd-policy…`.
- **Return path (validate early):** pods must reach the edge's tailnet IP via the
  node's `tailscale0`. This is the one integration risk; it is proven in Beat 1
  before any policy is layered on top.

## Demonstration arc

The app is a trivial HTTP echo service so all attention is on identity.

**Beat 1 — Cross-boundary mTLS with a SPIFFE identity.**
The edge workload calls an in-cluster echo service. `linkerd viz tap`/`edges`
shows the server proxy reporting the client identity as `spiffe://…/edge/echo`.
*Proves the shared trust domain reaches outside the cluster.*

**Beat 2 — Identity-based authz across the boundary (the money shot).**
An `AuthorizationPolicy` + `MeshTLSAuthentication` on the in-cluster service
permits **only** the edge's SPIFFE ID.
- Edge calls → **200**.
- Change the required identity → same edge calls now **403**, with no change to
  network/IP/firewall.
*Proves access is gated on cryptographic workload identity, not location.*

**Beat 3 (stretch) — Encrypt + authorize traffic *to* the edge.**
An in-cluster client calls a service hosted on the edge VM; traffic is
mTLS-encrypted to the off-cluster workload and the edge enforces authz on the
caller's in-cluster identity (Linkerd 2.15's "encrypt all traffic to VM
workloads"). Built only if Beats 1–2 land with time to spare; a natural second
act for the post.

## Repo layout

```
config.example.env    declares provider, hosts, VM sizing, pod/service CIDRs
                      (real values in a gitignored config.local.env)
provisioners/
  lima/               cluster.yaml, edge.yaml            (default provider)
  multipass/          cloud-init equivalents             (documented alt)
cluster/              k3s + linkerd + spire-server + app + authz + externalworkload
edge/                 spire-agent config, proxy launch + iptables scripts, app
scripts/              up / down / status / per-beat scripts (idempotent, resumable, arch-aware)
docs/                 walkthrough that becomes the blog-post backbone
Justfile              single entrypoint
```

- This layer is **bash + YAML**, not TypeScript: declarative infra + shell glue
  is the right tool. (Global TS/`@/` preferences apply to application code.)
- Scripts are idempotent and resumable (skip already-done units), arch-detecting;
  no `#` inside heredocs (use files); no `sed` writes.

## Success criteria

1. `just up` reads config, provisions two Linux VMs via the configured provider,
   and brings cluster + Linkerd + SPIRE + edge workload online, idempotently.
2. Beat 1: `linkerd viz tap` shows the edge's `spiffe://…` client identity on a
   cross-boundary call.
3. Beat 2: flipping the authz identity alone flips 200 → 403.
4. Beat 3 (stretch): in-cluster → edge mTLS.
5. Reproducible, documented, tears down cleanly (`just down`).
6. `docs/` walkthrough is sufficient to anchor the blog post and lets a stranger
   run it on their own hardware via the provisioner matrix.

## Non-goals

HA, multi-node clusters, production hardening, cert-rotation deep-dive, and
cloud-instance attestation are all out of scope. Single k3s node, single edge
workload, `join_token` attestation.

**Tested scope:** only the Lima-on-Apple-Silicon path is verified on available
hardware. Other providers and architectures are kept correct-by-construction
(config-driven, arch-aware) and documented, but are not CI-verified — stated
plainly rather than claimed as "works everywhere."

## Relationship to stack-control (second concern)

`stack-control`'s fleet control plane needs a multi-infrastructure shared trust
domain; its control plane already binds to the Tailscale interface. This
playground is a faithful small-scale rehearsal: same Tailscale trust fabric, same
SPIFFE shared-trust-domain mechanics. That work is a separate spec; nothing here
should hard-depend on the reference-environment specifics in a way that blocks
generalizing to real infra (hence `join_token` attestation, config-driven hosts,
and portable VM defs).
