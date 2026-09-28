# Cert-Hygiene Lab, Slice 3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Read this README first, then only your task file.

**Status:** approved by the user on 2026-09-13, extending the [slice 2 design](../../specs/2026-09-11-cert-hygiene-lab-slice-2-design.md).

**Goal:** close the last untested row of the article's triage table, and turn one "we cannot say" into a measurement.

1. **Tap/viz expiry (design § 8, scenario V).** The only scenario the slice 2 design specified and never ran. It was optional and needed the user's confirmation, which it now has.
2. **The `linkerd check` 60-day boundary.** Slice 2 showed the warning still firing at 60 days + 557 s and clearing at 61 days + 30 min, so the article can only state a 24-hour-wide bracket. A short bisect turns that into a number.

**Spec:** the slice 2 design remains the binding authority. § 8 defines V and V1; § 1.3's rule table, § 1.6's gates, § 13's acceptance conditions and § 14's guardrails all apply unchanged. K's design is § 5.

## What changed since slice 2, and what it costs

The harness was frozen at commit `5827915`, and every slice 2 evidence run records that tree's hash. Adding a scenario changes the hash, so:

- **V needs a fresh control run at the new tree.** V is a timed scenario, so its `control-at-tree` rule demands one. Budget an hour for it before V itself.
- **K does not.** Its rule list is `k-remaining` alone, by design — no probe outcome is judged — so K runs at any tree are valid.
- **Slice 2's recorded runs are unaffected.** Their verdicts were written at run time from values recorded in their own files; nothing re-derives them.

Recorded runs no longer live in this repository. Each new run is published with `tools/evidence-upload.sh`, which uploads it and writes the manifest; the manifest is committed, the local copy removed, and the archive added to the evidence release.

## Global Constraints

Slice 2's Global Constraints carry over unchanged — the same Linkerd version and Gateway API CRDs, the same OrbStack VM, clocks never altered, private keys never in the repo, `set -euo pipefail` everywhere, code files under 300 lines, no fallbacks or mock data outside tests, scripts judging validity and never hypotheses, evidence directories written once. In addition:

- **Commit and push at the end of every task**, on `article/cert-hygiene`, with messages starting `cert-hygiene ` and **no AI attribution**.
- **Publish, do not commit, run data.** `git add` a run's manifest; never its files.
- **The control must be re-run after the last harness change and before V.** A V run whose tree does not match a valid control is not evidence.

## Tasks

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 1 | Viz install and the tap credential | [task-01-viz-install.md](task-01-viz-install.md) | `tap-short` profile; viz installed with a lab-supplied tap certificate; discovery that Linkerd accepts it and that tap works while it is valid (**stop gate**) |
| 2 | Collector: APIService and viz state | [task-02-collect-apiservice.md](task-02-collect-apiservice.md) | Per-tick `apiservices/` and viz pod state; `v-baseline` validity rule with tests |
| 3 | Scenario V | [task-03-scenario-v.md](task-03-scenario-v.md) | `30-tap-expiry` scenario, rules and pins; one discovery run |
| 4 | K's plus lifetime as an argument | [task-04-k-argument.md](task-04-k-argument.md) | The bisect can vary the lifetime per run without touching the tracked tree |
| 5 | Freeze and re-run the control | [task-05-control-rerun.md](task-05-control-rerun.md) | A valid control at the new harness tree |
| 6 | V evidence run | [task-06-v-run.md](task-06-v-run.md) | One valid V run, published |
| 7 | K bisect runs | [task-07-k-bisect.md](task-07-k-bisect.md) | Four K runs bracketing the boundary, published |
| 8 | V write-up | [task-08-v-writeup.md](task-08-v-writeup.md) | `notes/lab-evidence-tap-expiry.md`, judging V1 |
| 9 | K write-up: the measured boundary | [task-09-k-writeup.md](task-09-k-writeup.md) | The existing threshold note updated with the bracket the bisect establishes |
| 10 | Reader pages | [task-10-reader-pages.md](task-10-reader-pages.md) | The last triage row moved or corrected; the boundary stated as measured |

Tasks are sequential. Tasks 1 and 3 have stop gates: if Linkerd will not serve a lab-supplied tap certificate, or if tap does not work while that certificate is valid, V cannot be run as designed and the controller decides what to do.
