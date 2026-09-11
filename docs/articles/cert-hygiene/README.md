# Certificate hygiene for Linkerd — article materials

Research and lab results for an article on recognising, fixing and preventing certificate-expiry problems in Linkerd.

## Start here

1. **[findings.md](findings.md)** — what we learned, in plain words, organised to match the article outline. Its [triage table](findings.md#triage-table) comes in two parts: what we reproduced in a test cluster, and what Linkerd's code predicts but we haven't tested yet. Each row links to its details. Every statement on the page says which kind it is.
2. **[sources.md](sources.md)** — what to cite for each claim, how authoritative each source is, and which claims in the draft need careful wording.
3. **[notes/](notes/)** — the detail behind the findings. You only need these to check a specific claim:
   - [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) — the full record of the issuer-expiry experiment, quoting raw logs and metrics.
   - [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md) — what Linkerd's source code says about certificate behaviour, with links to the exact lines.
   - [notes/research-links.md](notes/research-links.md) — reading list and a catalogue of real-world incident reports.
   - [notes/demo-feasibility.md](notes/demo-feasibility.md) — which failure modes can be reproduced safely in a test cluster, and how.

## Status

- **Identity issuer expiry:** tested. Results are in [findings.md](findings.md). A repeat with fuller logging is pending; it should answer the questions listed under "Still open" there.
- **Trust-anchor expiry, webhook certificates, viz/tap, and the other scenarios** in [notes/demo-feasibility.md](notes/demo-feasibility.md): not tested yet. Their findings come from Linkerd's source code only.

## The test lab

The experiments run in [`demos/cert-hygiene/`](../../../demos/cert-hygiene/): a throwaway single-machine Kubernetes cluster with Linkerd. It makes certificates expire on purpose and records everything that happens. Raw recordings of each run are kept under `demos/cert-hygiene/runs/`.

How the lab works is in its [design](../../superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md). How it was built is in its [implementation plan](../../superpowers/plans/2026-09-10-cert-hygiene-demo-lab/README.md). Both use internal shorthand that the pages above avoid.

## Research conventions

- Treat current Linkerd documentation as the source of truth for Linkerd behavior and operational procedures.
- Use Kubernetes, IETF, NIST, and cert-manager material to support underlying mechanics and general operational guidance.
- Treat GitHub issues and discussions as historical examples, not as current runbooks or universal behavior.
- Before adding article copy, map factual claims to [sources.md](sources.md) and keep any qualifications it records.
