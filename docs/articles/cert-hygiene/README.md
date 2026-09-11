# Certificate Hygiene for Linkerd

Working research materials for the Linkerd certificate-hygiene article.

## Files

- [research.md](research.md) — a quick, source-prioritized link index for active research.
- [bibliography.md](bibliography.md) — the canonical source and claim map, including authority level, outline mapping, research notes, and claims that need evidence or clear editorial labeling.
- [demo-feasibility.md](demo-feasibility.md) — a safe, version-aware plan for turning article failure modes into disposable-cluster demonstrations.
- [linkerd-source-notes.md](linkerd-source-notes.md) — Linkerd certificate behavior read from source at `edge-26.9.1` (leaf lifetime and clamping, issuer and anchor expiry, webhook certs and `failurePolicy`, `linkerd check` coverage), with permalinks. These are hypotheses for the demos to confirm, not article evidence.
- [Demo lab design](../../superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md) — how the demos are built: shared `lib/` install pieces, a one-box OrbStack + k3s lab, probe workloads, evidence capture, and the first scenario (issuer expiry).

## Demo status

| Scenario | State |
| --- | --- |
| Lab design | Approved after [third-party review](../../superpowers/reviews/2026-09-10-cert-hygiene-demo-lab-design-review.md); [implementation plan](../../superpowers/plans/2026-09-10-cert-hygiene-demo-lab/README.md) written |
| Lab harness | In progress: shared lib/ refactor verified against SPIFFE (plan Task 3 of 10) |
| Baseline control (`00-baseline-control`) | Not started |
| #5 Issuer expiry | Not started |
| All other scenarios in [demo-feasibility.md](demo-feasibility.md) | Not started |

## Research conventions

- Treat current Linkerd documentation as the source of truth for Linkerd behavior and operational procedures.
- Use Kubernetes, IETF, NIST, and cert-manager material to support underlying mechanics and general operational guidance.
- Treat GitHub issues and discussions as historical examples, not as current runbooks or universal behavior.
- Before adding article copy, map factual claims to the bibliography and retain any necessary qualifications.
