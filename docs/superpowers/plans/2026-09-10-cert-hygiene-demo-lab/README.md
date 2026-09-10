# Cert-Hygiene Demo Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task lives in its own file in this directory; read this README first, then only your task file.

**Goal:** Build a one-box OrbStack + k3s + Linkerd lab that produces version-pinned raw evidence for scenario #5 (identity issuer expiry) and its negative control.

**Architecture:**
- **Shared `lib/`.** The generic install pieces move out of the SPIFFE demo into `lib/` (certs, k3s, Linkerd). The SPIFFE scripts become thin callers.
- **Cert-hygiene scripts.** A new `demos/cert-hygiene/` runs host-side scripts that drive an OrbStack machine. Inside it, in-VM bash scripts reset k3s, install Linkerd with short-lived credentials, deploy probe workloads, and snapshot evidence on a timeline into committed `runs/` directories.
- **Validity versus outcome.** Harness validity is computed mechanically. Hypothesis outcomes are never graded by scripts.

**Tech stack:** bash, OrbStack (`orb`), k3s, Linkerd `edge-26.9.1`, smallstep `step` CLI, `openssl`, `jq`, `envsubst`, `shellcheck`, Kubernetes manifests. Probe images: `curlimages/curl`, `alpine/socat`, `busybox`, pinned by digest.

**Spec:** [`docs/superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md`](../../specs/2026-09-10-cert-hygiene-demo-lab-design.md). Executors read both the spec and this plan.

**Source notes (Linkerd behavior, with permalinks):** [`docs/articles/cert-hygiene/linkerd-source-notes.md`](../../../articles/cert-hygiene/linkerd-source-notes.md)

## Global Constraints

- Linkerd for cert-hygiene: `LINKERD_EDGE_VERSION=edge-26.9.1`. Gateway API CRDs: `v1.5.1`, applied with `kubectl apply --server-side`.
- The SPIFFE demo keeps its own pins, `edge-26.7.2` and Gateway API `v1.2.1`. Its documented script paths must not move.
- Lab machine: OrbStack, `ubuntu:24.04`, named `cert-hygiene-lab`, native architecture. **Never pass `-a amd64`.**
- **Never alter any clock.** Expiry comes only from short-lived certificates.
- **Private keys never enter the repo tree.** Lab certificates live in the VM at `$HOME/cert-hygiene-certs/`, which is not a Mac path. Evidence holds certificates only.
- No `linkerd-cni` and no Linkerd Viz in this slice.
- Every bash script starts with `set -euo pipefail` and sources `lib/common.sh` for `log`/`die`/`require_cmd`/`load_config`. Keep each file under 300 lines.
- No fallbacks and no mock data outside tests. Fail loudly with a message naming what is missing.
- Scripts **never** evaluate hypotheses H1–H8. They record raw observations. Validity (spec § 5) is the only thing a script judges.
- Tool-call rules (for agents executing this plan):
  - Never put `#` characters inside Bash heredocs or multi-line quoted arguments; write files with the Write tool instead.
  - Never use `sed` to write files.
  - Prefer a script file over a complex one-liner.
  - Launch long runs detached (`setsid nohup … &`), never as tracked background tasks.
- Commit and push at the end of every task, on branch `article/cert-hygiene`. Commit messages start with `cert-hygiene ` and carry **no AI attribution** (no `Co-Authored-By`, no session links, no "Generated with" footer).
- Update `docs/articles/cert-hygiene/README.md` in the **same commit** whenever a task changes what exists or its status.

## How commands reach the lab VM

- Host-side scripts run on macOS from the demo directory. `just demo cert-hygiene <verb>` from the repo root dispatches to `demos/cert-hygiene/Justfile`.
- In-VM scripts run as `orb -m cert-hygiene-lab bash -lc '<cmd>'`. OrbStack shows Mac files at the **same paths** inside machines (https://docs.orbstack.dev/machines/file-sharing), so in-VM scripts run directly from this working tree and their `runs/` writes land in it.
- `scripts/in-lab.sh <repo-relative-script> [args]` is the one wrapper for "run this in the VM" (Task 1).

## File map

| Path | Responsibility | Task |
| --- | --- | --- |
| `demos/cert-hygiene/config.example.env` | All lab settings (VM, versions, lifetimes, intervals, image digests, metric name) | 1, 5 |
| `demos/cert-hygiene/Justfile` | Host verbs: `lab-up`, `lab-down`, `sh`, `test`, `reset`, `run`, `wait` | 1, 4, 5, 7 |
| `demos/cert-hygiene/scripts/lab-up.sh`, `lab-down.sh`, `in-lab.sh` | Create or delete the OrbStack machine; run a repo script inside it | 1 |
| `demos/cert-hygiene/scripts/run.sh`, `wait-run.sh` | Record git state, launch a scenario detached in the VM, wait for its end marker | 7 |
| `lib/certs.sh` | `ensure_step`, `make_trust_anchor`, `make_issuer` | 3 |
| `lib/k3s.sh` | `install_k3s`, `reset_k3s` | 3 |
| `lib/linkerd.sh` | `ensure_linkerd_cli`, `install_gateway_crds`, `wait_rollouts`, `linkerd_install` | 3 |
| `demos/spiffe-cross-boundary/cluster/{gen-certs,install-k3s,install-linkerd}.sh` | Thin callers of `lib/` (same paths, same output) | 3 |
| `demos/cert-hygiene/lab/lib-lab.sh` | In-VM environment: sources `lib/*` and config, sets `DEMO`, `ROOT`, `CERTS_ROOT` | 4 |
| `demos/cert-hygiene/lab/lib-evidence.sh` | Pure functions: durations, cert metadata, leaf-lifetime check, trust invariant, validity | 4 |
| `demos/cert-hygiene/lab/tests/` | `assert.sh`, `test-evidence.sh`, `run.sh` (unit tests for `lib-evidence.sh`) | 4 |
| `demos/cert-hygiene/lab/reset.sh` | Fresh k3s + certs (`short` or `long` mode) + Linkerd | 5 |
| `demos/cert-hygiene/lab/workloads/*.yaml`, `lab/probes/*.sh`, `lab/deploy.sh` | Namespace, server, probes, restart target, probe-new; probe scripts; render + apply | 5 |
| `demos/cert-hygiene/lab/collect.sh` | Snapshot functions writing the spec § 3 evidence layout | 6 |
| `demos/cert-hygiene/lab/scenario-common.sh` | Shared phases: reset → baseline → observe → fault ticks → post-expiry → final collect → validity | 7 |
| `demos/cert-hygiene/scenarios/00-baseline-control.sh`, `05-issuer-expiry.sh` | Scenario entry points | 7, 8 |
| `demos/cert-hygiene/runs/<scenario>/<UTC>/` | Committed raw evidence | 2, 7, 8 |
| `docs/articles/cert-hygiene/evidence-05-issuer-expiry.md` | Human judgement of H1–H8 against a valid run | 9 |

## Tasks

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 1 | Lab machine and host wrappers | [task-01-lab-machine.md](task-01-lab-machine.md) | `just demo cert-hygiene lab-up` yields a VM that sees the working tree |
| 2 | SPIFFE pre-refactor snapshot | [task-02-spiffe-before.md](task-02-spiffe-before.md) | Recorded output of SPIFFE's three cluster scripts before the refactor |
| 3 | Shared `lib/` refactor | [task-03-lib-refactor.md](task-03-lib-refactor.md) | `lib/{certs,k3s,linkerd}.sh`; SPIFFE callers; after-snapshot matches before |
| 4 | Evidence library (TDD) | [task-04-evidence-lib.md](task-04-evidence-lib.md) | `lib-evidence.sh` with passing unit tests in the VM |
| 5 | Lab reset, workloads, probes | [task-05-workloads.md](task-05-workloads.md) | Lab with live probes; open questions (metric names, opaque ports) answered and recorded |
| 6 | Collector | [task-06-collector.md](task-06-collector.md) | `collect.sh` writes a complete, key-free snapshot from the live lab |
| 7 | Orchestration + negative control | [task-07-control.md](task-07-control.md) | Committed `00-baseline-control` run with `evidence_valid=yes` |
| 8 | Scenario #5 issuer expiry | [task-08-issuer-expiry.md](task-08-issuer-expiry.md) | Committed `05-issuer-expiry` run with `evidence_valid=yes` |
| 9 | Record observations | [task-09-observations.md](task-09-observations.md) | Per-hypothesis write-up citing the run directory |

Tasks are sequential: each consumes the previous one's outputs.
