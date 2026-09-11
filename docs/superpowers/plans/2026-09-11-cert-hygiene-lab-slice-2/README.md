# Cert-Hygiene Lab, Slice 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task lives in its own file in this directory; read this README first, then only your task file.

**Goal:** Generalise the slice-1 lab harness (credential profiles, planned credential transitions, richer collection, a second client, gated restart stages, scenario hooks), record valid evidence for scenarios R, W, O, K, A and S at one harness tree, and judge their hypotheses in per-scenario write-ups before any reader-facing page changes.

**Architecture:**
- **Harness (Phase 1).** Bash in `demos/cert-hygiene/`. Credential lifetimes move from `config.example.env` into `lab/profiles/<profile>.env`. The collector gains credential, webhook and control-plane state per tick. The evidence library (`lab/lib-evidence*.sh`, pure, unit-tested) gains a credential-plan walk and one validity rule table keyed by scenario name. Restart stages are gated (`lab/gates.sh`) and composed into choreographies (`lab/stages.sh`). `run_scenario` gains three hooks; a second entry point, `run_steps_scenario`, serves the step-driven scenarios (K, S-staged).
- **Evidence (Phase 2).** No harness changes. Control first, then every scenario at the same harness tree, each run committed the moment it finishes.
- **Write-ups (Phase 3).** Hypotheses are judged only in `docs/articles/cert-hygiene/notes/`. Reader-facing pages change last, only where design § 13 is met.

**Tech stack:** bash, OrbStack (`orb`), k3s, Linkerd `edge-26.9.1`, Gateway API `v1.5.1`, smallstep `step`, `openssl`, `jq`, `envsubst`, `shellcheck`. Probe images as pinned in `config.example.env`.

**Spec:** [`docs/superpowers/specs/2026-09-11-cert-hygiene-lab-slice-2-design.md`](../../specs/2026-09-11-cert-hygiene-lab-slice-2-design.md) is the binding authority. It builds on the [slice-1 design](../../specs/2026-09-10-cert-hygiene-demo-lab-design.md). Executors read the slice-2 design and this plan. Section references like "design § 1.6" mean the slice-2 design.

**Source notes (Linkerd behaviour, with permalinks):** [`docs/articles/cert-hygiene/notes/linkerd-source-notes.md`](../../../articles/cert-hygiene/notes/linkerd-source-notes.md)

## Scenario names

The design uses letters; runs are stored under the scenario's file name. The numbers follow `docs/articles/cert-hygiene/notes/demo-feasibility.md` where a matching row exists.

| Design | Scenario file (`scenarios/<name>.sh`, runs under `runs/<name>/`) | Profile |
| --- | --- | --- |
| control | `00-baseline-control` | `long` |
| R | `05-issuer-expiry` (slice 1's scenario #5, re-run) | `issuer-short` |
| W (Ignore) | `02-webhook-expiry-ignore` | `webhook-short` |
| W (Fail) | `02-webhook-expiry-fail` | `webhook-short-fail` |
| O | `09-identity-outage` | `long` |
| K | `20-check-threshold` (no feasibility row; numbered outside the matrix) | `check-threshold` |
| A | `06-anchor-expiry` | `anchor-short` |
| S-staged | `07-anchor-rotation-staged` | `long` |
| S-hard | `08-anchor-rotation-hard` | `long` |

## Global Constraints

- Everything in slice 1's Global Constraints still holds:
  - Linkerd for cert-hygiene: `LINKERD_EDGE_VERSION=edge-26.9.1`. Gateway API CRDs `v1.5.1`, applied with `kubectl apply --server-side`.
  - Lab machine: OrbStack, `ubuntu:24.04`, named `cert-hygiene-lab`, native architecture. Never pass `-a amd64`.
  - **Never alter any clock.** Expiry comes only from short-lived certificates.
  - **Private keys never enter the repo tree.** Lab keys live in the VM under `$HOME/cert-hygiene-certs/`. Evidence holds certificates only; `assert_no_keys` must pass on every run. Rendered manifests are redacted before they are written to evidence (Task 12).
  - Every bash script starts with `set -euo pipefail` and sources `lib/common.sh`, directly or through `lab/lib-lab.sh`. Sourced libraries (`lib-*.sh`, `collect*.sh`, `gates.sh`, `stages.sh`) are sourced, never executed.
  - Keep every code file under 300 lines. This plan splits `lib-evidence.sh` (Tasks 2–3), `collect.sh` (Task 4) and `scenario-common.sh` (Tasks 7–9) for that reason.
  - No fallbacks and no mock data outside tests. Fail loudly with a message naming what is missing.
  - Scripts **never** judge hypotheses. They record observations, and judge only evidence validity, the control's criteria, restart-gate conditions, W's recovery branch (a declared, mechanical classification) and S-hard's stage-1 condition, all as defined in this plan.
  - Evidence directories are written once and never edited. Invalid runs are committed too; `validity.txt` says why they don't count.
- **Commit and push at the end of every task**, on branch `article/cert-hygiene`. Commit messages start with `cert-hygiene ` and carry **no AI attribution**: no `Co-Authored-By`, no session links, no "Generated with" footer.
- **Update `docs/articles/cert-hygiene/README.md` in the same commit** whenever a task changes what exists or its status. Its "Status" section is a bullet list; each task says which bullet to change.
- **Tool-call rules for executing agents:**
  - Never put `#` characters inside Bash heredocs or multi-line quoted arguments. Write files, commit messages and FINDINGS files with the Write tool.
  - Never use `sed` to write files (read-only `sed -n` is allowed; prefer the Read tool).
  - Prefer a script file over a complex one-liner.
  - Launch long runs detached (`scripts/run.sh` does this through `scripts/in-lab.sh --detach`), never as tracked background tasks.
  - Wait with **bounded foreground waits**: `bash scripts/wait-run.sh <run> 540`. Exit 124 means "still running"; call it again.
- **Discovery artifacts** go under `demos/cert-hygiene/runs/_discovery/<stamp>/` (or `<stamp>-<what>/`), are committed, and are never evidence. A `FINDINGS.md` in each records the answer and which config key or file received it.

## How commands reach the lab VM

- Host-side scripts run on macOS from `demos/cert-hygiene/`. `just demo cert-hygiene <verb>` from the repo root dispatches to `demos/cert-hygiene/Justfile`.
- In-VM scripts run through `bash scripts/in-lab.sh [--detach LOG] <demo-relative-script> [args]`, which calls `orb -m cert-hygiene-lab bash -lc 'cd <demo> && bash <script> …'`. OrbStack shows Mac files at the same paths inside the machine, so in-VM scripts run from this working tree and their `runs/` writes land in it.
- One-off in-VM commands: `bash scripts/in-lab.sh lab/shell.sh -c '<command>'`. When the command needs a pipe, loop or `#`, write a script under `runs/_discovery/<stamp>/` or the scratchpad with the Write tool and run that instead.
- The VM never runs git; `scripts/run.sh` records git state on the host.

## Justfile verbs (final state)

| Verb | Task | Does |
| --- | --- | --- |
| `lab-up`, `lab-down`, `sh`, `test` | slice 1 | Machine lifecycle; shell; unit tests (every `lab/tests/test-*.sh`) |
| `reset PROFILE` | 1 | Fresh k3s + Linkerd with the credential profile `PROFILE` |
| `deploy WHAT`, `discover`, `snapshot` | slice 1 | Deploy workloads; record metric discovery data; one collector snapshot |
| `discover-webhooks` | 1 | Discovery: does Linkerd accept the lab-supplied webhook certificates |
| `discover-gates` | 7 | Discovery: healthy restart-gate durations (sets `GATE_TIMEOUT_S`) |
| `discover-admission` | 11 | Discovery: which policy and ServiceProfile resources the validators reject |
| `run SCENARIO`, `run-discovery SCENARIO`, `wait RUN [TIMEOUT]` | slice 1, 8 | Launch an evidence run / a discovery run; wait for it |

## File map

| Path | Responsibility | Task |
| --- | --- | --- |
| `demos/cert-hygiene/lab/profiles/*.env` | Credential profiles (design § 1.1) | 1 |
| `demos/cert-hygiene/lab/lib-webhook.sh` | Lab webhook CA and per-component serving certificates | 1 |
| `demos/cert-hygiene/lab/reset.sh`, `lab/lib-lab.sh` | `reset.sh <profile> <name>`; `load_profile` | 1 |
| `demos/cert-hygiene/lab/discover-webhooks.sh` | Discovery for supplied webhook certificates | 1 |
| `demos/cert-hygiene/lab/lib-evidence.sh` | Core pure helpers; sources the three below | 2, 3 |
| `demos/cert-hygiene/lab/lib-evidence-plan.sh` | `cert_facts`, `credential_state_key`, `credential_plan_walk` | 2 |
| `demos/cert-hygiene/lab/lib-evidence-rules.sh` | Rule table, `credential_plan_for`, `credential_plan_check`, `evaluate_validity`, proxy-log rule | 3, 5 |
| `demos/cert-hygiene/lab/lib-evidence-control.sh` | `control_criteria_check`, `gate_summary` | 3, 7, 8 |
| `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` | `admission_proof_check`, `redact_manifest`, `w_branch_classify`, `k_remaining_check`, `s_hard_endpoint_state` | 11, 12, 14, 17 |
| `demos/cert-hygiene/lab/tests/` | `fixtures.sh` plus `test-evidence.sh`, `test-plan.sh`, `test-rules.sh`, `test-control.sh`, `test-scenarios.sh`, `test-read.sh` | 2–18 |
| `demos/cert-hygiene/lab/collect.sh`, `collect-state.sh`, `collect-logs.sh` | Collector, split by concern | 4, 5 |
| `demos/cert-hygiene/lab/workloads/baseline.yaml`, `lab/probes/*` | Second client `probe-tcp-new-b`; `sample-once.sh` | 6, 7 |
| `demos/cert-hygiene/lab/gates.sh`, `lab/discover-gates.sh` | Restart-stage gates and samples; their discovery | 7 |
| `demos/cert-hygiene/lab/stages.sh` | Stage choreographies shared by control, R, O, S-hard | 8 |
| `demos/cert-hygiene/lab/scenario-common.sh` | `run_scenario`, `run_steps_scenario`, hooks | 4, 8, 9 |
| `demos/cert-hygiene/scripts/run.sh` | `--discovery` flag | 8 |
| `demos/cert-hygiene/scenarios/*.sh` | One file per scenario (table above) | 8–17 |
| `demos/cert-hygiene/lab/admission.sh`, `lab/admission/`, `lab/discover-admission.sh` | W's admission probes and their discovery | 11 |
| `demos/cert-hygiene/lab/scenario-webhook.sh` | W's shared timeline and recovery branches | 12 |
| `demos/cert-hygiene/lab/workloads/identity-canary.yaml` | A's canary for "is identity issuing new-anchor leaves" | 15 |
| `demos/cert-hygiene/scripts/probe-lines.sh`, `pod-series.sh`, `gate-table.sh`, `docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md` | Read-only evidence helpers and write-up instructions for the per-pod layout | 18 |
| `demos/cert-hygiene/runs/<scenario>/<UTC>/` | Committed raw evidence | 19–25 |
| `docs/articles/cert-hygiene/notes/lab-evidence-*.md` | Per-scenario judgement against design § 13 | 26–31 |
| `docs/articles/cert-hygiene/findings.md`, `sources.md`, `README.md` | Reader-facing updates | 32 |

## Tasks

### Phase 1 — harness (discovery allowed, no evidence runs)

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 1 | Credential profiles and supplied webhook certificates | [task-01-profiles.md](task-01-profiles.md) | `reset.sh <profile> <name>`; six profiles; discovery that Linkerd accepts supplied webhook certs (**stop gate**) |
| 2 | Credential facts and the plan walk (TDD) | [task-02-plan-walk.md](task-02-plan-walk.md) | `cert_facts`, `credential_state_key`, `credential_plan_walk`, tested |
| 3 | Validity rule table (TDD) | [task-03-rule-table.md](task-03-rule-table.md) | `evaluate_validity` driven by one per-scenario table; trust invariant replaced by the plan walk |
| 4 | Collector split and credential state | [task-04-credential-state.md](task-04-credential-state.md) | `credentials/<tick>.txt` every tick; `credential-plan.txt` per run |
| 5 | Collector additions | [task-05-collector-additions.md](task-05-collector-additions.md) | `webhooks/`, `controlplane/`, connection metrics, `logs/<label>/pods.txt`, non-vacuous proxy-log rule |
| 6 | Second forced-new-connection client | [task-06-second-client.md](task-06-second-client.md) | `probe-tcp-new-b` meeting the line contract (discovery) |
| 7 | Restart-stage gates | [task-07-gates.md](task-07-gates.md) | `gates.sh`, `gate_summary`; `GATE_TIMEOUT_S` from discovery |
| 8 | Stages and the restart-choreography control | [task-08-control.md](task-08-control.md) | `stages.sh`; control runs R's stages; new control criteria; `run.sh --discovery` |
| 9 | Scenario hooks | [task-09-hooks.md](task-09-hooks.md) | `scenario_fault`, `scenario_post_actions`, `scenario_tick_extra`; `run_steps_scenario`; one discovery smoke run of the control |
| 10 | Scenario R changes | [task-10-issuer-expiry.md](task-10-issuer-expiry.md) | 1800 s window; gated four-stage recovery with the two-pair matrix |
| 11 | W admission probes and their discovery | [task-11-admission.md](task-11-admission.md) | Invalid/valid resources chosen by discovery (**stop gate**); `admission.sh`; `admission_proof_check` |
| 12 | Scenario W | [task-12-webhooks.md](task-12-webhooks.md) | Two W scenarios: staggered expiry, per-tick probes, declared-branch recovery |
| 13 | Scenario O | [task-13-identity-outage.md](task-13-identity-outage.md) | Identity scaled to zero for `OUTAGE_S`; no-restart window, then stages |
| 14 | Scenario K | [task-14-check-threshold.md](task-14-check-threshold.md) | Bracketed 60-day checks; `k_remaining_check` |
| 15 | Scenario A | [task-15-anchor-expiry.md](task-15-anchor-expiry.md) | Anchor expiry; named recovery stages with a canary |
| 16 | Scenario S-staged | [task-16-rotation-staged.md](task-16-rotation-staged.md) | The guide's 11 steps with gates |
| 17 | Scenario S-hard | [task-17-rotation-hard.md](task-17-rotation-hard.md) | One-step swap; per-endpoint stage-1 condition; matrix stages |
| 18 | Evidence-reading helpers and write-up instructions | [task-18-reading-guide.md](task-18-reading-guide.md) | Per-pod probe history tools; reading guide |

### Phase 2 — evidence (no harness changes)

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 19 | Freeze the harness; run the control | [task-19-control-run.md](task-19-control-run.md) | Clean tree; valid control |
| 20 | R, twice | [task-20-r-runs.md](task-20-r-runs.md) | Two valid R runs |
| 21 | W, Ignore and Fail | [task-21-w-runs.md](task-21-w-runs.md) | Two valid W runs |
| 22 | O | [task-22-o-run.md](task-22-o-run.md) | Valid O run |
| 23 | K | [task-23-k-run.md](task-23-k-run.md) | Valid K run |
| 24 | A | [task-24-a-run.md](task-24-a-run.md) | Valid A run |
| 25 | S-staged and S-hard | [task-25-s-runs.md](task-25-s-runs.md) | Two valid S runs |

**Phase 2 rule.** A harness fix found mid-phase means: fix it, commit the harness, confirm a clean tree, re-run the control, and re-run only the scenarios the fix affects. Every run, valid or not, is committed immediately and never edited or deleted. Task 19 Step 1 defines the shared run procedure.

### Phase 3 — write-ups

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 26 | R write-up | [task-26-r-writeup.md](task-26-r-writeup.md) | `notes/lab-evidence-issuer-expiry-rerun.md` |
| 27 | W write-up | [task-27-w-writeup.md](task-27-w-writeup.md) | `notes/lab-evidence-webhook-expiry.md` |
| 28 | O write-up | [task-28-o-writeup.md](task-28-o-writeup.md) | `notes/lab-evidence-identity-outage.md` |
| 29 | K write-up | [task-29-k-writeup.md](task-29-k-writeup.md) | `notes/lab-evidence-check-threshold.md` |
| 30 | A write-up | [task-30-a-writeup.md](task-30-a-writeup.md) | `notes/lab-evidence-anchor-expiry.md` |
| 31 | S write-up | [task-31-s-writeup.md](task-31-s-writeup.md) | `notes/lab-evidence-anchor-rotation.md` |
| 32 | Reader-facing pages | [task-32-reader-pages.md](task-32-reader-pages.md) | `findings.md`, `sources.md`, `README.md` updated under design § 14 |

Tasks are sequential: each consumes earlier tasks' outputs.

## Follow-up, not in this plan

**Scenario V (tap/viz, design § 8)** is optional and needs the user's confirmation before any work starts. It is not planned here. If the user approves it, it needs its own plan task: a Viz install with `--set-file tap.crtPEM=…,tap.keyPEM=…,tap.caBundle=…` and a 15-minute certificate, the APIService status collector (design § 1.4, "APIService status, for V only"), a scenario file, an evidence run and a write-up.
