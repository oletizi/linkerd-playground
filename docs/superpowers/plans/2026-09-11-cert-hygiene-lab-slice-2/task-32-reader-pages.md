# Task 32: Reader-facing pages

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then design § 11, § 13 and § 14.

**Goal:** Carry the six evidence notes into the reader-facing pages: `docs/articles/cert-hygiene/findings.md`, `sources.md` and `README.md`. A triage row moves from "expected from Linkerd's code, not yet tested" to "reproduced in the lab", or is corrected, **only** when its scenario's write-up says its design § 13 condition is met and links exact run artifacts to the claim. Add the side-by-side comparison of issuer expiry, identity outage and anchor expiry (design § 11). Rewrite the rotation guidance in "Best practices" from the rotation evidence.

**Style rule for these three pages:** no hypothesis IDs (R1, W2, S1-obs, …), no run paths (`runs/<scenario>/<stamp>`), and no lab shorthand (scenario letters, T_mark, "tick", "gate", "stage1-norestart", profile names, "slice"). Link to the evidence notes instead, which hold the paths. Write plainly, as the pages do now.

**Guardrails (design § 14), applied to every sentence changed:**
- A scenario's failure is not evidence for its prediction unless the run was valid; invalid runs are mentioned only as failed attempts, if at all.
- A passing `linkerd check` after an issuer replacement doesn't prove that pre-existing workload certificates were renewed.
- Findings are phrased "in our lab" (or "in our testing"), naming Linkerd `edge-26.9.1` and the shortened lifetimes, unless primary documentation independently establishes them.
- Source-derived statements keep their label ("From Linkerd's code, not yet tested", "our inference").
- Webhook recovery results carry their caveat: the lab supplied its own static webhook certificates, which is not how Linkerd normally runs.

**Files:**
- Modify: `docs/articles/cert-hygiene/findings.md`, `docs/articles/cert-hygiene/sources.md`, `docs/articles/cert-hygiene/README.md`

**Interfaces:**
- Consumes: the notes from Tasks 26–31, and their "What this means for the article" and "For the comparison" sections.
- Produces: the updated reader pages.

- [ ] **Step 1: Build the claim ledger (working notes, not committed)**

Read the six notes' acceptance tables and "What this means for the article" sections. In a scratch file (outside the repo), list one line per reader-facing claim: the claim in plain words; the note and section that supports it; whether that scenario's § 13 condition is met (yes/no); and whether it confirms, corrects or leaves open the current wording in `findings.md`. Only lines with "met: yes" may move a row or add a "seen in the lab" statement.

- [ ] **Step 2: The triage tables in `findings.md`**

For each row of "Expected from Linkerd's code, not yet tested":
- **Pods without a proxy** and **validation skipped:** from the webhook note. If its condition is met, move each row to "Reproduced in the lab", with "What you're seeing" rewritten from the observed behaviour under each failure policy. If the lab contradicted the code-based wording, correct it and say so in the details section.
- **Identity outage:** from the identity-outage note, likewise.
- **Trust anchor expired:** from the anchor-expiry note, likewise. The "when failures appear" wording must follow the per-proxy timing observed.
- **Viz tap:** stays in the untested table (not run; the README records it as a follow-up).

Update the existing reproduced rows only where the issuer re-run changes them. For example, the "Proxy still expired" row can now say which restarts were needed, from the re-run's restart-matrix section. Every row keeps its link to a details section.

- [ ] **Step 3: The details sections**

Move each promoted row's details section from "Details: expected from Linkerd's code, not yet tested" to "Details: reproduced in the lab", keeping its heading text (the tables link to its anchor) or updating both the heading and every link to it. Rewrite each as "seen in the lab" bullets:
- the observed behaviour, with the version and lifetimes;
- the source-derived explanation, still labelled;
- a "Suggested wording" line where the page already uses that pattern;
- a link to the evidence note.

Sections that stay untested keep their labels.

- [ ] **Step 4: Add the side-by-side comparison**

Add a section after "Details: reproduced in the lab", titled "Three failures that look alike: issuer expired, identity service down, trust anchor expired". Build its table from the three notes' "For the comparison" sections, with the columns of design § 11: what went wrong; whether the signing certificate was still valid; whether workloads could reach the identity service; how failure spread (simultaneously, staggered by each workload's own certificate, or bounded by each certificate's remaining life); what recovery took; what `linkerd check` showed. Put a sentence under it on how to tell them apart, from the diagnosis signals each note quotes. Include only facts whose scenario met its § 13 condition. For a scenario that didn't, the cell says "not tested".

- [ ] **Step 5: Diagnosis, recovery and best practices**

- Extend "Diagnosis" with the signals the webhook, outage and anchor notes quote (only met scenarios).
- Add a recovery section for an expired trust anchor, from the anchor-expiry note's recovery stages: what the documented replacement did, whether identity needed a restart, and what workload restarts did. Keep Linkerd's documentation as the procedure's authority.
- Rewrite "Best practices" → "Trust-anchor rotation needs restarts" from the rotation note's "Evidence for the rotation guidance": the staged procedure, what each restart step was for, and what the one-step replacement showed goes wrong. Move it to "From what we saw in the lab" only if the rotation scenario's condition is met.
- Rewrite "The 60-day warning threshold is fixed" from the threshold note: what the headline showed just under and just over 60 days, next to the 15-minute case.
- Rewrite "Treat webhook certificates as first-class" from the webhook note, including what recovery took for lab-supplied certificates and the credential-model caveat.

- [ ] **Step 6: The rest of `findings.md`**

- **Scope paragraph:** say the page now rests on several experiments and a repeat of the issuer experiment, all on Linkerd `edge-26.9.1` on a single-node test cluster, each with shortened lifetimes (name them in plain words), and each paired with a matching run in which nothing expired.
- **"The short version":** re-number the "What we reproduced" list and trim "What Linkerd's code says, not yet tested" to what is still untested.
- **"Still open":** remove the questions the notes answer, keep the rest, and add any new open questions the notes list. Delete the paragraph saying a repeat of the issuer experiment is pending.
- **"Where the details are":** list the six new notes with one-line descriptions.

- [ ] **Step 7: `sources.md`**

- Expand "This project's own evidence" → "Our lab": one entry per experiment (issuer expiry and its repeats, webhook certificates, identity outage, the `linkerd check` threshold, trust-anchor expiry, trust-anchor rotation). Each entry gets **Where** (its note), **Authority level** (first-party experiment; number of runs; version; lifetimes; paired with a run where nothing expired), **Claims supported** (only claims whose § 13 condition is met), and **Research notes** (the "in our testing" attribution, and the credential-model caveat for webhooks).
- Update the research notes of the Linkerd entries the lab now bears on: "Manually Rotating Control Plane TLS Credentials" (the staged rotation), "Replacing expired certificates" (the anchor recovery), "Rotating webhooks certificates" (the recovery branch observed for lab-supplied certificates), "Troubleshooting and `linkerd check`" (the threshold measurements).
- In "Unsupported or editorial claims", update "Hard trust-anchor replacement is the most common self-inflicted outage" and "Single-proxy renewal failure is usually not a certificate-management task" with what the rotation and outage evidence supports, without upgrading either to a sourced fact.
- Add a maintenance-log entry dated when you make the change: "Added the second round of lab experiments", listing which entries changed.

- [ ] **Step 8: `README.md`**

- **Status:** replace the three status bullets with one per area, in plain words: which experiments were run and written up, which are reproduced, and that viz/tap is not tested (a possible follow-up).
- **"Start here":** item 1's description now says the triage table's first part holds what we reproduced across the experiments.

- [ ] **Step 9: Scan the three pages for the style rule**

Run: `grep -nE '\b[RWOKAS][0-9]\b|S1-obs|T_mark|runs/[0-9_]|[0-9]{8}T[0-9]{6}Z|\btick|\bgate[ds]?\b|stage[0-9]|issuer-short|webhook-short|anchor-short|check-threshold|slice' docs/articles/cert-hygiene/README.md docs/articles/cert-hygiene/findings.md docs/articles/cert-hygiene/sources.md`
Expected: no output. Rewrite any hit in plain words, and re-run until it prints nothing.

Run: `grep -c 'in our lab\|in our testing' docs/articles/cert-hygiene/findings.md`
Expected: at least one per promoted row. Read each promoted details section once more against the guardrails above.

- [ ] **Step 10: Commit**

```bash
git add docs/articles/cert-hygiene/findings.md docs/articles/cert-hygiene/sources.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene carry the second round of lab results into the findings, sources and README"
git push
```
