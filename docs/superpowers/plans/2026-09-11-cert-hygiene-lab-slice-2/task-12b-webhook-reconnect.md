# Task 12b: W's forced-reconnect phase

Part of the [slice 2 plan](README.md). Read its Global Constraints first. **Phase 1.** Added after the first `Ignore` discovery run, with the user's approval (design § 3 "Forced reconnect", W7, § 12.3).

**Goal:** After T3 plus W's post-expiry window, and before recovery, W forces the API server to open new connections to each webhook by restarting the Deployments behind the three webhook Services. It then probes each webhook, once straight away and on every tick for `W_RECONNECT_WINDOW_S`. Recovery starts after that phase. Scripts record; they never judge W7.

**Why:** in `runs/_discovery/20260911T172403Z-02-webhook-expiry-ignore`, the policy validator failed after expiry, but the injector kept injecting for about 24 minutes past its `notAfter`. The sp-validator kept denying. The k3s journal shows `x509: certificate has expired` only for calls to the policy validator. The likely cause is that the API server reused pre-expiry connections, and TLS checks a certificate's dates only at the handshake.

**Files:**
- Modify: `demos/cert-hygiene/lab/scenario-webhook.sh` (the reconnect phase, before recovery; the tick-to-phase mapping for `reconnect-*` ticks)
- Modify: `demos/cert-hygiene/lab/stages.sh` (a shared `capture_rollouts FILE DEPLOY...`; `capture_cp_rollouts` calls it, so the rollout loop exists once)
- Modify: `demos/cert-hygiene/lab/lib-evidence-rules.sh` (the `w-reconnect` rule; W's required files), `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` (pure helpers, if any), `demos/cert-hygiene/lab/scenario-common.sh` (`_discovery_setup` lowers `W_RECONNECT_WINDOW_S`)
- Modify: `demos/cert-hygiene/config.example.env` (`W_RECONNECT_WINDOW_S=180`, `DISCOVERY_W_RECONNECT_WINDOW_S=60`)
- Modify: `demos/cert-hygiene/lab/tests/test-rules.sh`, `lab/tests/fixtures.sh`, `lab/tests/test-scenarios.sh`

**Interfaces:**
- Consumes: `WEBHOOK_COMPONENTS`, `webhook_service` (lab/lib-webhook.sh); `capture`, `mark`, `tick`, `snap_controlplane`, `snap_webhooks`; W's admission probe round and phase directories (`admission/<phase>/`); `_discovery_setup` and `discovery-windows.txt` (Task 9); `capture_cp_rollouts` (lab/stages.sh).
- Produces:
  - `reconnect/backing.txt`: one line per component, `component=<c> service=<svc> deployment=<deploy|->`, derived at run time from each Service's `.spec.selector` matched against each `linkerd`-namespace Deployment's pod-template labels. A failed read is recorded (`deployment=-`, plus the error), never fatal.
  - `reconnect/restart.txt`: `capture` of one `kubectl -n linkerd rollout restart deploy/<d>…`, with each distinct backing Deployment named once.
  - `reconnect/rollout.txt`: `capture_rollouts` over the same Deployments. It ends `[exit N]` and exits non-zero on an empty list or a failed rollout.
  - `controlplane/reconnect-before.txt` and `controlplane/reconnect-after.txt` (pod UIDs before and after).
  - Admission phases `reconnect-NNNN`, where NNNN is the seconds since the rollouts finished. `reconnect-0000` is the immediate round; the rest come from ticks named `reconnect-<n>` during `W_RECONNECT_WINDOW_S`. Each has the same per-attempt artifacts as the other phases, and the tick's `checks/<tick>.txt` holds the `linkerd check` transcript.
  - Timeline markers: `reconnect-backing`, `reconnect-restart`, `reconnect-rolled-out`, `reconnect-end`. The `recover-delete` marker comes after `reconnect-end`.
  - `W_RECONNECT_WINDOW_S` is recorded in `versions.txt` (the `W_` prefix already covers it). Discovery `--short` lowers it to `DISCOVERY_W_RECONNECT_WINDOW_S` and records that in `discovery-windows.txt`, never raising it.
  - Validity rule `w-reconnect`, for both W scenarios only. It holds when `reconnect/backing.txt` names a Deployment for all three components, and `reconnect/restart.txt` and `reconnect/rollout.txt` each end `[exit 0]`. The three files join W's required files.

**Requirements:**
1. The reconnect phase runs after T3 + `W_POST_WINDOW_S` and before the first recovery action (the Secret delete). No credential changes during it: the restart doesn't touch Secrets, so the credential plan stays `W1 → W2`. Check this with the plan walk on a fixture.
2. Restart each distinct backing Deployment once, even when it backs more than one webhook.
3. Do not restart any `lab`-namespace workload in this phase.
4. `capture_rollouts FILE DEPLOY...` holds the one rollout-status loop. `capture_cp_rollouts FILE` becomes a call to it with every `linkerd` Deployment. It keeps its hardened behaviour: it exits non-zero on an empty or unreadable list or a failed rollout. Its existing tests stay green.
5. TDD for the pure parts:
   - selector-to-Deployment matching, if implemented as a pure function over recorded JSON;
   - the `w-reconnect` rule, with a positive and three negative fixtures (missing deployment; restart not `[exit 0]`; rollout not `[exit 0]`), each asserting its reason text;
   - updated exact `scenario_rules` pins for both W scenarios;
   - the fixtures writing the new required files (`make_run`'s placeholder loop keeps creating files only when absent).
6. `bash -n`, shellcheck clean, `just demo cert-hygiene test` all PASS, every file under 300 lines. Report DONE_WITH_CONCERNS if one would exceed.
7. No lab run in this task. Task 19 repeats both W discovery runs on this code.

**Commit:** `cert-hygiene force new API-server connections to expired webhooks before W recovery`. No article README change.

**Downstream:**
- Task 19 re-runs Steps 4 and 5 after this task. It adds these checks:
  - `reconnect/backing.txt` names three Deployments;
  - `restart.txt` and `rollout.txt` end `[exit 0]`;
  - `admission/` has `reconnect-0000` and at least one later `reconnect-NNNN`;
  - `reconnect-end` comes before `recover-delete` in `timeline.log`.
- Task 28's write-up judges W7 from the `reconnect-*` phases and the journal. Every claim about when an expired webhook fails says whether the API server had reconnected (design § 13).
