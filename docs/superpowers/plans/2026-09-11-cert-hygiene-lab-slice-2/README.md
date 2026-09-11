# Cert-Hygiene Lab, Slice 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task lives in its own file in this directory; read this README first, then only your task file.

**Status:** revised after the [plan review](../../reviews/2026-09-11-cert-hygiene-lab-slice-2-plan-review.md). Every finding in it (C1, I1–I7, M1–M15) and the controller's rulings are applied. The plan also went through a pre-flight conflict scan against the current harness, and the controller's rulings on that scan have been applied to the task files.

**Goal:** Generalise the slice-1 lab harness and use it to record evidence, in three phases.
- Generalise the harness: credential profiles, planned credential transitions, richer collection, a second client, gated restart stages, and scenario hooks.
- Record valid evidence for scenarios R, W, O, K, A and S, all at one harness tree.
- Judge their hypotheses in per-scenario write-ups before any reader-facing page changes.

**Architecture:**
- **Harness (Phase 1).** Bash in `demos/cert-hygiene/`.
  - Credential lifetimes move from `config.example.env` into `lab/profiles/<profile>.env`.
  - The collector gains credential, webhook and control-plane state per tick.
  - The evidence library (`lab/lib-evidence*.sh`, pure, unit-tested) gains a credential-plan walk and one validity rule table keyed by scenario name.
  - Restart stages are gated (`lab/gates.sh`) and composed into choreographies (`lab/stages.sh`).
  - `run_scenario` gains three hooks, and a second entry point, `run_steps_scenario`, serves the step-driven scenarios (K, S-staged).
  - Before the freeze, every new scenario, and R, runs once as a discovery run (Task 19).
- **Evidence (Phase 2).** No harness changes. Control first, then every scenario at the same harness tree, each run committed the moment it finishes.
- **Write-ups (Phase 3).** Hypotheses are judged only in `docs/articles/cert-hygiene/notes/`. Reader-facing pages change last, and only where design § 13 is met.

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

One more profile, `webhook-long`, is for Task 1's discovery only.

## Design-conformant choices recorded here

These readings of the design are settled; none needs a further decision.

| Point | Choice | Where |
| --- | --- | --- |
| Post-expiry windows | The control, R and A: 1800 s after T_mark (R's window; the control mirrors it). **W: 600 s after T3, the last webhook expiry** (design § 3: "after T3 plus the post-expiry window"; controller ruling I7). Webhook effects are immediate on each admission call, so about 20 per-tick probe rounds after the last expiry are enough. O: `OUTAGE_S` (900 s). S-hard: 0, because its stage 1 is condition-driven. K and S-staged are step-driven and have none. | Tasks 8, 9, 12, 13, 17 |
| W's credential plan | One webhook change across ticks, `A/I1/W1 → A/I1/W2`, as design § 1.3's example states (controller-confirmed). The state between the plain upgrade and an explicit re-supply is recorded in non-tick files and classified by a branch rule declared in advance. The `w-plain-render` rule guarantees the plain render really ran. | Tasks 3, 12 |
| W's phase directories | `post-NNNN`, not the design's `post-NNN`: the seconds after T1 exceed 999. | Task 12 |
| Gates when a leaf is not predicted | No slice-2 stage predicts that a restarted pod can't get a leaf, so every gate requires all five conditions. Every poll records the certificate state, and a timeout leaves the cell unclassified. | Task 7 |
| K's "that step is repeated" | The repeat is a fresh run. An in-run repeat would sign a third, undeclared issuer. | Tasks 14, 24 |
| S-hard's stage-1 condition | A successful renewal also meets it (`renewed`), so S4 stays falsifiable. The S write-up must establish which anchor each renewed leaf chains to. | Tasks 17, 32 |
| Discovery runs | `scripts/run.sh --discovery [--short]` writes `discovery.txt`, and such a run never reads `evidence_valid=yes`. `--short` lowers the observation windows for discovery only. Evidence runs refuse it in `run.sh`, and again in the scenario if `discovery.txt` appears outside `runs/_discovery/`. | Tasks 3, 8, 9, 19 |

## Global Constraints

- Everything in slice 1's Global Constraints still holds:
  - Linkerd for cert-hygiene: `LINKERD_EDGE_VERSION=edge-26.9.1`. Gateway API CRDs `v1.5.1`, applied with `kubectl apply --server-side`.
  - Lab machine: OrbStack, `ubuntu:24.04`, named `cert-hygiene-lab`, native architecture. Never pass `-a amd64`.
  - **Never alter any clock.** Expiry comes only from short-lived certificates.
  - **Private keys never enter the repo tree.** Lab keys live in the VM under `$HOME/cert-hygiene-certs/`, and evidence holds certificates only. `assert_no_keys` must pass on every run. It searches for PEM key text, and it decodes every base64 run of 40 or more characters, including base64 nested inside base64 (the `linkerd-config-overrides` shape), looking for a private key (Task 12, unit-tested). Rendered manifests are redacted by the same nested test before they are written to evidence (Task 12).
  - Every bash script starts with `set -euo pipefail` and sources `lib/common.sh`, directly or through `lab/lib-lab.sh`. Sourced libraries (`lib-*.sh`, `collect*.sh`, `gates.sh`, `stages.sh`, `admission.sh`, `scenario-*.sh`) are sourced, never executed.
  - Keep every code file under 300 lines. This plan splits `lib-evidence.sh` (Tasks 2–3), `collect.sh` (Task 4) and `scenario-common.sh` (Tasks 7–9) for that reason.
  - No fallbacks and no mock data outside tests. Fail loudly with a message naming what is missing. A collector read that fails during a run is *recorded*, never fatal: after an expiry, failing commands are the observation.
  - Scripts **never** judge hypotheses. Beyond recording observations, they judge only these things, each defined in this plan:
    - evidence validity;
    - the control's criteria;
    - restart-gate conditions;
    - W's recovery branch (a declared, mechanical classification);
    - S-hard's stage-1 condition;
    - whether A's canary is proven.
  - Evidence directories are written once and never edited. Invalid runs are committed too; `validity.txt` says why they don't count.
- **Commit and push at the end of every task**, on branch `article/cert-hygiene`. Commit messages start with `cert-hygiene ` and carry **no AI attribution**: no `Co-Authored-By`, no session links, no "Generated with" footer.
- **Update `docs/articles/cert-hygiene/README.md` in the same commit** whenever a task changes what exists or its status. Its "Status" section is a bullet list; each task says which bullet to change.
- **Tool-call rules for executing agents:**
  - Never put `#` characters inside Bash heredocs or multi-line quoted arguments. Write files, commit messages and FINDINGS files with the Write tool.
  - Never use `sed` to write files (read-only `sed -n` is allowed; prefer the Read tool).
  - Prefer a script file over a complex one-liner.
  - Launch long runs detached (`scripts/run.sh` does this through `scripts/in-lab.sh --detach`), never as tracked background tasks.
  - Wait with **bounded foreground waits**: `bash scripts/wait-run.sh <run> 540`. Exit 124 means "still running"; call it again.
- **Discovery artifacts** go under `demos/cert-hygiene/runs/_discovery/<stamp>/` (or `<stamp>-<what>/`). They are committed, and they are never evidence. Each has a `FINDINGS.md` recording the answer and which config key or file received it. Discovery runs of scenarios carry `discovery.txt`, and their `validity.txt` always says `evidence_valid=no`.

## How commands reach the lab VM

- Host-side scripts run on macOS from `demos/cert-hygiene/`. `just demo cert-hygiene <verb>` from the repo root dispatches to `demos/cert-hygiene/Justfile`.
- In-VM scripts run through `bash scripts/in-lab.sh [--detach LOG] <demo-relative-script> [args]`, which calls `orb -m cert-hygiene-lab bash -lc 'cd <demo> && bash <script> …'`. OrbStack shows Mac files at the same paths inside the machine, so in-VM scripts run from this working tree and their `runs/` writes land in it.
- One-off in-VM commands: `bash scripts/in-lab.sh lab/shell.sh -c '<command>'`. When the command needs a pipe, a loop or a `#`, write a script with the Write tool instead (under `.lab-logs/`, which is git-ignored, or under `runs/_discovery/<stamp>/`) and run that.
- The VM never runs git; `scripts/run.sh` records git state on the host.

## Justfile verbs (final state)

| Verb | Task | Does |
| --- | --- | --- |
| `lab-up`, `lab-down`, `sh`, `test` | slice 1 | Machine lifecycle; shell; unit tests (every `lab/tests/test-*.sh`) |
| `reset PROFILE` | 1 | Fresh k3s + Linkerd with the credential profile `PROFILE` |
| `deploy WHAT`, `discover`, `snapshot` | slice 1 | Deploy workloads; record metric discovery data; one collector snapshot |
| `discover-webhooks` | 1 | Discovery: does Linkerd accept the lab-supplied webhook certificates; does the Fail render reach all three webhooks |
| `discover-gates` | 7 | Discovery: healthy restart-gate durations (sets `GATE_TIMEOUT_S`) |
| `discover-admission` | 11 | Discovery: which policy and ServiceProfile resources the validators reject |
| `run SCENARIO`, `wait RUN [TIMEOUT]` | slice 1 | Launch an evidence run; wait for it |
| `run-discovery SCENARIO`, `run-discovery-short SCENARIO` | 8 | Launch a discovery run, optionally with the discovery-only short windows |

## File map

| Path | Responsibility | Task |
| --- | --- | --- |
| `demos/cert-hygiene/lab/profiles/*.env` | Credential profiles (design § 1.1); `webhook-long` is for discovery only | 1 |
| `demos/cert-hygiene/lab/lib-webhook.sh` | Lab webhook CA and per-component serving certificates | 1 |
| `demos/cert-hygiene/lab/reset.sh`, `lab/lib-lab.sh` | `reset.sh <profile> <name>`; `load_profile` | 1 |
| `demos/cert-hygiene/lab/discover-webhooks.sh` | Discovery for supplied webhook certificates and the Fail render | 1 |
| `demos/cert-hygiene/lab/lib-evidence.sh` | Core pure helpers; sources the four below | 2, 3, 11 |
| `demos/cert-hygiene/lab/lib-evidence-plan.sh` | `cert_facts`, `credential_state_key`, `credential_plan_walk` | 2 |
| `demos/cert-hygiene/lab/lib-evidence-rules.sh` | Rule table (including `w-plain-render` and the discovery rule), `credential_plan_for`, `credential_plan_check`, `evaluate_validity`, proxy-log rule | 3, 5 |
| `demos/cert-hygiene/lab/lib-evidence-control.sh` | `control_criteria_check`, `gate_summary` | 3, 7, 8 |
| `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` | `admission_proof_check`, `redact_manifest`, `w_branch_classify`, `b64_key_hits`, `k_remaining_check`, `pod_section`, `s_hard_endpoint_state` | 11, 12, 14, 17 |
| `demos/cert-hygiene/lab/tests/` | `fixtures.sh` plus `test-evidence.sh`, `test-plan.sh`, `test-rules.sh`, `test-control.sh`, `test-scenarios.sh`, `test-read.sh` | 2–18 |
| `demos/cert-hygiene/lab/collect.sh`, `collect-state.sh`, `collect-logs.sh` | Collector, split by concern; `assert_no_keys` with the decode scan | 4, 5, 9, 12 |
| `demos/cert-hygiene/lab/workloads/baseline.yaml`, `lab/probes/*` | Second client `probe-tcp-new-b`; `sample-once.sh` | 6, 7 |
| `demos/cert-hygiene/lab/gates.sh`, `lab/discover-gates.sh` | Restart-stage gates and samples (records in `gates/`, restart commands in `restarts/`); their discovery | 7 |
| `demos/cert-hygiene/lab/stages.sh` | Stage choreographies shared by the control, R, O and S-hard | 8 |
| `demos/cert-hygiene/lab/scenario-common.sh` | `run_scenario`, `run_steps_scenario`, hooks, `_discovery_setup` | 4, 8, 9 |
| `demos/cert-hygiene/scripts/run.sh` | `--discovery`, `--short` | 8 |
| `demos/cert-hygiene/scenarios/*.sh` | One file per scenario (table above) | 8–17 |
| `demos/cert-hygiene/lab/admission.sh`, `lab/admission/`, `lab/discover-admission.sh` | W's admission probes and their discovery | 11 |
| `demos/cert-hygiene/lab/scenario-webhook.sh` | W's shared timeline and recovery branches | 12 |
| `demos/cert-hygiene/lab/workloads/identity-canary.yaml` | A's canary for "is identity issuing new-anchor leaves" | 15 |
| `demos/cert-hygiene/scripts/probe-lines.sh`, `pod-series.sh`, `gate-table.sh`, `docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md` | Read-only evidence helpers and write-up instructions for the per-pod layout | 18 |
| `demos/cert-hygiene/runs/_discovery/` | Discovery records (never evidence): webhooks, second client, gates, admission, timestamps, one control discovery run and eight scenario discovery runs (the six new scenarios, with W's two files, and R) | 1, 6, 7, 9, 11, 18, 19 |
| `demos/cert-hygiene/runs/<scenario>/<UTC>/` | Committed raw evidence | 20–26 |
| `docs/articles/cert-hygiene/notes/lab-evidence-*.md` | Per-scenario judgement against design § 13 | 27–32 |
| `docs/articles/cert-hygiene/findings.md`, `sources.md`, `README.md` | Reader-facing updates | 33 |

## Tasks

### Phase 1 — harness (discovery allowed, no evidence runs)

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 1 | Credential profiles and supplied webhook certificates | [task-01-profiles.md](task-01-profiles.md) | `reset.sh <profile> <name>`; seven profiles; discovery that Linkerd accepts supplied webhook certs and that the Fail render reaches all three (**stop gate**) |
| 2 | Credential facts and the plan walk (TDD) | [task-02-plan-walk.md](task-02-plan-walk.md) | `cert_facts`, `credential_state_key`, `credential_plan_walk`, tested |
| 3 | Validity rule table (TDD) | [task-03-rule-table.md](task-03-rule-table.md) | `evaluate_validity` driven by one per-scenario table, with the `w-plain-render` and discovery rules; trust invariant replaced by the plan walk |
| 4 | Collector split and credential state | [task-04-credential-state.md](task-04-credential-state.md) | `credentials/<tick>.txt` every tick; `credential-plan.txt` per run |
| 5 | Collector additions | [task-05-collector-additions.md](task-05-collector-additions.md) | `webhooks/`, `controlplane/`, per-tick `trust/`, connection metrics, `logs/<label>/pods.txt`, non-vacuous proxy-log rule |
| 6 | Second forced-new-connection client | [task-06-second-client.md](task-06-second-client.md) | `probe-tcp-new-b` meeting the line contract (discovery) |
| 7 | Restart-stage gates | [task-07-gates.md](task-07-gates.md) | `gates.sh`, `gate_summary`; `GATE_TIMEOUT_S` from discovery |
| 8 | Stages and the restart-choreography control | [task-08-control.md](task-08-control.md) | `stages.sh`; control runs R's stages; new control criteria; `run.sh --discovery [--short]` |
| 9 | Scenario hooks | [task-09-hooks.md](task-09-hooks.md) | `scenario_fault`, `scenario_post_actions`, `scenario_tick_extra`, `scenario_post_window_end`; `run_steps_scenario`; discovery setup; one discovery smoke run of the control |
| 10 | Scenario R changes | [task-10-issuer-expiry.md](task-10-issuer-expiry.md) | 1800 s window; gated four-stage recovery with the two-pair matrix |
| 11 | W admission probes and their discovery | [task-11-admission.md](task-11-admission.md) | Invalid/valid resources chosen by discovery (**stop gate**); `admission.sh`; `admission_proof_check` |
| 12 | Scenario W | [task-12-webhooks.md](task-12-webhooks.md) | Two W scenarios: staggered expiry, per-tick probes, recovery after T3 + 600 s, declared-branch recovery, key decode scan |
| 13 | Scenario O | [task-13-identity-outage.md](task-13-identity-outage.md) | Identity scaled to zero for `OUTAGE_S`; no-restart window, then stages |
| 14 | Scenario K | [task-14-check-threshold.md](task-14-check-threshold.md) | Bracketed 60-day checks; `k_remaining_check` |
| 15 | Scenario A | [task-15-anchor-expiry.md](task-15-anchor-expiry.md) | Anchor expiry; named recovery stages with a proven canary |
| 16 | Scenario S-staged | [task-16-rotation-staged.md](task-16-rotation-staged.md) | The guide's 11 steps with gates |
| 17 | Scenario S-hard | [task-17-rotation-hard.md](task-17-rotation-hard.md) | One-step swap; per-endpoint stage-1 condition; matrix stages |
| 18 | Evidence-reading helpers and write-up instructions | [task-18-reading-guide.md](task-18-reading-guide.md) | Per-pod probe history tools; reading guide; timestamp-zone discovery |
| 19 | Discovery runs of the new scenarios, and of R | [task-19-discovery-runs.md](task-19-discovery-runs.md) | Each new scenario and R run once (eight runs), short windows, Phase 2 sanity checks applied, harness fixed before the freeze |

### Phase 2 — evidence (no harness changes)

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 20 | Freeze the harness; run the control | [task-20-control-run.md](task-20-control-run.md) | Clean tree; valid control |
| 21 | R, twice | [task-21-r-runs.md](task-21-r-runs.md) | Two valid R runs |
| 22 | W, Ignore and Fail | [task-22-w-runs.md](task-22-w-runs.md) | Two valid W runs |
| 23 | O | [task-23-o-run.md](task-23-o-run.md) | Valid O run |
| 24 | K | [task-24-k-run.md](task-24-k-run.md) | Valid K run |
| 25 | A | [task-25-a-run.md](task-25-a-run.md) | Valid A run |
| 26 | S-staged and S-hard | [task-26-s-runs.md](task-26-s-runs.md) | Two valid S runs |

**Phase 2 rule.** A harness fix found mid-phase means:
1. Fix it and commit the harness.
2. Confirm a clean tree.
3. Re-run the control.
4. Re-run only the scenarios the fix affects.

Every run, valid or not, is committed immediately and never edited or deleted. Task 20 Step 1 defines the shared run procedure; Phase 2 never passes `--discovery` or `--short`.

### Phase 3 — write-ups

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 27 | R write-up | [task-27-r-writeup.md](task-27-r-writeup.md) | `notes/lab-evidence-issuer-expiry-rerun.md` |
| 28 | W write-up | [task-28-w-writeup.md](task-28-w-writeup.md) | `notes/lab-evidence-webhook-expiry.md` |
| 29 | O write-up | [task-29-o-writeup.md](task-29-o-writeup.md) | `notes/lab-evidence-identity-outage.md` |
| 30 | K write-up | [task-30-k-writeup.md](task-30-k-writeup.md) | `notes/lab-evidence-check-threshold.md` |
| 31 | A write-up | [task-31-a-writeup.md](task-31-a-writeup.md) | `notes/lab-evidence-anchor-expiry.md` |
| 32 | S write-up | [task-32-s-writeup.md](task-32-s-writeup.md) | `notes/lab-evidence-anchor-rotation.md` |
| 33 | Reader-facing pages | [task-33-reader-pages.md](task-33-reader-pages.md) | `findings.md`, `sources.md`, `README.md` updated under design § 14 |

Tasks are sequential: each consumes earlier tasks' outputs. Each write-up task also updates the article README's status in its own commit.

## Follow-up, not in this plan

**Scenario V (tap/viz, design § 8)** is optional and needs the user's confirmation before any work starts. It is not planned here. If the user approves it, it needs its own plan task:
- a Viz install with `--set-file tap.crtPEM=…,tap.keyPEM=…,tap.caBundle=…` and a 15-minute certificate;
- the APIService status collector (design § 1.4, "APIService status, for V only");
- a scenario file;
- a discovery run, an evidence run and a write-up.
