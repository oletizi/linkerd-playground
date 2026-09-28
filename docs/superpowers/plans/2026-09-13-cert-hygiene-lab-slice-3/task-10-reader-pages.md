# Task 10: Reader pages

Part of the [slice 3 plan](README.md). Read its Global Constraints first, then the two notes this task depends on: `notes/lab-evidence-tap-expiry.md` (Task 8) and `notes/lab-evidence-check-threshold.md` (Task 9).

**Goal:** the reader-facing pages state what slice 3 measured, and nothing more. Every claim traces to a note, and every note traces to a recorded run.

**Files:**
- Modify: `docs/articles/cert-hygiene/findings.md`, `docs/articles/cert-hygiene/README.md`
- Read (do not edit): the two notes, and `sources.md` if a citation needs checking

**What is stale today.** Grep `findings.md` for `tap` before you start; these are the places that say the tap scenario is untested, and each needs its own treatment:

- Item 10 in the numbered list: "Our inference: … We have not run this experiment."
- The triage table's tap row: "What an expired one does is our inference."
- The `### Tap and other viz features stopped working` section: "Our inference:" and "What would confirm it: install viz in the lab and expire the tap API certificate."
- The "what nothing checks" bullet and the "Still open" list item "The viz/tap scenario, which we have not run at all."

Plus, wherever the 60-day boundary is described, the bracket the threshold note used to give.

**Steps:**

1. **The tap row.** Move it from inference to observed, and be precise about which part. The run showed the three clauses of V1 behaving differently, and one of them — tap continuing to stream events after expiry until the API server reconnected — is the opposite of what the page currently infers. A row that says "reproduced" without that distinction is worse than the inference it replaces. The claim the reader takes away should be the one the run supports: what `linkerd viz check` says, what the APIService says, and when tap actually stops.
2. **The masking effect, which is new and operational.** Because the tap row is fatal, `linkerd viz check` truncates the whole `linkerd-viz` section at it: every later row — `tap API service is running`, the extension's pods and proxies, prometheus, the self-check — disappears from the output. So one expired tap certificate does not merely report itself; it blanks everything a person debugging viz would look at next. The note has the detail. This belongs on the reader pages in its own right, near whatever the pages already say about `linkerd check` stopping at the first failure.

3. **The connection-reuse pattern.** Tap is now the second component where an expired serving certificate kept working over an established connection — the webhook section already says this for admission webhooks. The two belong together as one observation about how these failures surface, not two unrelated rows. Decide where that belongs on the page and put it there once, cross-linked, rather than repeating the explanation in both places.
4. **The 60-day boundary.** State it as the two measured numbers from the threshold note, with the same caveat the note carries about mechanism. Do not round to a friendly figure, and do not write "60 days" unqualified anywhere the page is making a claim about when the warning fires.
5. **The "Still open" list.** Remove the viz/tap item. Add what slice 3 did not settle — whatever the two notes name as unknown, including why the check demands more margin than 60 days.
6. **Keep `README.md` current** in the same commit: the "Start here" list should reach the new note, and the status bullet should describe what is written up.
7. Read the finished pages end to end before committing, checking that nothing elsewhere still says the tap scenario is untested or the boundary unknown.
8. Commit (`cert-hygiene move the tap row to observed and state the check boundary`) and push.
