# Reviews

Durable copies of the sub-agent reviews that drove design changes.

## 2026-08-08 — spiffe-cross-boundary demo

Two independent sub-agent passes over `demos/spiffe-cross-boundary/`:

- [`2026-08-08-spiffe-cross-boundary-security-review.md`](2026-08-08-spiffe-cross-boundary-security-review.md)
  — exploitable security holes, ranked (root CA key on the edge; unauthenticated policy
  mutation; the web pod's SA token; `unix:uid:0` attestation; etc.).
- [`2026-08-08-spiffe-cross-boundary-bestpractice-review.md`](2026-08-08-spiffe-cross-boundary-bestpractice-review.md)
  — production best-practice deviations, grouped (trust & CA, SPIRE topology, attestation,
  lifecycle, networking, app/runtime, operations).

**What they produced:**

- The honest disclaimer `demos/spiffe-cross-boundary/PRODUCTION-NOTES.md` (distills these
  findings + the production practice for each).
- The trust-architecture change — design record
  `docs/superpowers/specs/2026-08-08-spire-trust-architecture-design.md`, plan
  `docs/superpowers/plans/2026-08-08-spire-trust-architecture.md` — which resolved the
  root-key, workload-attestation, and bootstrap findings (SPIRE server in the cluster,
  agent-only edge, non-root proxy attested by uid+path, pinned bootstrap).

These are the raw review outputs as written; they reflect the demo at review time.
