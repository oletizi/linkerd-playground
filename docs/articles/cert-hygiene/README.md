# Certificate hygiene for Linkerd — article materials

Research and lab results for an article on recognising, fixing and preventing certificate-expiry problems in Linkerd.

## Start here

1. **[findings.md](findings.md)** — what we learned, in plain words, organised to match the article outline. Its [triage table](findings.md#triage-table) comes in two parts: what we reproduced in a test cluster, and what Linkerd's code predicts but we haven't tested yet. Each row links to its details. Every statement on the page says which kind it is.
2. **[sources.md](sources.md)** — what to cite for each claim, how authoritative each source is, and which claims in the draft need careful wording.
3. **[notes/](notes/)** — the detail behind the findings. You only need these to check a specific claim:
   - [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) — the full record of the issuer-expiry experiment, quoting raw logs and metrics.
   - [notes/lab-evidence-issuer-expiry-rerun.md](notes/lab-evidence-issuer-expiry-rerun.md) — two repeats of the issuer-expiry experiment with fuller recording, and which open questions they answer.
   - [notes/lab-evidence-webhook-expiry.md](notes/lab-evidence-webhook-expiry.md) — webhook certificates expiring one at a time, under each failure policy, and how recovery went.
   - [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md) — what Linkerd's source code says about certificate behaviour, with links to the exact lines.
   - [notes/research-links.md](notes/research-links.md) — reading list and a catalogue of real-world incident reports.
   - [notes/demo-feasibility.md](notes/demo-feasibility.md) — which failure modes can be reproduced safely in a test cluster, and how.
   - [notes/lab-evidence-review-2026-09-11.md](notes/lab-evidence-review-2026-09-11.md) — an independent review of what the lab evidence does and doesn't yet support, and which claims to narrow before publishing.
   - [notes/lab-evidence-reading-guide.md](notes/lab-evidence-reading-guide.md) — how to read the lab's raw recordings when checking a claim.

## Status

- **Identity issuer expiry:** tested. Results are in [findings.md](findings.md). Its repeat, with fuller logging, is part of the second round of lab experiments below; its open questions are answered once that write-up lands.
- **Trust-anchor expiry and rotation, webhook certificates, an identity-service outage, and the `linkerd check` threshold** are part of the second round of lab experiments below; their results are not findings until each is written up. **Viz/tap and the other scenarios** in [notes/demo-feasibility.md](notes/demo-feasibility.md) remain untested; their findings still come from Linkerd's source code only.
- **Second round of lab experiments** (webhook certificates, identity outage, `linkerd check` threshold, trust-anchor expiry and rotation, and a repeat of the issuer experiment): every experiment has been run. Written up so far: the repeat of the issuer experiment and the webhook experiment. The other write-ups are in progress; until each is done, its results are not findings.

## The test lab

The experiments run in [`demos/cert-hygiene/`](../../../demos/cert-hygiene/): a throwaway single-machine Kubernetes cluster with Linkerd. It makes certificates expire on purpose and records everything that happens. Raw recordings of each run are kept under `demos/cert-hygiene/runs/`.

How the lab works is in its [design](../../superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md). How it was built is in its [implementation plan](../../superpowers/plans/2026-09-10-cert-hygiene-demo-lab/README.md). Both use internal shorthand that the pages above avoid.

## Research conventions

- Treat current Linkerd documentation as the source of truth for Linkerd behavior and operational procedures.
- Use Kubernetes, IETF, NIST, and cert-manager material to support underlying mechanics and general operational guidance.
- Treat GitHub issues and discussions as historical examples, not as current runbooks or universal behavior.
- Before adding article copy, map factual claims to [sources.md](sources.md) and keep any qualifications it records.
