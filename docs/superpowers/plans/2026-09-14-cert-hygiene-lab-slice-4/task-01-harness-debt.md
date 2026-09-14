# Task 1: Pay slice 3's harness debt

Part of the [slice 4 plan](README.md). Read its Global Constraints first.

**Goal:** the four items slice 3's final review deferred, done together, before the freeze. They are grouped because each changes the harness tree, and a changed tree costs a control re-run — one re-run for all four rather than one each.

**Files:**
- Modify: `demos/cert-hygiene/lab/lib-evidence.sh`, `lib-evidence-rules.sh`, `scenarios/30-tap-expiry.sh`
- Test: `demos/cert-hygiene/lab/tests/test-rules.sh`, and new coverage for `collect-state.sh` and `lib-webhook.sh`

**The four items:**

1. **`control-at-tree` reads committed manifests, not a directory on disk.** Today `_control_passed` (`lib-evidence.sh:81`) scans `runs/00-baseline-control/*/validity.txt`. That is why a control which had been published and its local copy removed — exactly what the publish workflow tells you to do — silently invalidated a perfectly good 50-minute run. The manifests are committed, and each one's header already carries `validity_evidence_valid` and `harness_tree_sha256`. Read those instead, so a fresh clone can validate a run without materialising anything.

   Keep accepting a control that is present on disk, so nothing that works today stops working; the manifest is an additional source, not a replacement. Say in the code comment why both exist.

2. **The duplicated reconnect-exit block.** `lib-evidence-rules.sh` contains the same four lines — the `restart`/`rollout` loop and its reason string — byte-identical in `w-reconnect` and `v-reconnect`. Extract one helper in the style of the file's existing `_first_is` and `_kv`, emitting reasons the way the callers expect. Only the `backing.txt` check genuinely differs between the two rules; leave that difference in place.

3. **`_v_backing` carries its namespace.** In `scenarios/30-tap-expiry.sh`, `_v_backing` reads `.spec.service.namespace` from the live APIService into a local and never returns it, and then `_v_reconnect` hardcodes `linkerd-viz` twice. Add a `namespace=` field to the backing line and use it. A scenario that derives a value precisely so it is not hardcoded, and then hardcodes it, teaches the wrong pattern to whoever adds the next one.

4. **Unit tests for slice 3's collectors.** None of these has any: `snap_apiservices`' `-` sentinel for an absent caBundle (itself a review fix that shipped untested), `_v_tap_events`' counting, `make_tap_cert` and `tap_install_args`, and `load_profile`'s new required key. `collect-state.sh` and `lib-webhook.sh` have no test file at all — create what they need, following `test-webhook.sh`'s shape.

   Each test must be able to fail. Assert on the reason string or the emitted value, not merely on exit status, the way `test-rules.sh`'s `vk1`/`vk2`/`vk3` cases do.

**Steps:**

1. Read `lib-evidence.sh`, `lib-evidence-rules.sh` and `test-rules.sh` before changing anything.
2. Make each change with its test. For item 1, prove the new path works by pointing a fixture at a manifest with no run directory present — that is the case that broke.
3. `bash -n`, `shellcheck`, and `just demo cert-hygiene test` clean. Every suite passes.
4. Confirm no scenario's behaviour changed except `30-tap-expiry`'s backing line, and say in your report how you confirmed it.
5. Commit and push. No article change.

**Do not** re-run any lab scenario in this task, and do not delete the control run's local copy — item 1 makes that safe eventually, but Task 5 records the new control and until then the old rule still has to work.
