# Task 3b: V's forced-reconnect phase

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Why this exists.** Task 3's throwaway run showed the tap certificate expiring, `linkerd viz check` going fatal on the tap row — and `linkerd viz tap` continuing to stream real events, with the APIService still `Available=True`, for the rest of the run. That is the same shape slice 2 found in the admission webhooks: an expired serving certificate does not bite while the API server is still using a connection it opened earlier, because TLS checks dates at the handshake.

Slice 2 answered that by adding a forced-reconnect phase to the webhook scenario, with the user's approval; this task gives V the same treatment, for the same reason. Without it, V can only report that nothing appeared to break, which would tell a reader almost nothing about the risk.

**Precedent to follow:** `lab/scenario-webhook.sh`'s reconnect phase and its `w-reconnect` rule. This is the same mechanism against a different Deployment, so follow its shape rather than inventing one.

**Files:**
- Modify: `demos/cert-hygiene/scenarios/30-tap-expiry.sh` (the phase), `demos/cert-hygiene/lab/lib-evidence-rules.sh` (the rule and required files), `lab/tests/test-rules.sh` and `lab/tests/fixtures.sh` (tests and fixture)
- Modify: `demos/cert-hygiene/config.example.env` (`V_RECONNECT_WINDOW_S`, and its discovery-only counterpart alongside the existing `DISCOVERY_*` values)

**Interfaces:**
- After the post-expiry window and before the run ends, the phase: find the Deployment behind the Service the tap APIService points at — derive it at run time from the APIService and the Service's selector, as the webhook phase derives its backing Deployments, and record the mapping in `reconnect/backing.txt`. Do not hardcode `tap`.
- `reconnect/restart.txt` and `reconnect/rollout.txt`, each ending `[exit N]`, produced the same way the webhook phase produces them (`capture`, and the shared rollout helper).
- `controlplane/` snapshots of the linkerd-viz namespace before and after the restart, so the new pod's UID proves the restart happened.
- Tap probes, the APIService condition and `linkerd viz check` repeated immediately after the rollout and on each tick for `V_RECONNECT_WINDOW_S`, under tick names that make the phase obvious in the timeline.
- Rule `v-reconnect` for `30-tap-expiry`: `reconnect/backing.txt` names a Deployment, and both `restart.txt` and `rollout.txt` end `[exit 0]`. Join it to V's rule list and required files, with exact pins and a negative test per clause, as `w-reconnect` has.

**Steps:**

1. Read `lab/scenario-webhook.sh`'s reconnect phase first and follow it. The rollout helper it uses already exists; do not write a second one.
2. TDD the rule: fixture plus one negative test per clause, each asserting its own reason text. Show RED, then implement.
3. Implement the phase. Everything it records is an observation — a tap probe failing after the restart is the point, and must never abort the run.
4. `bash -n`, `shellcheck`, and `just demo cert-hygiene test` clean.
5. **One throwaway run** of `30-tap-expiry` with the short windows, waited out with bounded foreground waits. Check: the phase's markers appear in the timeline after the post-expiry window; `reconnect/backing.txt` names a Deployment; both records end `[exit 0]`; the viz pod's UID differs before and after; tap probes and check transcripts exist for the reconnect ticks; `validity.txt` carries only the discovery and no-control reasons. Publish the run with `tools/evidence-upload.sh`, commit its manifest, and remove the local copy.
6. Record, as seen and never judged, what tap and the APIService did after the restart — that is the whole reason for the phase, and Task 8 will judge it.
7. Commit and push. No article README change.
