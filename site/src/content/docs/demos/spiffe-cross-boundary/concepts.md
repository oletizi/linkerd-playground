---
title: Concepts
description: How SPIFFE gives a workload a portable identity, and how authorization by identity differs from authorization by network.
---

:::note
This is a teaching demo. The setup is simplified for clarity, not hardened for
production — see [Production notes](/demos/spiffe-cross-boundary/production-notes/) for
the shortcuts it takes and what to do instead.
:::

On Kubernetes with a service mesh, workload identity is already familiar: Linkerd
gives every pod a cryptographic identity derived from its ServiceAccount, and
services authenticate with mutual TLS rather than trusting whatever responds at a
given IP address. A pod is identified by its identity, not by its location. That
identity comes from Kubernetes, however, so it only covers workloads Kubernetes
runs. When part of a system runs elsewhere — a VM, a legacy service, an on-premises
host — those workloads fall outside the scheme, and access control falls back to
firewalls and IP rules.

## Identity instead of location

SPIFFE gives any workload, whether or not it is a pod, a cryptographic identity: a
short-lived certificate called an **SVID**, issued within a shared **trust domain**.
The store's service is identified by a SPIFFE ID rather than by an address:

```
spiffe://root.linkerd.cluster.local/store-pos
```

That identity does not change with the network the workload runs on.

## Mesh expansion

`store-pos` runs on a standalone machine, not in Kubernetes. Linkerd's **mesh
expansion** adds it to the mesh: a standalone `linkerd2-proxy` runs alongside it, and
**SPIRE** (the SPIFFE reference implementation) issues its SVID, chained to the same
trust anchor Linkerd uses inside the cluster. One trust domain then spans both
machines, without federation and without requiring them to share a network.

## Attestation

Before SPIRE issues an SVID it has to answer one question: *which* identity does the
process asking for one deserve? It answers by **attestation** — verifying facts about the
caller that the operating system vouches for, instead of trusting anything the process
claims about itself.

When the store's proxy asks the local SPIRE agent for its identity, it presents no name or
password. Because the request arrives over a Unix socket, the kernel tells the agent the
caller's user ID, and the agent reads the process's executable path from the OS. Those
become **selectors** — here, *runs as uid 2102* and *is the `linkerd2-proxy` binary at this
path*. The agent matches them against a **registration** an operator made ahead of time —
"a process with these properties may receive this SPIFFE ID" — and issues the matching
SVID.

The process cannot lie its way into an identity: its user ID and its binary come from the
kernel, not from its own say-so. This is the off-cluster counterpart to Kubernetes
identity — in the cluster a pod's identity is tied to its ServiceAccount, verified by the
Kubernetes API; off-cluster, SPIRE ties identity to OS-level properties, verified by the
kernel. (SPIRE attests at two levels: the **agent** first proves which node it is to the
server, then each **workload** is attested locally as described here.)

The [manual](/demos/spiffe-cross-boundary/manual/) shows the exact selectors and
registration in Part 3.

## Trust domains: one or many?

A trust domain is the unit of *ambient* trust: every workload whose SVID chains to the
same root implicitly trusts every other as a potential peer. A trust domain's boundary
is therefore the boundary of "who can even authenticate as one of us" — and choosing
where that boundary falls is a real design decision.

This demo uses **one** trust domain on purpose. `store-pos` and `retail-cloud` are one
application spanning on-premises and the cluster; sharing a domain gives them a seamless
identity fabric, and access is decided per *identity* (admit this exact SPIFFE ID), not
per domain.

You would use **several** trust domains — inside a single organization — when you want a
hard boundary between groups of workloads:

- **Isolation / blast radius.** Separate roots mean a compromise or mis-issuance in one
  domain cannot mint identities another domain will trust. The classic split is
  **production vs staging** — staging should never be able to authenticate as production.
- **Independent administration.** Different business units, subsidiaries, or platform
  teams each run their own SPIRE/PKI, with their own CA rotation, TTLs, and attestation
  policy.
- **Regulatory scope.** A domain under a specific compliance regime (say PCI) kept
  distinct from everything else.

You then connect only the domains that must interoperate with **SPIFFE federation**: the
domains exchange trust bundles, so a workload in one can validate SVIDs from another —
*explicitly and selectively*, rather than the ambient trust you get inside a single
domain.

| | One trust domain | Several domains, federated |
|---|---|---|
| **Use when** | the workloads are one trust realm you run as a unit (this demo) | you want a hard boundary — environments, teams, compliance scopes |
| **Trust between workloads** | ambient — same root; authorize per identity | explicit — only federated domains interoperate |
| **Blast radius** | domain-wide: one root anchors everything | contained: a compromise can't cross the boundary |
| **Cost** | simplest; nothing to federate | federation setup + cross-domain authorization to author |

This demo takes the single-domain path because that is its thesis — identity that spans
infrastructure without federation. A production fleet might instead give each environment
its own domain and federate the pairs that must talk; the
[Production notes](/demos/spiffe-cross-boundary/production-notes/) frame the single domain
as the deliberate choice it is.

## Mutual TLS

When the store connects to the cloud, both sides present their SVIDs and establish
mutual TLS. Each side authenticates the other by identity, and the traffic is
encrypted across the boundary.

## Authorization by identity

Access control is expressed as a policy over identity: the cloud's ingest endpoint
admits only the store's identity. If the allowed identity is changed, requests from
the store are rejected with HTTP **403**, with no change to the network. Because the
identity is cryptographic and portable, authorization is defined in terms of the
workload rather than the network it runs on.

The **[manual](/demos/spiffe-cross-boundary/manual/)** covers each of these pieces in
full.
