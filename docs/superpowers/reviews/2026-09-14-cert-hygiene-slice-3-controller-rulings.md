# Slice 3 controller rulings

Every decision taken while executing the [slice 3 plan](../plans/2026-09-13-cert-hygiene-lab-slice-3/README.md), with what it cost and what it would have cost if wrong. Recorded for the same reason as [slice 2's](2026-09-12-cert-hygiene-slice-2-controller-rulings.md): a reader who disagrees with a judgement should be able to find it, see the reasoning, and overturn it without re-deriving the situation.

Slice 3 ran the tap/viz expiry scenario — the last untested row of the article's triage table — and bisected the `linkerd check` 60-day boundary.

## On the scenario

**Add a forced-reconnect phase to V (task 3b).** Discovery showed tap still streaming events long after its certificate expired, exactly as the webhook scenario had shown for admission webhooks. Without a reconnect phase V could only have reported that nothing appeared to break. Taken before the harness freeze, so it cost nothing then; after the freeze it would have cost a control re-run. It became the finding the slice is built on.

**V1's verdict stays "falsified as literally stated, confirmed after the reconnect."** The implementer offered "confirmed, but only after a forced reconnect" as a gentler headline. V1 asserts three things follow from expiry; two did not. Burying that in a qualifier would lose the finding, and the webhook note already sets the precedent.

## On the harness freeze

**Restore the control from its published archive rather than fix the rule.** The first V run came back `evidence_valid=no`: `control-at-tree` reads the control from disk, and task 5's brief — written by the controller — had told the agent to delete it after publishing. Fetching the published copy back, verified against its committed manifest, made the run repeatable at the same frozen tree. Fixing the rule instead would have changed the harness tree, invalidated the control, and cost a second control run on top of the V re-run. Cost of the ruling: one V re-run, about 50 minutes.

**The durable fix is deferred.** Teaching `control-at-tree` to read committed manifests costs a control re-run whenever it is made, so deferring costs nothing later, and the failure mode is loud — `evidence_valid=no` with the reason named — rather than silent.

**The current control's local copy is never deleted.** Publishing it is for durability, not eviction. Task 5's brief was corrected so the trap cannot recur.

**The three harness findings from the final review are deferred to the next slice**, bundled with the `control-at-tree` fix: a reconnect-exit block duplicated verbatim between the webhook and tap validity rules, `_v_backing` deriving a namespace and then hardcoding it, and no unit tests for the new collectors. Any edit under `lib/` or `demos/cert-hygiene/` makes a new tree and costs a control re-run; bundling them costs one re-run rather than several, and none of them affects the evidence already recorded. Cost if wrong: the next person adding a scenario copies the duplicated block.

## On the bisect

**Continue past the brief's four runs to eight.** The runs cost about four minutes each rather than the fifteen budgeted, and after four the bracket was still about 90 minutes wide. The stronger reason was evidentiary: every run so far had passed, so the warning side of the bracket still rested on a single slice 2 run. Four more produced the first valid warn points, putting both sides of the boundary on valid runs at one frozen tree — which is what let K's acceptance condition be re-judged at all.

**The provable-value convention.** A check command spans `[start, end]` and the issuer row is evaluated at an unknown instant inside it. A run that warned proves only that the threshold is at least that command's **end** value; a run that passed proves only that it is below that command's **start** value. The first report had this inverted in both directions, claiming a bracket 8 seconds narrower than the evidence supported. Applied across both commands of a run — the smaller start among passes, the larger end among warns — it gives the published 305-second bracket.

**The same inversion in the existing note was corrected without weakening its claim.** Its headline "still warned at 60 days + 557 s" quoted a warn at its start value; provably it is 553 s. The point that run made — a certificate with more than 60 days left still drew the warning — survives either figure.

**K's acceptance condition is ruled met**, reversing this note's earlier ruling. The design's K row reads naturally as a per-run test, and six of the eight bisect runs meet it at one frozen tree. The note states which three runs do not flip and why that is the interesting part, so a reader can disagree with the reading without re-deriving the data.

**The 3,600-second coincidence stays in.** The bracket contains one hour. The note records that and immediately says a bracket containing a round number is not a mechanism. Cutting it would hide a fact any reader can compute from the bracket themselves.

## On the write-ups

**`sources.md` was pulled into scope.** It still said the check clearing above 60 days had never been seen in a valid run, and that the tap case was not reproduced here. Both had become false. A reader-facing page asserting the opposite of the evidence is a defect, not scope creep.

**The cross-page vocabulary question was settled on exit status, and turned into a finding.** The three pages disagreed on whether the issuer row's `‼` is "fatal". Grounding the answer in what the transcripts record showed the command succeeds: all forty threshold transcripts exit 0, including all twenty-six that printed the warning, and an issuer fourteen and a half minutes from expiry still exits 0. So anything monitoring `linkerd check` by its exit status never sees this warning at any margin. It was the sharpest operational consequence of the slice and it had been stated nowhere.

**A misquotation in a committed discovery artifact was corrected despite write-once.** `FINDINGS.md` there is authored prose, not captured output, and it misquoted the transcript sitting beside it. Making an authored summary agree with its own evidence is the opposite of what write-once protects against; the transcript and every other artifact in that directory were untouched.

**Run directories are now git-ignored.** The ruling that the control's local copy is permanent left 1,481 untracked, unignored files in the working tree, one `git add -A` away from committing run data the plan says to publish. The root `.gitignore` is outside the hashed paths, so the rule does not disturb the freeze.

## What the process caught, and what it did not

Three of slice 2's six write-ups shipped with an interval computed wrongly from timestamps that were right. Slice 3's reviewers were told to recompute rather than check prose for internal consistency, and that found: an inverted bracket convention, a count stated as uniform across 58 ticks when seven differed, a journal denominator that counted a superset string, a run count that folded a non-evidence run into a scope statement, a generalisation about webhook logs the same page contradicted two sections above, and a note describing a sibling page's superseded state in the present tense.

Three times a correction to a count introduced a fresh counting error. That is the argument for verifying corrections as strictly as originals, which this slice did.
