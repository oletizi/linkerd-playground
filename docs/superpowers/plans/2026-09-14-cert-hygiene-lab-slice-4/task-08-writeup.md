# Task 8: The write-up

Part of the [slice 4 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where N1–N5 and G1–G4 are judged. Nothing recorded is edited.

**Goal:** `docs/articles/cert-hygiene/notes/lab-evidence-not-expiry.md`, judging both scenarios in one note because they make one argument together.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-not-expiry.md`
- Modify: `docs/articles/cert-hygiene/README.md` (the "Start here" list and the status bullet, in the same commit)

**Why one note.** N and G are separate experiments but a single claim: a symptom does not identify a cause. N shows a failure that looks like a certificate problem and is not one. G shows a certificate problem that is not expiry. Read apart they are two small results; read together they are the test of whether the article's triage table does anything. Give each its own section and verdicts, then a section that puts them beside the expiry results.

**Reading the evidence.** The runs are not in this repository. Fetch each once with `bash tools/evidence.sh fetch <run> <dest>` and work locally; never read from the B2 API. Verify nothing against another document — every figure comes from the run's own files.

**Steps:**

1. **Facts per run:** `validity.txt`, the harness tree against the control's, `versions.txt`, the rule results, and the phase times from `timeline.log`.

2. **Judge each hypothesis separately**, in the sanctioned vocabulary (confirmed / falsified / inconclusive), with Verdict / Evidence / Notes as the other notes do. N1–N5 and G1–G4 are nine verdicts, not two.

3. **Give N2 and G3 the most room.** N2 asks whether an unavailable injector and an expired injector produce the same observable; G3 asks whether `linkerd check` calls a certificate valid that the API server refuses. Each is the hypothesis its scenario exists to answer, and each is the kind of result the article will lean on. If either holds, say exactly what a reader can and cannot conclude from it.

4. **The contrast section.** For each of the three causes the lab has now produced — expired, unavailable, refused-for-algorithm — say what the operator-visible symptom was, what `linkerd check` said, what the API server said, and what distinguishes it from the other two. If two causes are genuinely indistinguishable from a given signal, say so plainly; that is the most useful thing this note can tell a reader, and it is the thing a triage table must not paper over.

5. **Keep the credential caveat.** These webhook certificates are lab-supplied, as every W run's were, and G's is signed by tooling the lab otherwise refuses to use. Both belong on every claim.

6. **Check every number against the file you took it from, then recheck the arithmetic.** Three of slice 2's six notes shipped with an interval computed wrongly from timestamps that were right, and three times since, a correction to a count introduced a fresh counting error. Subtract on paper; count by listing members.

7. **Do not generalise past the runs.** N ran twice, once per policy. G ran once. Where a claim would need repetition, say so.

8. **If G was not run**, write the note for N alone and give G its own short section saying what Task 3 found and why the scenario could not be built. A documented dead end is a result the article can use — it tells a reader something about the platform.

9. Update the README, commit (`cert-hygiene record what a non-expiry certificate failure looks like`) and push.
