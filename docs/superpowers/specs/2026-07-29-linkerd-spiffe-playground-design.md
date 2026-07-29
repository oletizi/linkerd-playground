---
title: Linkerd + SPIFFE Cross-Boundary Playground — Design
date: 2026-07-29
status: approved
---

# Linkerd + SPIFFE Cross-Boundary Playground

## Purpose

Build a reproducible, **infrastructure-agnostic** playground that demonstrates
the core SPIFFE thesis: **a unified trust domain and workload identity that are
independent of the network and the underlying infrastructure.** It uses
**Linkerd mesh expansion** to bring a **non-Kubernetes workload** into the mesh,
is the backing artifact for a blog post on SPIFFE in Linkerd, is intended to grow
into a **public demo** others can run on their own machines and networks, and is
a first rehearsal for a later `stack-control` fleet control plane that needs a
multi-infrastructure shared trust domain.

This is the **first of several demos** the repository will house. The repo's top
level is organized as a demo *collection*; this SPIFFE case lives in its own
self-contained demo directory (`demos/spiffe-cross-boundary/`) and does **not**
define the repo. Shared tooling is extracted from real duplication once a second
demo exists — not pre-built.

The demo **crosses a real boundary between two physical machines** — that is the
point, so it never collapses onto a single host. The headline: a process
Kubernetes has never heard of, on a *separate machine*, authenticates to
in-cluster services with a cryptographic SPIFFE identity, and access is gated on
**that identity, not on IP, subnet, or network location.**

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

## Network independence (the SPIFFE thesis) — and what the demo actually needs

SPIFFE decouples **identity and trust** from the network: a workload's SVID, not
its IP or location, is what authenticates and authorizes it. The playground
therefore **does not prescribe, provision, or depend on any particular network
infrastructure.** There is no "connectivity provider" to choose.

Two honest, separate facts keep the demo from overclaiming:

- **Trust/identity — network-independent (what SPIFFE proves).** The edge
  workload is authorized by its SPIFFE identity, not by IP, subnet, or firewall.
  Move it to a different network and nothing about trust changes. This is the
  thesis the demo centers.
- **Data-plane connectivity — a precondition SPIFFE does not remove.** Linkerd's
  proxy still needs IP packets to reach in-cluster pods and resolve cluster DNS.
  SPIFFE issues identity; it does not conjure routes. This is a *Linkerd*
  requirement, orthogonal to SPIFFE, and the demo names it as such.

**Precondition — bring your own reachability.** The two machines can already
reach each other over IP by *any* means — LAN, VPN, Tailscale, WireGuard, a cloud
VPC, a crossover cable. The playground neither sets this up nor cares which it is.
The only network inputs in config are generic addresses you already use:
`CLUSTER_NODE_ADDR` (how you reach Box A) and `EDGE_ADDR` (how the cluster reaches
Box B).

Given that reachability, the playground adds the **minimal, generic plumbing
Linkerd's data plane requires**, expressed independently of the network:

1. a route from the edge to the cluster **pod + service CIDRs** via
   `CLUSTER_NODE_ADDR`;
2. `cluster.local` DNS → the cluster's CoreDNS.

These are two provider-neutral steps (a static route + a stub resolver entry),
not a pluggable network layer — and they are flagged in the walkthrough as
Linkerd's data-plane need, so the identity-vs-connectivity boundary stays clear.

**Return-path check (validate early):** in-cluster pods must reach `EDGE_ADDR`.
This is the one integration risk and is proven in Beat 1 before any policy is
layered on top.

## Host contract (OS-neutral)

The playground targets **two Linux hosts on two separate physical machines**.
Nearly everything in the stack (k3s, Linkerd, SPIRE, iptables, `ExternalWorkload`)
is pure Linux and ships both `arm64` and `amd64`, so the core is portable. The one
environment-specific concern — how you *produce* the Linux hosts — is isolated
into a swappable **provisioner** layer.

| Box | Must provide |
|---|---|
| **Box A — cluster** | A Linux node that can run k3s and route its pod+service CIDRs; reachable at `CLUSTER_NODE_ADDR` |
| **Box B — edge** | A Linux node that can run iptables redirection + a standalone `linkerd2-proxy`; reachable at `EDGE_ADDR` |

Design intent: the demo runs in **disposable VMs**, one per physical machine
(isolation + easy teardown), even on Linux — one uniform Linux bootstrap path.
It **must** be two physical machines; single-host is out of scope by design.

## Portability: compute provisioners & architecture

A **provisioner** produces one Linux VM per physical machine; the core bootstrap
is identical across all of them.

| Host OS | Provisioner | Status |
|---|---|---|
| macOS (Apple Silicon) | **Lima** (arm64 guest) | **Reference — tested** |
| macOS (Intel) | Lima (amd64 guest) | Portable by construction |
| Linux (arm64 / amd64) | Lima (QEMU backend) | Portable by construction |
| Windows | multipass or WSL2 | Documented |
| Cloud (any) | a Linux instance | Documented |

- **Lima is the default provider** (runs on macOS and Linux; committable YAML).
- **Architecture-aware bootstrap:** scripts detect `uname -m` and pull the
  matching `linkerd2-proxy` binary and container images (`arm64` vs `amd64`).
- **Config-driven:** `config.example.env` declares provider, hosts, addresses,
  VM sizing, and pod/service CIDRs; real values live in a gitignored
  `config.local.env`.

### Reference environment (what this was authored on)

Two Apple Silicon Macs that already reach each other (over the LAN), each hosting
a Lima VM. Boundary crossed: orion-m1 ↔ orion-m4 (two physical machines). Any
reachability would work equally.

| Role | Physical host | Linux VM | Runs |
|---|---|---|---|
| **Box A — cluster** | orion-m1 (M1, 16 GB) | `linkerd-cluster` (~8 GB) | k3s + Linkerd control plane + `linkerd viz` + SPIRE server |
| **Box B — edge** | orion-m4 (M4, 16 GB) | `linkerd-edge` (~4 GB) | SPIRE agent + standalone `linkerd2-proxy` + demo app |

### Why these choices

- **VM per host, not bare-metal.** Even on Linux, a disposable VM keeps the demo
  isolated and tear-down clean, and yields one uniform bootstrap path.
- **Lima, not Docker/k3d.** k3d nests pod IPs on a Docker bridge inside Docker's
  own Linux VM; reaching that CIDR across a boundary means several NAT layers. A
  real Linux VM host network stack makes routing the pod CIDR the documented case.
- **k3s, not kind/k3d.** Runs on the VM host directly, so pod CIDR
  (`10.42.0.0/16`) and service CIDR (`10.43.0.0/16`, both config-overridable) are
  host-visible and routable.

## Trust wiring

- **One SPIFFE trust domain.** Linkerd's trust anchor (`ca.crt`/`ca.key`) is the
  root.
- **SPIRE server** (in-cluster) runs with `UpstreamAuthority` = disk plugin
  loaded with the Linkerd trust anchor, so SPIRE-issued SVIDs chain to the same
  root as Linkerd's in-cluster ServiceAccount identities.
- **SPIRE agent** on the edge VM.
- **Attestation:**
  - Node (agent → server): **`join_token`** — infrastructure-neutral, no cloud
    metadata. The natural thing to swap for real infra attestation later in
    `stack-control`.
  - Workload (on edge): **`unix`** attestor — maps the `linkerd2-proxy`
    process's uid/path to its registration entry.
- **Binding:** a SPIRE registration entry → `spiffe://<trust-domain>/edge/echo`,
  plus an `ExternalWorkload` CRD in-cluster carrying that SPIFFE ID, `EDGE_ADDR`,
  and the workload's ports.

> The exact SPIFFE ID string scheme (trust-domain value + `ExternalWorkload`
> path convention) is to be pinned against the Linkerd/SPIRE docs during
> planning; strings here are illustrative examples.

## Demonstration arc

The app is a trivial HTTP echo service so all attention is on identity.

**Beat 1 — Cross-boundary mTLS with a SPIFFE identity.**
The edge workload calls an in-cluster echo service. `linkerd viz tap`/`edges`
shows the server proxy reporting the client identity as `spiffe://…/edge/echo`.
*Proves the shared trust domain reaches outside the cluster.*

**Beat 2 — Identity-based authz, independent of network (the money shot).**
An `AuthorizationPolicy` + `MeshTLSAuthentication` on the in-cluster service
permits **only** the edge's SPIFFE ID.
- Edge calls → **200**.
- Change the required identity → same edge calls now **403**, with no change to
  network/IP/firewall.
*Proves access is gated on cryptographic workload identity, not location — the
SPIFFE thesis, demonstrated.*

**Beat 3 (stretch) — Encrypt + authorize traffic *to* the edge.**
An in-cluster client calls a service hosted on the edge VM; traffic is
mTLS-encrypted to the off-cluster workload and the edge enforces authz on the
caller's in-cluster identity (Linkerd 2.15's "encrypt all traffic to VM
workloads"). Built only if Beats 1–2 land with time to spare.

## Repository structure (multi-demo)

The repo houses many demos; the top level is demo-neutral, and each demo is
self-contained under `demos/`.

```
README.md                 repo overview + index of demos (demo-neutral)
Justfile                  thin dispatcher: `just <demo> <target>`, `just demos`
lib/                      shared bash helpers (arch-detect, config-load, VM launch) — grows as needed
demos/
  spiffe-cross-boundary/  demo #1 — this design, fully self-contained
    README.md             walkthrough / blog-post backbone
    config.example.env    provider, hosts, CLUSTER_NODE_ADDR, EDGE_ADDR, VM sizing, pod/service CIDRs
                          (real values in a gitignored config.local.env)
    provisioners/
      lima/               cluster.yaml, edge.yaml         (default compute provider)
      multipass/          cloud-init equivalents          (documented alt)
    net/                  generic route + cluster-DNS shim (uses CLUSTER_NODE_ADDR + CIDRs)
    cluster/              k3s + linkerd + spire-server + app + authz + externalworkload
    edge/                 spire-agent config, proxy launch + iptables scripts, app
    scripts/              up / down / status / per-beat (idempotent, resumable, arch-aware)
    Justfile              demo targets (invoked by the top-level dispatcher)
docs/
  superpowers/specs/      design specs (this file — repo-level history)
```

- **Top level is not about SPIFFE.** `README.md` describes the repo as a
  collection of Linkerd mesh/identity demos and indexes them; the SPIFFE
  specifics live entirely under `demos/spiffe-cross-boundary/`.
- **No speculative framework.** `lib/` starts with only the trivially-shared
  helpers this demo needs; genuinely common tooling (e.g. VM provisioning) is
  promoted out of the demo when a second demo demonstrates the reuse (rule of
  three), not before.
- This layer is **bash + YAML**, not TypeScript: declarative infra + shell glue
  is the right tool. (Global TS/`@/` preferences apply to application code.)
- Scripts are idempotent and resumable, arch-detecting; no `#` inside heredocs
  (use files); no `sed` writes.

## Success criteria

1. `just spiffe-cross-boundary up` reads config, provisions two Linux VMs (one per
   physical machine) via the configured compute provider, applies the generic
   route/DNS shim over whatever reachability already exists, and brings cluster +
   Linkerd + SPIRE + edge workload online, idempotently. **No network
   infrastructure is selected or provisioned by the playground.**
2. Beat 1: `linkerd viz tap` shows the edge's `spiffe://…` client identity on a
   cross-boundary call.
3. Beat 2: flipping the authz identity alone flips 200 → 403.
4. Beat 3 (stretch): in-cluster → edge mTLS.
5. Reproducible, documented, tears down cleanly (`just spiffe-cross-boundary down`).
6. `docs/` walkthrough lets a stranger run it on their own two machines over
   *any* reachability, needing no specific network product.

## Non-goals & tested scope

HA, multi-node clusters, production hardening, cert-rotation deep-dive,
single-host collapse, cloud-instance attestation, and **provisioning or
prescribing the underlying network** are all out of scope. Single k3s node,
single edge workload, `join_token` attestation. The playground assumes IP
reachability between the two machines already exists and adds only the minimal
generic routing/DNS that Linkerd's data plane requires.

**Tested scope:** only the reference environment (Lima on Apple Silicon) is
verified on available hardware. Other compute providers and architectures are
kept correct-by-construction (config-driven, arch-aware) and documented, but are
not CI-verified — stated plainly rather than claimed as "works everywhere."

## Relationship to stack-control (second concern)

`stack-control`'s fleet control plane needs a multi-infrastructure shared trust
domain. This playground is a faithful small-scale rehearsal: the *same*
SPIFFE-issued identity and shared trust domain, demonstrated to be independent of
the network. Because the playground prescribes no network, the identical demo
runs over a LAN today and over whatever reachability the fleet actually has
(overlay, VPC, direct) tomorrow — with `join_token` attestation, config-driven
addresses, and portable VM defs ensuring nothing hard-depends on the reference
specifics.
