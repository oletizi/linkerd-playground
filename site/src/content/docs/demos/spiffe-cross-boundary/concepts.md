---
title: Concepts
description: How SPIFFE gives a workload a portable identity, and why authorization by identity beats authorization by network.
---

If you've run anything on Kubernetes with a service mesh, you've seen workload
identity already: Linkerd gives every pod a cryptographic identity derived from its
ServiceAccount, and services authenticate with mutual TLS instead of trusting
whatever happens to be at a given IP. It's a better model — a pod proves *who it is*,
not just *where it sits*. But that identity comes from Kubernetes, so it only covers
things Kubernetes runs. The moment part of your system lives elsewhere — a VM, a
legacy service, an on-prem box — those workloads fall outside the scheme, and you're
back to firewalls and IP rules.

## SPIFFE: identity, not location

SPIFFE gives *any* workload — pod or not — a cryptographic identity (a short-lived
certificate called an **SVID**) inside a shared **trust domain**. The store's service
isn't "whatever is at 192.0.2.7"; it *is*:

```
spiffe://root.linkerd.cluster.local/store-pos
```

That identity is the same regardless of what network the workload sits on.

## Mesh expansion: the workload joins the mesh

`store-pos` runs on a plain machine, not in Kubernetes. Linkerd's **mesh expansion**
brings it in: a standalone `linkerd2-proxy` runs beside it, and **SPIRE** (the SPIFFE
reference implementation) issues its SVID — chained to the same trust anchor Linkerd
uses inside the cluster. One trust domain now spans both machines, with no federation
and no requirement that everything share a network.

## mTLS: encrypted and mutually authenticated

When the store reports to the cloud, both sides present their SVIDs and establish
mutual TLS. The cloud knows exactly who is reporting — by identity — and the traffic
is encrypted the whole way across the boundary.

## Authorization by identity

Access becomes a policy about *identity*: the cloud's ingest endpoint allows only the
store's identity to report. Change the allowed identity, and the store's pushes are
refused with a real HTTP **403** — with nothing about the network changing. Once
identity is portable and cryptographic, authorization stops being about networks and
starts being about workloads.

Ready to build it? The **[manual](/demos/spiffe-cross-boundary/manual/)** walks
through every piece from scratch.
