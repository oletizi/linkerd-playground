# Task 9: K write-up — the measured boundary

Part of the [slice 3 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md).

**Goal:** fold Task 7's bisect runs into `docs/articles/cert-hygiene/notes/lab-evidence-check-threshold.md`, replacing the 24-hour bracket with the measured one.

**What the note says today,** and what must change:

- It bounds the boundary "above 60 days + 557 s and at or below 61 days + 30 minutes — about 24 h 21 m", and flags that only the lower bound is evidence-backed: the upper bound came from a supplementary run marked `evidence_valid=no` because a local config override made the tree dirty.
- It rules that **K's acceptance condition is not met by that run**, because design § 13 requires the measured values *and* the transcripts to land on opposite sides, and no transcript ever printed `√`.

Task 7's runs are valid evidence, and Task 4 removed the reason the supplementary run was dirty. So if any bisect run's transcripts print `√`, the pass side is now evidence-backed for the first time — **re-judge K's acceptance condition and K1's second half on the new evidence**, and say so explicitly rather than leaving the old ruling standing beside new numbers.

**Files:**
- Modify: `docs/articles/cert-hygiene/notes/lab-evidence-check-threshold.md`, `docs/articles/cert-hygiene/README.md` (status bullet, if it mentions the bracket)

**Reading the evidence:** the runs are not in the repository. Use `bash tools/evidence.sh cat <run> <path>` or `fetch`; never the B2 API.

**Steps:**

1. Read Task 7's report and every bisect run's `k/plus-calc.txt`, `k/plus-check.txt`, `k/plus-check-proxy.txt`, `k-remaining.txt`, `versions.txt` (for the recorded lifetime) and `validity.txt`. Take each number from the file, not from the report.
2. Extend "The measurements" table with one row per transcript per run: configured lifetime, run, command, start/end times, remaining validity at start and end, and the headline row printed. Keep the existing rows.
3. State the bracket as two measured numbers — the largest remaining validity that still warned and the smallest that passed — with the run and file each comes from, and give the width. Do the subtraction on paper.

   **Use the provable value in each direction, and say why.** `k/plus-calc.txt` brackets the whole command's wall time, and the issuer row is evaluated at an unknown instant inside `[check_started, check_ended]`, so remaining validity at evaluation lies between the end value (smallest) and the start value (largest). A run that **warned** proves only that the threshold is at least its **end** value; a run that **passed** proves only that the threshold is below its **start** value. Taking the other value in either direction claims a narrower bracket than the evidence supports.

   This affects the existing note too. Its headline "still warned at 60 days + 557 s" is a warn quoted at its start value; the provable figure from that run is its end value, 553 s. The point that run was making — that a certificate with more than 60 days left still drew the fatal row — survives either way, so correct the figure without weakening the claim. The bisect's own warn points supersede it as the bracket's lower bound in any case; say which run the bound now comes from.
4. Rewrite the parts of "K1 — verdict", "Acceptance condition" and "What this means for the article" that the new runs change. If the pass side is now observed in valid runs, the note must say that, and must no longer describe the upper bound as depending on a non-evidence run. Keep the supplementary run in the note as history, relabelled as superseded.
5. Leave the mechanism unexplained. The note's "Inference, not established fact" paragraph named a sweep as what would settle where the headline flips; the bisect locates the flip, and still shows nothing about why. Update that paragraph to say what the sweep found and what remains unknown — do not convert a narrower bracket into an explanation.
6. Check every figure against its source file, then re-check the arithmetic.
7. Commit (`cert-hygiene record the measured 60-day check boundary`) and push.
