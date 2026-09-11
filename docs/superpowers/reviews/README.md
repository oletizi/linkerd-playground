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

## 2026-09-10 — cert-hygiene demo lab design

- [`2026-09-10-cert-hygiene-demo-lab-design-review.md`](2026-09-10-cert-hygiene-demo-lab-design-review.md)
  — third-party review of the lab design at commit `5d4f92a`: H2 conflated credential
  expiry with traffic failure; the recovery step needed a trust-anchor invariant; the stream
  probe had to fail closed; the "restarted workload" experiment was ambiguous; plus
  evidence-hardening items.

**What it produced:** the revised design
`docs/superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md`, whose § 9 records
each item's disposition (accepted, extended, or accepted with a different method).

## 2026-09-11 — cert-hygiene lab, slice 2 design

- [`2026-09-11-cert-hygiene-lab-slice-2-design-review.md`](2026-09-11-cert-hygiene-lab-slice-2-design-review.md)
  — third-party review of the slice 2 design at commit `31b920f`: separate the
  webhook-credential models and make W's recovery a deliberate experiment; make S-hard
  actually create the mixed-anchor state; test K at the 60-day boundary; generalise the
  anchor invariant into planned credential transitions; plus evidence-design refinements.

**What it produced:** the revised design
`docs/superpowers/specs/2026-09-11-cert-hygiene-lab-slice-2-design.md`, whose § 12
records each item's disposition.

- [`2026-09-11-cert-hygiene-lab-combined-implementation-review.md`](2026-09-11-cert-hygiene-lab-combined-implementation-review.md)
  — implementation-facing review of the slice 2 design and the first issuer run: isolate
  webhook expiries, treat supplied-credential recovery as a branching observation, gate
  restart stages, make S-hard and A's recovery test what they claim, plus acceptance
  conditions and publishing guardrails. Its companion as-built evidence review is
  `docs/articles/cert-hygiene/LAB-EVIDENCE-REVIEW-2026-09-11.md`.

**What they produced:** the slice 2 design's § 12.2 (dispositions), § 13 (acceptance
conditions) and § 14 (guardrails), and narrowed claims in
`docs/articles/cert-hygiene/findings.md`.
