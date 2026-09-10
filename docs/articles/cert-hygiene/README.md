# Certificate Hygiene for Linkerd

Working research materials for the Linkerd certificate-hygiene article.

## Files

- [research.md](research.md) — a quick, source-prioritized link index for active research.
- [bibliography.md](bibliography.md) — the canonical source and claim map, including authority level, outline mapping, research notes, and claims that need evidence or clear editorial labeling.
- [demo-feasibility.md](demo-feasibility.md) — a safe, version-aware plan for turning article failure modes into disposable-cluster demonstrations.
- [Demo lab design](../../superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md) — how the demos are built: shared `lib/` install pieces, a one-box OrbStack + k3s lab, probe workloads, evidence capture, and the first scenario (issuer expiry).

## Demo status

| Scenario | State |
| --- | --- |
| Lab design | Draft, in review |
| Baseline control (`00-baseline-control`) | Not started |
| #5 Issuer expiry | Not started |
| All other scenarios in [demo-feasibility.md](demo-feasibility.md) | Not started |

## Research conventions

- Treat current Linkerd documentation as the source of truth for Linkerd behavior and operational procedures.
- Use Kubernetes, IETF, NIST, and cert-manager material to support underlying mechanics and general operational guidance.
- Treat GitHub issues and discussions as historical examples, not as current runbooks or universal behavior.
- Before adding article copy, map factual claims to the bibliography and retain any necessary qualifications.
