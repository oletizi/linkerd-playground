# Certificate hygiene for Linkerd — article materials

Research and lab results for an article on recognising, fixing and preventing certificate-expiry problems in Linkerd.

## Start here

1. **[findings.md](findings.md)** — what we learned, in plain words, organised to match the article outline. Every row of its [triage table](findings.md#triage-table) has now been reproduced in the lab, and each links to its details. Every statement on the page says whether we saw it, read it in Linkerd's code, or still don't know.
2. **[sources.md](sources.md)** — what to cite for each claim, how authoritative each source is, and which claims in the draft need careful wording.
3. **[notes/](notes/)** — the detail behind the findings. You only need these to check a specific claim:
   - [notes/lab-evidence-issuer-expiry.md](notes/lab-evidence-issuer-expiry.md) — the full record of the issuer-expiry experiment, quoting raw logs and metrics.
   - [notes/lab-evidence-issuer-expiry-rerun.md](notes/lab-evidence-issuer-expiry-rerun.md) — two repeats of the issuer-expiry experiment with fuller recording, and which open questions they answer.
   - [notes/lab-evidence-webhook-expiry.md](notes/lab-evidence-webhook-expiry.md) — webhook certificates expiring one at a time, under each failure policy, and how recovery went.
   - [notes/lab-evidence-identity-outage.md](notes/lab-evidence-identity-outage.md) — what happened while the identity service was down, and after it came back.
   - [notes/lab-evidence-check-threshold.md](notes/lab-evidence-check-threshold.md) — where `linkerd check`'s 60-day issuer warning actually starts: a bisect that narrows it from a day-wide guess to a 305-second bracket about an hour past 60 days.
   - [notes/lab-evidence-anchor-expiry.md](notes/lab-evidence-anchor-expiry.md) — a trust anchor expiring, how failures spread, and what recovery took.
   - [notes/lab-evidence-anchor-rotation.md](notes/lab-evidence-anchor-rotation.md) — rotating a trust anchor by Linkerd's staged procedure, and replacing it in one step.
   - [notes/lab-evidence-tap-expiry.md](notes/lab-evidence-tap-expiry.md) — the tap API server's certificate expiring: what kept working, for how long, and what finally broke it.
   - [notes/linkerd-source-notes.md](notes/linkerd-source-notes.md) — what Linkerd's source code says about certificate behaviour, with links to the exact lines.
   - [notes/research-links.md](notes/research-links.md) — reading list and a catalogue of real-world incident reports.
   - [notes/demo-feasibility.md](notes/demo-feasibility.md) — which failure modes can be reproduced safely in a test cluster, and how.
   - [notes/lab-evidence-review-2026-09-11.md](notes/lab-evidence-review-2026-09-11.md) — an independent review of what the lab evidence does and doesn't yet support, and which claims to narrow before publishing.
   - [notes/lab-evidence-reading-guide.md](notes/lab-evidence-reading-guide.md) — how to read the lab's raw recordings when checking a claim.

## Status

Every experiment below has been run, written up, and carried into [findings.md](findings.md). Its triage table no longer has an untested half.

- **Identity issuer expiry:** run three times (once, then twice more with fuller recording). Reproduced. The repeats also settled how the handshake fails, which restarts recovery needs, and how long an already-open connection lasted.
- **Webhook serving certificates:** run twice, once per failure policy. Reproduced — with the important qualification that two of the three webhooks kept working past their own expiry, about 30 minutes for the proxy injector and about 10 minutes for the ServiceProfile validator, until the API server had to reconnect.
- **Identity-service outage:** run once. Reproduced, including the answer to whether a proxy re-certifies on its own afterwards (it did not). One thing that run saw but cannot explain is recorded as an open question.
- **Trust-anchor expiry:** run once. Reproduced, except that failures did not stagger across proxies as expected; whether recovery needs the identity service restarted separately is unresolved.
- **Trust-anchor rotation:** run twice, staged and one-step. Reproduced; the guidance in the findings is rewritten from it.
- **The `linkerd check` 60-day warning:** run ten times — twice in the second round, then eight more as a bisect; nine of the ten are valid evidence, the tenth having been recorded against a dirty tree. Reproduced in both directions, and the boundary is now measured rather than bracketed by a day: it is not at 60 days. The check still printed that `‼` warning with 58 m 58 s *more* than 60 days of validity remaining, and cleared to `√` only once an issuer had 1 h 4 m 3 s more — so the row is still warning almost an hour's worth of validity past the 60-day mark, and therefore at exactly 60 days too; the warning starts roughly an hour before that mark is reached, not when it arrives. [findings.md](findings.md) now quotes that 305-second bracket rather than a single figure, and records why the check wants the extra margin as still open.
- **Viz/tap API certificate expiry:** run once. Reproduced, with the same qualification the webhook experiment found: `linkerd viz check` went fatal at the first observation after expiry, but the tap APIService stayed available and `linkerd viz tap` kept returning live events for about half an hour afterwards, until a restart of the tap pod forced the API server to open a new connection. Its triage row is now in [findings.md](findings.md)'s reproduced table, carrying that distinction, together with the masking effect the fatal row has on the rest of `linkerd viz check`. The remaining scenarios in [notes/demo-feasibility.md](notes/demo-feasibility.md) still rest on Linkerd's source code only.

## The test lab

The experiments run in [`demos/cert-hygiene/`](../../../demos/cert-hygiene/): a throwaway single-machine Kubernetes cluster with Linkerd. It makes certificates expire on purpose and records everything that happens. Raw recordings of each run are kept outside this repository, so that cloning it stays cheap for anyone who just wants to run the demos. What stays here is a manifest per run listing every file with its checksum; `tools/evidence.sh` prints any single recorded file, or downloads a whole run and verifies it against that manifest.

How the lab works is in its [first design](../../superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md) and [first implementation plan](../../superpowers/plans/2026-09-10-cert-hygiene-demo-lab/README.md). The second round of experiments — every scenario, credential profile, restart stage and validity rule behind the evidence on these pages — is specified in its [second design](../../superpowers/specs/2026-09-11-cert-hygiene-lab-slice-2-design.md) and [second implementation plan](../../superpowers/plans/2026-09-11-cert-hygiene-lab-slice-2/README.md). All four use internal shorthand that the pages above avoid.

## Research conventions

- Treat current Linkerd documentation as the source of truth for Linkerd behavior and operational procedures.
- Use Kubernetes, IETF, NIST, and cert-manager material to support underlying mechanics and general operational guidance.
- Treat GitHub issues and discussions as historical examples, not as current runbooks or universal behavior.
- Before adding article copy, map factual claims to [sources.md](sources.md) and keep any qualifications it records.
