# Task 8: V write-up

Part of the [slice 3 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where V1 is judged. Nothing recorded is edited.

**Goal:** judge V1 (spec § 8) against the run Task 6 produced, and write `docs/articles/cert-hygiene/notes/lab-evidence-tap-expiry.md`.

**V1, exactly as the design states it:** "The tap APIService goes `Available=False`, `linkerd viz tap` fails, and `linkerd viz check` goes fatal on 'tap API server has valid cert'." It is one hypothesis with three clauses, and the run does not treat them alike — say so rather than averaging them into a single word.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-tap-expiry.md`
- Modify: `docs/articles/cert-hygiene/README.md` (the "Start here" list and the status bullet — the README stays current in the same commit as the artifact)

**Reading the evidence.** The run is not in this repository. Read individual files with `bash tools/evidence.sh cat <run> <path>`, or fetch the whole run once with `bash tools/evidence.sh fetch <run> <dest>` and work locally — prefer the fetch, since this write-up reads many files. Both verify against the committed manifest. Never read from the B2 API.

**Judgement vocabulary:** confirmed / falsified / inconclusive, as the reading guide defines them. A clause the run contradicts is falsified; write that plainly.

**Steps:**

1. **Facts.** `validity.txt` (must be `evidence_valid=yes`), the harness tree hash against the control's, `versions.txt`, `tap-baseline.txt`, the tap certificate's `notBefore`/`notAfter`, and every marker in `timeline.log` with its UTC time. State the phase boundaries in seconds after expiry, as the other notes do.

2. **Per-clause evidence.** For each of the three clauses, walk the ticks in order — the last before expiry, the first after, the last before the forced reconnect, and each reconnect tick:
   - **APIService:** the `Available` condition's status, reason and message per tick.
   - **`linkerd viz tap`:** whether it returned events, how many, and the exact error text when it failed.
   - **`linkerd viz check`:** the "tap API server has valid cert" row, and whether the check was fatal.
   Give the numbers per tick, not a summary: the interval between expiry and the first failure is the finding.

3. **The reconnect phase.** Say what forced it (`reconnect/backing.txt`), that the pod's UID changed, and what each of the three clauses did after it. Every claim about when tap started failing must state whether the API server had reconnected — the same rule W follows, for the same reason.

4. **Mesh traffic.** Whether the probes failed at any point and when relative to the restart. A probe failure adjacent to a deliberate pod restart is restart-adjacent, not evidence about certificate expiry; label it that way.

5. **Write the note**, modelled on `notes/lab-evidence-webhook-expiry.md`: run and control identifiers with their tree hash, versions, the credential caveat (a lab-supplied static tap certificate is not how Linkerd normally runs — the tap certificate is normally issued by the viz installer), a phase table, a section per clause with Verdict / Evidence / Notes, the reconnect section, and a closing "What this means for the article" that names the triage row this moves and the artifact paths a reader can check.

6. **Check every number you write** against the file you took it from, then re-check the arithmetic: three of slice 2's six notes went out with a wrong interval, each computed in the head from two timestamps that were right. Subtract on paper.

7. **Do not generalise beyond one run.** V ran once. Where a claim would need repetition, say the run showed it once.

8. Update the README, commit (`cert-hygiene record tap-expiry observations`) and push.
