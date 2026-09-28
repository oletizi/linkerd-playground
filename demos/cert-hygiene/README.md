# The cert-hygiene lab

A throwaway Kubernetes cluster that breaks Linkerd's certificates on purpose, records everything that happens, and decides for itself whether the recording counts as evidence.

It exists to answer questions about certificate failures with transcripts rather than inference — what the API server actually says, what `linkerd check` actually prints, what keeps working and for how long. The findings it produced are written up in [`docs/articles/cert-hygiene/`](../../docs/articles/cert-hygiene/); this page is about running it.

**Everything happens inside a disposable OrbStack VM.** The lab installs k3s and Linkerd there, mints its own certificate authorities, and deletes the machine when you are done. It never touches your kubeconfig, your clusters, or your clock.

## What you need

On the Mac host:

- [OrbStack](https://orbstack.dev/) — the `orb` command must be on your `PATH`
- [`just`](https://github.com/casey/just) — the recipes below are `just` targets
- `git`, `shasum`, `perl` — `shasum` and `perl` ship with macOS

Inside the VM, everything else is installed for you on first use: `curl`, `jq`, `openssl`, `gettext-base`, `shellcheck` by `lab-up`, then the `linkerd` CLI and the [smallstep](https://smallstep.com/docs/step-cli/) `step` CLI on the first `reset`.

Two things the lab checks rather than assumes, because both make every timing it records meaningless:

- **The VM must match your host's architecture.** An emulated amd64 guest on Apple Silicon is unusably slow. `lab-up` refuses to continue if the architecture differs.
- **The VM must see this working tree at the same path.** The lab runs straight from your checkout through OrbStack's file sharing, rather than copying itself in. `lab-up` proves this before doing anything else.

Defaults are 4 CPUs, 6 GB of RAM and a 40 GB disk. Override them in `config.local.env` (see [Configuration](#configuration)).

## Quick start

Run these from the repository root.

```bash
just demo cert-hygiene lab-up                       # create the VM, install packages (a few minutes)
just demo cert-hygiene run 40-webhook-unavailable-ignore
```

The `run` recipe launches the scenario **detached inside the VM** and prints the run directory it is writing to. It returns immediately; the scenario keeps going. Follow it with:

```bash
just demo cert-hygiene wait runs/40-webhook-unavailable-ignore/<stamp> 1200
```

which blocks until the run finishes, then prints the tail of its timeline and its validity verdict. That scenario takes about fifteen minutes and is the cheapest one that produces a real finding.

When you are finished:

```bash
just demo cert-hygiene lab-down                     # delete the VM and the keys inside it
```

The VM is disposable by design. Deleting it costs nothing except the few minutes `lab-up` takes next time.

## The scenarios

Each one resets the cluster to a credential profile, breaks something, watches, and where there is a documented recovery procedure, follows it. Durations are approximate — most of the time is spent waiting for a certificate to expire, and each run prints its own timeline as it goes.

| Scenario | What it does | Roughly |
| --- | --- | --- |
| `00-baseline-control` | Breaks nothing. Same timeline and restart choreography as the issuer-expiry run, so the two can be compared. Required before any timed scenario counts as evidence. | 1 h |
| `05-issuer-expiry` | A 15-minute identity issuer expires under a long-lived anchor, then is replaced. | 1 h |
| `02-webhook-expiry-ignore` | Three webhook serving certificates expire ten minutes apart, under Linkerd's default fail-open policy. Then the API server is forced to reconnect. | 1 h |
| `02-webhook-expiry-fail` | The same, fail-closed. | 1 h |
| `09-identity-outage` | The identity service is scaled to zero for fifteen minutes while workload certificates expire under it. | 45 m |
| `06-anchor-expiry` | A 20-minute trust anchor expires beneath a longer-lived issuer, then both are replaced. | 1 h |
| `07-anchor-rotation-staged` | Linkerd's documented eleven-step trust-anchor rotation, with the bundle overlap. Nothing should break. | 1 h |
| `08-anchor-rotation-hard` | The anchor and issuer replaced in one step, without the overlap — why the staged procedure exists. | 1 h |
| `30-tap-expiry` | The tap API server's certificate expires, then its pod is restarted to force a new connection. | 50 m |
| `20-check-threshold` | Measures where `linkerd check`'s 60-day issuer warning actually starts. Nothing expires. Accepts an issuer lifetime as an argument. | 5 m |
| `40-webhook-unavailable-ignore` | A webhook's pods are scaled to zero while its certificate stays perfectly valid, fail-open. | 15 m |
| `40-webhook-unavailable-fail` | The same, fail-closed. | 15 m |
| `41-webhook-algorithm` | A webhook is given a certificate that is time-valid and correctly chained but signed with SHA-1, which the API server refuses. | 20 m |

The last four break nothing's dates. They exist so the findings can distinguish "the certificate expired" from "the certificate is fine and something else is wrong" — see [`notes/lab-evidence-not-expiry.md`](../../docs/articles/cert-hygiene/notes/lab-evidence-not-expiry.md).

Only one scenario can run at a time; there is one cluster.

## How a run works

Every scenario follows the same shape:

1. **Reset** — a fresh k3s cluster, Linkerd installed with credentials minted to the scenario's profile, lab workloads deployed, traffic probes started.
2. **Baseline** — probes prove the thing about to break currently works. A run whose baseline never worked proves nothing, so this is checked mechanically.
3. **The fault** — whatever the scenario exists to cause, at a recorded moment the run calls `T_mark`.
4. **Observation** — a *tick* every 30 seconds, each writing a complete snapshot: certificates, pods, control plane, checks, metrics, trust state, and whatever the scenario adds. Traffic probes run every 2 seconds throughout.
5. **Recovery** — where Linkerd documents a procedure, the run follows it and records whether it worked. Where there is none, the run says so.

Timings come from `config.example.env`; each scenario's own windows are named there with the scenario they belong to.

## What a run records

Every run is a directory under `runs/<scenario>/<UTC stamp>/`. A typical one holds 900–1,500 files:

| | |
| --- | --- |
| `timeline.log` | Every marker and tick, with UTC timestamps. Read this first. |
| `validity.txt` | `evidence_valid=yes`, or `no` with a reason per line. |
| `versions.txt` | Linkerd and Kubernetes versions, and every config value the run used. |
| `git-state.txt` | The hash of the harness that produced the run, and whether the tree was dirty. |
| `checks/` | Complete `linkerd check` and `linkerd check --proxy` transcripts per tick, with exit status. |
| `certs/`, `credentials/`, `secrets/`, `trust/` | Certificate state per tick — public material only. |
| `probes/` | Traffic probe logs: HTTP, new TCP connections, and a long-lived stream. |
| `pods/`, `controlplane/` | Pod and Deployment state per tick, including identities and restart counts. |
| `logs/` | Control-plane and proxy logs, plus the k3s journal. |
| `admission/` | For webhook scenarios: every admission attempt, its exact response, and the object it produced. |

Scenario-specific directories appear alongside these — `swap/` and `timevalidity/` for the algorithm scenario, `reconnect/` where a run forces the API server onto a new connection, and so on.

## What makes a run evidence

A recorded run is not automatically evidence. Each scenario has a list of **validity rules**, and `validity.txt` is written from them at the end of the run:

- **Baseline rules** — the probe worked before the fault, so its failure afterwards means something.
- **Recovery rules** — where a scenario restores something, it worked again afterwards.
- **`control-at-tree`** — for timed scenarios, a valid `00-baseline-control` run exists recorded at *the same harness tree hash*. Change any harness file and the hash changes, so the control has to be re-run before the comparison holds.
- **Scenario-specific rules** — for instance the algorithm scenario requires its refused certificate to be provably time-valid at every tick, since otherwise the run cannot be told apart from an expiry.

Two things the rules deliberately do **not** do:

- **They never judge a hypothesis.** A rule decides whether a run is admissible. Whether the thing being tested actually happened is decided by a person reading the artifacts, in a write-up. No scenario refuses to produce a run in which its own hypothesis turns out false.
- **They never get relaxed to make a run pass.** A failing rule is a finding about the run.

Recorded runs are also **written once**. Nothing edits a file inside a run after the run wrote it.

## Where the recordings live

Runs are published to object storage behind a CDN and attached to a GitHub release. Only a **manifest** is committed here — one file per run listing every path with its size and SHA-256 — so cloning the repository stays cheap.

From the repository root:

```bash
bash tools/evidence.sh runs                                    # every run this repo has a manifest for
bash tools/evidence.sh cat runs/41-webhook-algorithm/<stamp> timeline.log
bash tools/evidence.sh fetch runs/41-webhook-algorithm/<stamp> /tmp/run
```

`cat` prints one recorded file; `fetch` downloads a whole run in one request and verifies every file against the committed manifest before handing it to you. Both read through the CDN. **Do not read the bucket's API directly** — it is rate-limited, and the CDN serves repeat reads from cache without touching the bucket at all.

You do not need any credentials to read. Publishing needs `rclone` and `gh` and a write-only key, and is only for whoever is adding runs.

## Credential profiles

A profile is the set of certificate lifetimes a scenario resets to, in `lab/profiles/<name>.env`. It declares the trust anchor, issuer, workload leaf, and where relevant the webhook and tap certificate lifetimes.

Profiles are how a scenario gets something to expire in minutes instead of months. `issuer-short.env` mints a 15-minute issuer under a 720-hour anchor; `anchor-short.env` inverts it with a 20-minute anchor under a 120-minute issuer; `long.env` keeps the anchor and issuer long-lived so that neither expires during a run.

Every profile sets a 5-minute workload leaf. That is deliberate and is not a fault being injected: proxies refresh their own certificates well before expiry, so a short leaf makes ordinary renewal visible in the recordings, and makes a *failure* to renew visible within minutes rather than hours.

`lab/profiles/` is the authority for these numbers. Do not take a lifetime from a neighbouring experiment — the profiles differ deliberately, and several of them differ in ways that matter.

## Configuration

`config.example.env` is committed and documents every setting. To change anything, copy it:

```bash
cp demos/cert-hygiene/config.example.env demos/cert-hygiene/config.local.env
```

`config.local.env` is git-ignored and overrides the example. It covers the VM's size and name, the Linkerd and Gateway API versions, every observation window, the restart-stage gate timings, and the probe images — which are **pinned by digest**, so a scenario cannot silently change behaviour because an upstream `:latest` moved.

One caveat if you are producing evidence rather than just watching: the harness records whether your tree was dirty, and a local override file makes it dirty. A run recorded that way is marked invalid. That is deliberate — it is how the lab refuses to compare runs made with different settings.

## Discovery runs

A discovery run answers a question about the lab itself: does this cluster even serve a lab-supplied certificate, how long do healthy restarts take, what does this tool actually print.

```bash
just demo cert-hygiene run-discovery 41-webhook-algorithm
just demo cert-hygiene run-discovery-short 41-webhook-algorithm    # shortened windows
```

Discovery runs land under `runs/_discovery/`, carry a `discovery.txt` marker, and are **never evidence** — `validity.txt` says so explicitly. `--short` shortens every observation window and is discovery-only; evidence runs refuse it.

There are also several targeted discovery recipes that answer one question without running a scenario: `discover`, `discover-webhooks`, `discover-gates`, `discover-admission`, `discover-tap`.

## Safety

- **Everything is inside the disposable VM.** The lab has no access to any cluster but its own k3s, and `lab-down` deletes the machine and the keys in it.
- **Clocks are never altered.** Every expiry in this lab is a genuinely short-lived certificate, not a time shift. A shifted clock would corrupt unrelated cluster components and make the recordings worthless.
- **Private keys never enter the repository.** They are minted inside the VM under `$HOME/cert-hygiene-certs`, outside the working tree. Before any run directory is committed, a guard scans it for PEM key text *and* for base64 that decodes to key material through up to three layers:

  ```bash
  just demo cert-hygiene key-guard runs/<scenario>/<stamp>
  ```

  It fails closed: it exits non-zero if it finds anything, and also if any file under the directory cannot be read.

## Tests

```bash
just demo cert-hygiene test
```

Eleven suites, run inside the VM, covering the evidence helpers — the validity rules, the gate tables, the collectors, the credential-plan checks and the key scan. They are unit tests with fixtures; they do not need a cluster.

They must run in the VM. On the macOS host several fail on BSD tool behaviour — `date -d`, `head -n -1` — which is not a defect.

## Other useful recipes

| Recipe | What it does |
| --- | --- |
| `sh` | A shell inside the VM, in this directory. |
| `reset PROFILE` | Fresh k3s and Linkerd at a profile, without running a scenario. Useful for poking at a state by hand. |
| `deploy WHAT` | Deploy the lab workloads (`baseline` or `probe-new`) into the current cluster. |
| `snapshot` | One complete state snapshot of the current cluster into `.lab-logs/`. Not evidence. |
| `wait RUN TIMEOUT` | Block until a run finishes; print its timeline tail and verdict. |

`scripts/` also holds readers for recorded runs — `probe-lines.sh`, `pod-series.sh`, `gate-table.sh` — which turn a run's raw files into something you can scan.

## When something goes wrong

**The scenario is still running and you want to know where it is.** `cat runs/<scenario>/<stamp>/timeline.log`. Every marker and tick is there with a UTC timestamp.

**`orb` hangs, or errors with a Go stack trace.** OrbStack's daemon has wedged; this happened once during this lab's own development. Quit and reopen OrbStack, then re-check with `orb -m cert-hygiene-lab echo alive`. Nothing in the repository needs changing.

**`lab-up` refuses on architecture.** The VM was created for a different architecture than your host. `lab-down`, then `lab-up` again.

**`lab-up` says the VM cannot see the working tree.** OrbStack's [file sharing](https://docs.orbstack.dev/machines/file-sharing) is not presenting your checkout at the same path inside the machine. Nothing else works until it does.

**A run came back `evidence_valid=no`.** Read the reasons in `validity.txt`; each names what failed. The most common are a dirty tree (a local override file counts), a missing control run at the current harness tree, and a discovery run, which is never evidence by definition.

**A run's numbers look wrong.** Trust the recorded files over any summary of them, including the write-ups. Every figure in the article notes is meant to be checkable with `tools/evidence.sh cat`, and that is the point of the manifests.

## Where the findings are

- [`docs/articles/cert-hygiene/findings.md`](../../docs/articles/cert-hygiene/findings.md) — what the lab learned, with a triage table that starts from a symptom
- [`docs/articles/cert-hygiene/sources.md`](../../docs/articles/cert-hygiene/sources.md) — what to cite for each claim, and what each experiment does *not* support
- [`docs/articles/cert-hygiene/notes/`](../../docs/articles/cert-hygiene/notes/) — one write-up per experiment, where the hypotheses are judged against the transcripts
- [`docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md`](../../docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md) — how to read a recorded run when checking a claim

The lab's own design and the judgement calls made while building it are under [`docs/superpowers/`](../../docs/superpowers/), including a record per round of what each decision would have cost if it was wrong.

## Layout

```
demos/cert-hygiene/
  Justfile                 the recipes above
  config.example.env       every setting, documented; copy to config.local.env
  scenarios/               one file per scenario, thin wrappers over lab/
  lab/                     the harness: reset, collectors, validity rules, tests
    profiles/              credential lifetimes per scenario
    tests/                 the unit suites
  scripts/                 host-side entry points and readers for recorded runs
  runs/                    one committed manifest per recorded run
```

`lab/` runs inside the VM; `scripts/` runs on the host and reaches in through `orb`. The split matters when reading the code: anything under `lab/` can assume GNU tools and a cluster, and anything under `scripts/` cannot.
