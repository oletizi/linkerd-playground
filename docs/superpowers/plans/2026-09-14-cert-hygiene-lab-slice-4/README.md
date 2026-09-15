# Cert-Hygiene Lab, Slice 4 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Read this README first, then only your task file.

**Goal:** produce the two failures the article's triage table exists to distinguish expiry from — a webhook that is down with a healthy certificate, and a certificate that is valid but refused — and find out what the diagnostic surface says while each is happening.

**Spec:** [the slice 4 design](../../specs/2026-09-14-cert-hygiene-lab-slice-4-design.md), which extends the [slice 2 design](../../specs/2026-09-11-cert-hygiene-lab-slice-2-design.md). Slice 2 remains the binding authority for the rule table (§ 1.3), the gates (§ 1.6), the acceptance conditions (§ 13) and the guardrails (§ 14).

## What is different about this slice

**Nothing expires.** Every previous scenario turned on a `notAfter` passing. These two must show their certificates *valid* throughout — that is what makes them controls rather than more expiry runs. A G run that cannot prove its certificate was time-valid at every tick is not evidence.

**One scenario may not be runnable.** G depends on the API server refusing a certificate for its signature algorithm, which is unverified on this cluster and which the lab's own signing tool will not produce. Task 3 is a stop gate: if no candidate is refused for its algorithm, G stops there and the controller decides.

**The harness debt is paid first.** Adding scenarios changes the tree and costs a control re-run anyway, so slice 3's four deferred findings are free here and are done before the freeze.

## Global Constraints

Slice 2's and slice 3's constraints carry over unchanged — the same Linkerd version and Gateway API CRDs, the same OrbStack VM, clocks never altered, private keys never in the repo, `set -euo pipefail` everywhere, code files under 300 lines, no fallbacks or mock data outside tests, scripts judging validity and never hypotheses, evidence directories written once. In addition:

- **Commit and push at the end of every task**, on `article/cert-hygiene`, with messages starting `cert-hygiene ` and **no AI attribution**.
- **Publish, do not commit, run data.** `git add` a run's manifest; never its files. Run directories are git-ignored as of `fd0ef275`.
- **Never delete the current control run's local copy.** The `control-at-tree` rule reads it; Task 1 changes that, and until it does, deleting it invalidates every timed run.
- **The freeze holds from Task 5.** After the control is recorded, any harness change means a new tree and a new control.

## Tasks

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 1 | Harness debt from slice 3's final review | [task-01-harness-debt.md](task-01-harness-debt.md) | `control-at-tree` reads manifests; the duplicated reconnect block shared; `_v_backing` carries its namespace; unit tests for slice 3's collectors |
| 2 | Scenario N: the webhook is unavailable | [task-02-scenario-n.md](task-02-scenario-n.md) | `40-webhook-unavailable-ignore` and `-fail`, rules, one discovery run |
| 3 | G feasibility (**stop gate**) | [task-03-g-feasibility.md](task-03-g-feasibility.md) | Whether any certificate is refused for its algorithm, and the exact error — or a documented dead end |
| 4 | Scenario G: the certificate is refused | [task-04-scenario-g.md](task-04-scenario-g.md) | `41-webhook-algorithm`, rules, one discovery run |
| 5 | Freeze and re-run the control | [task-05-control-rerun.md](task-05-control-rerun.md) | A valid control at the new harness tree |
| 6 | N evidence runs | [task-06-n-runs.md](task-06-n-runs.md) | Both policies, published |
| 7 | G evidence run | [task-07-g-run.md](task-07-g-run.md) | One valid run, published |
| 8 | Write-up | [task-08-writeup.md](task-08-writeup.md) | `notes/lab-evidence-not-expiry.md`, judging N1–N5 and G1–G4 |
| 9 | Reader pages | [task-09-reader-pages.md](task-09-reader-pages.md) | The triage table gains what distinguishes these causes from expiry |

Tasks are sequential. Task 3 is a stop gate: if it fails, Tasks 4 and 7 are dropped and the slice delivers N alone — which is still worth shipping, and the write-up says why G could not be run.
