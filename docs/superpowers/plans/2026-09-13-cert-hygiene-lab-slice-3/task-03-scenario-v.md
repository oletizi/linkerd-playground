# Task 3: Scenario V — tap certificate expiry

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** a scenario that lets the tap serving certificate expire and records what tap, the tap APIService and `linkerd viz check` do — before, at, and after the expiry. It judges nothing: V1 is judged later, in the write-up.

**Design:** slice 2 design § 8. V1 predicts that the APIService goes `Available=False`, `linkerd viz tap` fails, and `linkerd viz check` goes fatal on the tap certificate row. The basis is an inference from source notes, so the run exists to test it, not to confirm it.

**Files:**
- Create: `demos/cert-hygiene/scenarios/30-tap-expiry.sh`
- Modify: `demos/cert-hygiene/lab/scenario-common.sh` only if a hook genuinely cannot express what V needs — prefer the existing hooks
- Create (committed): one discovery run under `demos/cert-hygiene/runs/_discovery/`

**Interfaces:**
- `run_scenario 30-tap-expiry tap-short "$1"`, so the profile installs Viz with a 15-minute tap certificate.
- T_mark is the tap certificate's `notAfter`, exactly as the webhook scenarios take theirs from the serving certificate: the expiry is the fault, nothing is deleted or scaled.
- Before T_mark, once, the baseline: run `linkerd viz tap` against live traffic, confirm the APIService is Available and `linkerd viz check`'s tap rows pass, and write `tap-baseline.txt` in the shape Task 2's `v-baseline` rule reads (`result=ok|fail`, then `ok:`/`fail:` lines).
- On every tick after T_mark, a tap probe: `linkerd viz tap` against a lab workload with a short bounded duration, recorded whole — the command line, its exit status, its output — under `tap/<tick>.txt`. A failure here is the observation, so it must never abort the run.
- `POST_EXPIRY_WINDOW_S` applies as for the other timed scenarios; the run ends with a `verify` tick.
- Mesh traffic probes run throughout, so the write-up can say whether tap's expiry touched data-plane traffic at all.

**Steps:**

1. Read `scenarios/02-webhook-expiry-ignore.sh` first: V is the same shape — a lab-supplied serving credential expiring, probes repeated per tick — minus the recovery branching. Follow it.
2. Write the scenario. Keep the tap probe's timeout short and bounded (`linkerd viz tap` has no `--timeout` flag, as Task 1's discovery found; bound it another way and say how).
3. Register the scenario wherever the harness lists scenario names, and confirm `scenario_rules 30-tap-expiry` and its required files, added in Task 2, match what this scenario actually writes. A required file the scenario never writes makes every run invalid.
4. `bash -n`, `shellcheck`, and `just demo cert-hygiene test` all clean.
5. **One discovery run:** `bash scripts/run.sh --discovery --short 30-tap-expiry`, waited out with bounded foreground waits. Then check: the timeline reaches `done`; `tap-baseline.txt` says `result=ok`; `apiservices/` and `tap/` have per-tick files spanning the expiry; `validity.txt` carries only the discovery reason and the no-control reason. Commit the discovery run.
   If the baseline fails — tap not working while its certificate is valid — stop and report BLOCKED: that is the stop gate, and it means V cannot be run as designed.
6. Commit and push. No article README change.
