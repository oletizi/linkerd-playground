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
