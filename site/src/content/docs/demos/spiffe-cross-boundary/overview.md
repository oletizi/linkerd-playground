---
title: Overview
description: SPIFFE identity for a workload outside Kubernetes, joined to a Linkerd mesh across a machine boundary.
---

:::caution[This is a teaching demo]
It is built for explanatory clarity, not as a model of best practice. It takes
deliberate shortcuts — starting with copying the trust domain's root key onto the store
host — that are unsafe in production. See
[Production notes](/demos/spiffe-cross-boundary/production-notes/) for every shortcut and
what to do instead.
:::

:::note[Made with Claude Code]
This demo and its documentation were built with [Claude Code](https://claude.com/claude-code), Anthropic's agentic coding tool.
:::

This demo runs a workload outside Kubernetes and gives it a SPIFFE identity that an
in-cluster service trusts. A point-of-sale service (`store-pos`) runs on a separate
machine that is not part of the cluster. Linkerd's mesh expansion adds it to the mesh
with a SPIRE-issued identity (`spiffe://root.linkerd.cluster.local/store-pos`) that
chains to the cluster's trust anchor. `store-pos` sends inventory and sales data to
the in-cluster `retail-cloud` service over mTLS. The store initiates the connection,
because the cluster cannot assume that a machine inside the store is reachable.

Authorization is expressed in terms of identity rather than network location. The
`retail-cloud` ingest endpoint admits only the store's SPIFFE identity. If that
identity is removed from the policy, the next request is rejected with HTTP 403; no
addresses, routes, or firewall rules change. A workload is authorized by its
identity, which remains the same across machines and networks.

## Where to go next

- **[Concepts](/demos/spiffe-cross-boundary/concepts/)** — how SPIFFE identity and
  Linkerd mesh expansion work, and how authorization by identity differs from
  authorization by network.
- **[The manual](/demos/spiffe-cross-boundary/manual/)** — a step-by-step walkthrough
  of every configuration file, field, and command, without setup scripts.
- **[Reference](/demos/spiffe-cross-boundary/reference/)** — the key configuration
  artifacts in one place.

The runnable code lives in the
[repository](https://github.com/oletizi/linkerd-playground/tree/main/demos/spiffe-cross-boundary).
