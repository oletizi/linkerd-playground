---
title: Overview
description: SPIFFE identity for a workload outside Kubernetes, brought into a Linkerd mesh across a real two-machine boundary.
---

**A store's point-of-sale system, running on a *different machine* outside
Kubernetes, pushes live inventory and sales up to a cloud app — and the cloud
accepts the data based on cryptographic SPIFFE identity, not on IP or network.**

This demo makes SPIFFE-in-Linkerd tangible. A point-of-sale service (`store-pos`)
runs on a machine that Kubernetes has never heard of. Linkerd's **mesh expansion**
brings it into the mesh with a SPIRE-issued identity
(`spiffe://root.linkerd.cluster.local/store-pos`) that chains to the cluster's trust
anchor. The store pushes its data to the in-cluster app (`retail-cloud`) over mTLS —
the realistic direction, since the cloud can't depend on an in-store box being
reachable.

Access is a policy about **identity**: the cloud's ingest endpoint admits only the
store's SPIFFE identity. Revoke that identity and the store's next push is refused
with a real HTTP 403 — with nothing about the network, the routes, or the addresses
changing. That is the whole point: authorization follows *who a workload is*, not
*where it runs*.

## Where to go next

- **[Concepts](/demos/spiffe-cross-boundary/concepts/)** — the SPIFFE story, from the
  problem to identity-based authorization.
- **[The manual](/demos/spiffe-cross-boundary/manual/)** — a from-scratch, no-scripts
  walkthrough of every config file, field, and command.
- **[Reference](/demos/spiffe-cross-boundary/reference/)** — the key configuration
  artifacts at a glance.

The runnable code lives in the
[repository](https://github.com/oletizi/linkerd-playground/tree/main/demos/spiffe-cross-boundary).
