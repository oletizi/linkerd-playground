# Slice 4 controller rulings

Every decision taken while executing the [slice 4 plan](../plans/2026-09-14-cert-hygiene-lab-slice-4/README.md), with what it cost and what it would have cost if wrong. Written at the end of the slice and extended after the whole-branch review, so that the last two rulings are here rather than only in the working ledger. Recorded for the same reason as [slice 2's](2026-09-12-cert-hygiene-slice-2-controller-rulings.md) and [slice 3's](2026-09-14-cert-hygiene-slice-3-controller-rulings.md): a reader who disagrees with a judgement should be able to find it, see the reasoning, and overturn it without re-deriving the situation.

Slice 4 ran the two experiments in which nothing expires — a webhook whose pods are gone with a healthy certificate, and a certificate that is time-valid and correctly chained but refused for its signature algorithm.

## On scope

**The plan's own text was corrected before execution.** The pre-flight scan found Task 2 naming one scenario file and one profile while its own step 4 invoked a second, against a precedent of two entry points and two profiles. Ruled in favour of mirroring the webhook pair exactly: the scenario's central hypothesis compares its `Ignore` result against the webhook experiment's `Ignore` result, and a comparison between differently-structured runs is a comparison between different things.

**The harness debt from slice 3's final review was paid first.** Adding scenarios changes the hashed tree and costs a control re-run regardless, so four deferred items were free before the freeze and would have cost an hour each afterwards. One of them — teaching `control-at-tree` to read committed manifests — closed the bug that had invalidated a good fifty-minute run in the previous slice, and it was verified end to end against a real published control by moving the control's directory aside.

**`sources.md` and `findings.md` were both pulled into the final task's scope** where they made claims this slice's evidence contradicts. Correcting a reader-facing page that asserts the opposite of the evidence is fixing a defect, not widening scope.

**An older claim was narrowed rather than deleted.** The pages said `linkerd check` can be green while traffic is broken. That is false for the refused certificate, where the check is fatal and accurate — but it remains true for the causes it was drawn from, and the original finding stays reachable. Newer evidence qualifying an older headline is the case most likely to be handled too bluntly.

**The triage table kept its shape and lost a column.** When the discriminating information made the rows too dense, the choice was between moving it into per-row prose and dropping something else. Prose beneath a table is the same burial one step shorter — a reader holding a proxy-less pod reads the row and stops — so the mechanism column went instead, since every one of its cells was already in the detail section the row links to. The discriminator is the only column that answers the question the reader arrived with.

## On the feasibility gate

**The gate was written so that a negative was a success.** Scenario G depended on the API server refusing a certificate for its signature algorithm, which was unverified on this cluster and which the lab's own signing tool was believed unable to produce. The brief said in terms that a clean negative costs an hour and saves building a scenario that cannot produce its own evidence, and that no other fault was to be improvised to keep the scenario alive. The gate passed on its first candidate.

**The gate's answer to a hypothesis did not change the hypothesis.** Discovery showed `linkerd check` failing the certificate row, contradicting the pre-registered prediction that it would pass. The prediction stayed exactly as written and was judged from the evidence run instead. Rewriting a pre-registered hypothesis to match what discovery found is the single thing this lab's discipline exists to prevent.

**Two beliefs the brief was built on turned out to be wrong, and the briefs were corrected rather than the record.** `step` will emit a SHA-1 leaf through a certificate template — only its command-line flags refuse — so no `openssl` path was added. And the design's claim that every scenario the lab had run was a certificate that expired was false: the threshold bisect and the staged rotation are neither. That error propagated into a reader-facing note before a reviewer caught it; the design now carries the correction in place with the original sentence quoted.

## On what was tested, and what was not

**Scenario G used the ServiceProfile validator rather than the proxy injector.** The mechanism under test is the API server's certificate verification, which is not component-specific, and the validator has the smallest blast radius: a refused proxy-injector certificate under a fail-closed policy would fail every pod creation and could leave a run unrecoverable. The cost is that the two experiments tested different components, which the pages state rather than imply.

**Scenario G used the fail-closed policy**, because under fail-open the client sees nothing and the hypothesis is about the error the API server returns.

**`linkerd viz check` was dropped from G.** Viz is not installed on these profiles, so its transcripts read "namespace not found" — a recorded non-answer that invites a reader to mistake absence for a result.

**A second G run varying only the signature algorithm was not ordered.** The refused certificate differs from the working one in three ways: algorithm, extended key usage and lifetime. The API server's error names the algorithm explicitly, so the attribution is well supported — but it is an argument from the record rather than a single-variable proof, and the note and pages say exactly that rather than more. The run that would settle it costs a harness change, a fresh control and another run; it is recorded as open instead.

**A known wait gap in two older scenarios was left alone.** Both restart a Deployment without waiting for the old pods to go — the weaker form of a bug scenario G hit and fixed. Their published runs are not corrupted by it, because their own recorded pod identities show the replacement pod at every tick afterwards. Fixing it would change the artifact sets of two scenarios this slice never re-runs, for no benefit here.

## On the evidence

**Discovery runs are published like every other run, and only their manifest is committed.** A `.gitignore` rule written earlier had said otherwise, generalised from the single whole discovery run that had been committed; twenty-five of the twenty-seven were manifests only. One discovery run of 901 files was published and its files removed.

**The 6.1 MB already committed was not rewritten out of history.** A third force-push under an open pull request costs more than the objects do, and removing the files fixes the working-tree weight that was the actual concern.

**Harness code was changed after the freeze, deliberately.** Two holes were found in the private-key guard — a locale-dependent read that silently skipped files, and a swallowed exit status that dropped unreadable ones — in a function documented as failing closed. Both were fixed once every evidence run was recorded and reviewed, because the freeze exists to protect runs, and a changed tree only obliges a *future* run to have a fresh control.

## What the process caught

Every figure an implementer reported was recomputed by a reviewer from the run files rather than checked for internal consistency. That found: a fault that was not proved to have taken effect before probing, a run whose fault could have failed entirely while still being marked valid evidence, a wait that could hang forever on a pod that would never be deleted, an asserted mechanism the run disproved, a tick count contradicting its own enumeration in the same sentence, an interval computed in the wrong direction, a false universal quantifier, a miscounted upload, and a claim about two tools' behaviour drawn from one run.

Seven times in this project a correction has introduced a fresh error — twice in this slice. The first was a sentence added while fixing five others. The second was worse and is the one worth learning from: a clause corrected in the note was re-imported verbatim into two other pages by a task already in flight, because the controller dispatched that task while the document it was told to draw from was still being corrected. The implementer copied text that was accurate when it read it and stale by the time it committed.

A correction is the highest-risk edit here, because it is made under the belief that the surrounding text was just checked — and a correction to a *source* document is riskier still, because work already running against it does not see the change. Every fix round got its own verification pass, and every one of those passes found something, including the last: the whole-branch review is what caught the re-import.
