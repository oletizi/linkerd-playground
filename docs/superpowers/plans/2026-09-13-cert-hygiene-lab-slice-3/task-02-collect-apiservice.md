# Task 2: Collector — tap APIService state, and the rule that makes V falsifiable

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** every tick records what the tap API is doing, and a validity rule refuses to call a V run evidence unless tap was proved working while its certificate was valid. Without that baseline, "tap failed after expiry" says nothing — it might never have worked.

**Design:** slice 2 design § 1.4 lists "APIService status, for V only" among the collector additions. § 1.3's rule table is where the new rule joins.

**Files:**
- Modify: `demos/cert-hygiene/lab/collect-state.sh` (a `snap_apiservices` beside the existing snapshots), `demos/cert-hygiene/lab/collect.sh` (call it from `tick`, only when the profile installed Viz)
- Modify: `demos/cert-hygiene/lab/lib-evidence-rules.sh` (the `v-baseline` rule, V's required files, V's credential plan), `demos/cert-hygiene/lab/tests/test-rules.sh` and `lab/tests/fixtures.sh` (the rule's tests and fixture)
- Modify: `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` if a pure helper is the clean way to judge the baseline

**Interfaces:**
- `apiservices/<tick>.txt`: for `v1alpha1.tap.linkerd.io` — the `Available` condition's status, reason and message; the `caBundle`'s SHA-256; and the backing Service. One line per fact, in the style the other per-tick files use.
- `viz/<tick>.txt`: the linkerd-viz namespace's pods with UID, start time and readiness, and each Deployment's generation — the same shape `snap_controlplane` writes, so a reader already knows how to read it.
- `tap-baseline.txt`: written once, before the certificate expires, recording whether `linkerd viz tap` returned events while tap was healthy. First line `result=ok` or `result=fail`, then `ok:`/`fail:` lines naming what was checked.
- Rule `v-baseline`, for scenario `30-tap-expiry` only: the run is evidence only if `tap-baseline.txt` says `result=ok`. A run where tap never worked cannot be evidence about tap breaking.
- V's rule list is `v-baseline control-at-tree`; its credential plan is a single state (nothing rotates in V — only the tap certificate expires, and it is not part of the credential plan).

**Steps:**

1. Read `collect-state.sh`'s existing snapshots and `lib-evidence-rules.sh`'s rule table before writing. Follow their shape.
2. **TDD the rule first.** Add the fixture and the tests: a V fixture whose `tap-baseline.txt` says `result=ok` is valid; one saying `result=fail` is invalid with the rule's reason text; one missing the file is invalid for the missing-file reason. Show RED, then implement.
3. Add the exact `scenario_rules` and `credential_plan_for` pins for `30-tap-expiry` to `test-rules.sh`, in the style every other scenario already has there — an exact assertion, not a `contains`.
4. Write `snap_apiservices` and the viz snapshot. Both are collector reads: a failure is recorded, never fatal. Call them from `tick` only when Viz is installed, so every other scenario's per-tick files are unchanged.
5. Confirm the other scenarios' required-file lists are untouched, and that `just demo cert-hygiene test` passes. `bash -n` and `shellcheck` clean.
6. Commit and push. No article README change; no lab run in this task.
