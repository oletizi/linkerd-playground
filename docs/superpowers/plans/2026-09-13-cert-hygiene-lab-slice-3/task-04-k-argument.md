# Task 4: K's replacement-issuer lifetime as a per-run argument

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** the `linkerd check` threshold scenario can be run at different replacement-issuer lifetimes without editing a tracked file, so a bisect is a series of runs rather than a series of commits.

**Why:** slice 2 measured the 60-day warning still firing at 60 days + 557 s, and clearing at 61 days + 30 min — a 24-hour-wide bracket the article cannot state as a number. Narrowing it means several runs at different lifetimes. Today the lifetime is `K_PLUS_ISSUER_LIFETIME` in `config.example.env`, so each run would need a commit, and the one attempt that used a local override was marked invalid because the harness treats any override file as a dirty tree.

**Files:**
- Modify: `demos/cert-hygiene/scenarios/20-check-threshold.sh`, `demos/cert-hygiene/scripts/run.sh` if it must pass an argument through, `demos/cert-hygiene/config.example.env` (the default stays, as the documented value)

**Interfaces:**
- The scenario accepts the lifetime as an optional argument after the run directory; absent, it uses `K_PLUS_ISSUER_LIFETIME` exactly as today, so every existing invocation behaves identically.
- Whatever value is used is recorded in the run — in `versions.txt` if the existing config dump covers it, otherwise explicitly — so a run's own files say what it tested. A run whose lifetime is not recoverable from its own evidence is not evidence.
- `scripts/run.sh` passes trailing arguments through to the scenario. Keep its refusal of `--short` outside discovery runs intact.

**Steps:**

1. Read `scenarios/20-check-threshold.sh` and `scripts/run.sh` first. The scenario already signs its replacement issuer from the profile's anchor; only the lifetime's source changes.
2. Make the lifetime an argument with the config value as the default. Record it in the run.
3. `bash -n`, `shellcheck`, and `just demo cert-hygiene test` clean. No lab run in this task — Task 7 does the runs.
4. Confirm, without running it, that an unchanged `run.sh 20-check-threshold` still behaves exactly as before: same default, same recorded values. Say in your report how you confirmed it.
5. Commit and push. No article README change.
