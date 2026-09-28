# Task 9: Reader pages

Part of the [slice 4 plan](README.md). Read its Global Constraints first, then the note Task 8 wrote.

**Goal:** the triage table stops being a list of expiry symptoms and starts doing the job it is named for.

**Files:**
- Modify: `docs/articles/cert-hygiene/findings.md`, `docs/articles/cert-hygiene/sources.md`, `docs/articles/cert-hygiene/README.md`

**What is wrong with the pages today**, and what this task fixes: every row of the triage table was produced by a certificate expiring. A reader arriving with a symptom is given a cause, but the pages have never shown them a case where the same symptom had a *different* cause. This slice produced exactly those cases, and the pages should now be able to tell a reader how to tell them apart — or admit where they cannot.

**Steps:**

1. **The triage table gains a discriminating column or its equivalent.** For each row, the reader needs to know what would distinguish this cause from the others that produce the same symptom. Where the lab established that (a certificate that is valid and still refused, an API error with no time-validity language in it, a check row that passes while the platform refuses), say it with the artifact behind it. Decide the shape — a column, a per-row clause, a short section the rows point at — and keep it readable at the width the page already uses.

2. **Where two causes are indistinguishable from a signal, say so in the table, not only in the note.** If an unavailable injector and an expired injector both yield a pod without a proxy, a reader looking at a pod without a proxy must be told that the symptom alone does not settle it. Burying that in a linked note is how a triage table misleads.

3. **The `linkerd check` material.** The pages already say the check can be green while traffic is broken, and that its exit code does not see the issuer warning. If G confirmed that the check also calls a refused certificate valid, that belongs beside them as the same lesson a third time, not as a new isolated bullet. If G was not run, nothing here changes.

4. **Scope and counts.** N ran twice, G once. Every count on these pages excludes non-evidence runs — that rule has already been broken twice on this branch and caught both times. State what was run as valid evidence and nothing more.

5. **`sources.md` gets an entry per experiment**, as it does for every other, including a claims-NOT-supported field. For these two the over-readings to forbid are predictable and should be named explicitly: that an unavailable webhook is a certificate problem, and that a refused certificate is an expired one.

6. **"Still open" gains what this slice could not settle** — at minimum, the other causes in the feasibility matrix that remain untested (chain mismatch for the webhook and for the issuer), and, if G was not run, that the platform's algorithm behaviour on this cluster is unestablished.

7. Read the finished pages end to end before committing, checking that nothing still implies every certificate failure is an expiry.

8. Commit (`cert-hygiene teach the triage table to tell causes apart`) and push.
