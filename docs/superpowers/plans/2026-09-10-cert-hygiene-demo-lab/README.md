# Cert-Hygiene Demo Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task lives in its own file in this directory; read this README first, then only your task file.

**Goal:** Build a one-box OrbStack + k3s + Linkerd lab that produces version-pinned raw evidence for scenario #5 (identity issuer expiry) and its negative control, then judge the spec's hypotheses against that evidence.

**Architecture:**
- **Shared `lib/`.** The generic install pieces move out of the SPIFFE demo into `lib/` (certs, k3s, Linkerd). The SPIFFE scripts become thin callers.
- **Cert-hygiene scripts.** A new `demos/cert-hygiene/` runs host-side scripts that drive an OrbStack machine. Inside it, in-VM bash scripts reset k3s, install Linkerd with short-lived credentials, deploy probe workloads, and snapshot evidence on a timeline into committed `runs/` directories.
- **Validity versus outcome.** Harness validity is computed mechanically. Hypothesis outcomes are judged only by a human write-up (Task 10).

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
- Every bash script starts with `set -euo pipefail` and sources `lib/common.sh` (directly, or through `lab/lib-lab.sh`). Keep each file under 300 lines.
- No fallbacks and no mock data outside tests. Fail loudly with a message naming what is missing.
- Scripts **never** evaluate hypotheses H1–H8. They record raw observations. Validity (spec § 5) and the control's § 4.4 criteria are the only things a script judges.
- Evidence directories are written once and never edited. Invalid runs are committed too; `validity.txt` says why they don't count.
- Tool-call rules (for agents executing this plan):
  - Never put `#` characters inside Bash heredocs or multi-line quoted arguments; write files with the Write tool instead.
  - Never use `sed` to write files.
  - Prefer a script file over a complex one-liner.
  - Launch long runs detached (`setsid nohup … &`, which `scripts/in-lab.sh --detach` does), never as tracked background tasks.
- Commit and push at the end of every task, on branch `article/cert-hygiene`. Commit messages start with `cert-hygiene ` and carry **no AI attribution** (no `Co-Authored-By`, no session links, no "Generated with" footer).
- Update `docs/articles/cert-hygiene/README.md` in the **same commit** whenever a task changes what exists or its status.

## How commands reach the lab VM

- Host-side scripts run on macOS from the demo directory. `just demo cert-hygiene <verb>` from the repo root dispatches to `demos/cert-hygiene/Justfile`.
- In-VM scripts run as `orb -m cert-hygiene-lab bash -lc '<cmd>'`. OrbStack shows Mac files at the **same paths** inside machines (https://docs.orbstack.dev/machines/file-sharing), so in-VM scripts run directly from this working tree and their `runs/` writes land in it.
- `scripts/in-lab.sh [--detach LOG] <demo-relative-script> [args]` is the one wrapper for "run this in the VM" (Task 1). The VM never runs git; `scripts/run.sh` records git state on the host (Task 8).

## Justfile verbs (final state)

| Verb | Task | Does |
| --- | --- | --- |
| `lab-up`, `lab-down`, `sh` | 1 | Create or delete the machine; open a shell in it |
| `test` | 4 | Unit tests for `lab/lib-evidence.sh`, in the VM |
| `reset MODE` | 5 | Fresh k3s + Linkerd with `short` or `long` credentials |
| `deploy WHAT`, `discover` | 6 | Deploy `baseline` or `probe-new`; record discovery data |
| `snapshot` | 7 | One full collector snapshot into `.lab-logs/` |
| `run SCENARIO`, `wait RUN` | 8 | Launch a scenario detached; wait for it and print validity |

## File map

| Path | Responsibility | Task |
| --- | --- | --- |
| `demos/cert-hygiene/config.example.env` | All lab settings (VM, versions, lifetimes, intervals, image digests, metric names) | 1, 5, 6 |
| `demos/cert-hygiene/Justfile` | Host verbs (table above) | 1, 4–8 |
| `demos/cert-hygiene/scripts/lab-up.sh`, `lab-down.sh`, `in-lab.sh`, `wait-log.sh` | Machine lifecycle; run a repo script in the VM; wait for a detached log | 1 |
| `demos/cert-hygiene/lab/detach.sh`, `lab/shell.sh` | In-VM detach helper; in-VM shell | 1 |
| `demos/cert-hygiene/lab/refactor-check.sh`, `refactor-cleanup.sh`, `scripts/refactor-compare.sh` | Record and compare the SPIFFE scripts before and after the refactor | 2, 3 |
| `lib/certs.sh`, `lib/k3s.sh`, `lib/linkerd.sh` | Shared install helpers | 3 |
| `demos/spiffe-cross-boundary/cluster/{gen-certs,install-k3s,install-linkerd}.sh` | Thin callers of `lib/` (same paths, same output) | 3 |
| `demos/cert-hygiene/lab/lib-evidence.sh` | Pure functions: durations, cert metadata, leaf-lifetime check, trust invariant, control criteria, validity | 4, 8 |
| `demos/cert-hygiene/lab/tests/` | `assert.sh`, `test-evidence.sh`, `run.sh` | 4, 8 |
| `demos/cert-hygiene/lab/lib-lab.sh` | In-VM environment: sources `lib/*`, config, evidence lib; image pinning and pre-pull | 5 |
| `demos/cert-hygiene/lab/reset.sh`, `lab/resolve-images.sh` | Fresh cluster + credentials (`short` or `long`); pin probe images | 5 |
| `demos/cert-hygiene/lab/workloads/*.yaml`, `lab/probes/*.sh`, `lab/deploy.sh`, `lab/discover.sh` | Namespace, server, probes, restart target, probe-new; probe scripts; render + apply; discovery | 6 |
| `demos/cert-hygiene/lab/collect.sh`, `lab/snapshot-once.sh` | Snapshot functions writing the spec § 3 layout; one-shot exerciser | 7 |
| `demos/cert-hygiene/lab/scenario-common.sh` | Shared timeline: reset → baseline → observe → fault ticks → post-expiry → recover hook → verify → validity | 8 |
| `demos/cert-hygiene/scenarios/00-baseline-control.sh` | Negative control | 8 |
| `demos/cert-hygiene/scripts/run.sh`, `wait-run.sh` | Record git state, launch detached, wait for the verdict | 8 |
| `demos/cert-hygiene/scenarios/05-issuer-expiry.sh` | Issuer expiry + staged recovery | 9 |
| `demos/cert-hygiene/runs/_refactor-check/`, `runs/_discovery/` | Committed verification records (not article evidence) | 2, 3, 6 |
| `demos/cert-hygiene/runs/<scenario>/<UTC>/` | Committed raw evidence | 8, 9 |
| `docs/articles/cert-hygiene/evidence-05-issuer-expiry.md` | Human judgement of H1–H8 against the valid run | 10 |

## Tasks

| # | Task | File | Deliverable |
| --- | --- | --- | --- |
| 1 | Lab machine and host wrappers | [task-01-lab-machine.md](task-01-lab-machine.md) | `just demo cert-hygiene lab-up` yields a VM that sees the working tree |
| 2 | SPIFFE pre-refactor snapshot | [task-02-spiffe-before.md](task-02-spiffe-before.md) | Recorded output of SPIFFE's three cluster scripts before the refactor |
| 3 | Shared `lib/` refactor | [task-03-lib-refactor.md](task-03-lib-refactor.md) | `lib/{certs,k3s,linkerd}.sh`; SPIFFE callers; after-snapshot matches before |
| 4 | Evidence library (TDD) | [task-04-evidence-lib.md](task-04-evidence-lib.md) | `lib-evidence.sh` with passing unit tests in the VM |
| 5 | Lab reset and image pinning | [task-05-reset.md](task-05-reset.md) | `just demo cert-hygiene reset short` gives Linkerd `edge-26.9.1` with a 15m issuer and 5m leaves |
| 6 | Workloads, probes, discovery | [task-06-workloads.md](task-06-workloads.md) | Live probes that meet the line contract; metric names and opaque-port behaviour confirmed (**stop gate**) |
| 7 | Collector | [task-07-collector.md](task-07-collector.md) | `collect.sh` writes a complete, key-free snapshot from the live lab |
| 8 | Orchestration + negative control | [task-08-control.md](task-08-control.md) | Committed `00-baseline-control` run with `evidence_valid=yes` |
| 9 | Scenario #5, issuer expiry | [task-09-issuer-expiry.md](task-09-issuer-expiry.md) | Committed control + `05-issuer-expiry` runs at one harness tree, both `evidence_valid=yes` |
| 10 | Record observations | [task-10-observations.md](task-10-observations.md) | `evidence-05-issuer-expiry.md`: H1–H8 judged with quoted evidence |

Tasks are sequential: each consumes the previous one's outputs.
