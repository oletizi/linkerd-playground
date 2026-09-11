# Review: cert-hygiene lab slice 2 implementation plan

- **Reviewed:** `docs/superpowers/plans/2026-09-11-cert-hygiene-lab-slice-2/` at commit `00dcb69` (draft, before any execution), against the approved slice 2 design.
- **Reviewer:** independent subagent review, read-only. It could not write its report file, so the controller recorded it here from the reviewer's returned text.
- **Controller rulings on this review** are at the end.

**Method:**
- Read the plan (README and tasks 01–32), the design and the harness the plan modifies.
- Extracted all 154 fenced blocks. Ran `bash -n` and `shellcheck -s bash|sh` on the 51 bash/sh blocks of 8 or more lines.
- Checked against linkerd2 upstream (`main` branch, not a pinned edge-26.9.1 tag):
  - `linkerd upgrade` declares `Args: cobra.NoArgs`.
  - The proxy-injector chart writes `tls.key` and `caBundle` unquoted, sets `sideEffects: None` and `failurePolicy: {{.Values.webhookFailurePolicy}}`, and has no checksum annotation.
- Traced each unit test by hand. The tests could not be run: the host has only bash 3.2 and the lab VM was off limits.

**Counts:** 1 Critical, 7 Important, 15 Minor.
- No `bash -n` errors across the larger code blocks.
- Shellcheck reports SC1010 once and SC2016 five times where the plan expects no findings.
- Commit messages, the ban on `sed` writes and `#` in multi-line commands, the 300-line file limit, and file lists versus commit steps are all fine.

## 1. Coverage

| Design element | Task(s) | Status |
| --- | --- | --- |
| § 1.1 profiles, `reset.sh <profile>`, lab-supplied webhook creds (CA, SANs, `--set-file … caBundle`) | 1 | Covered. The discovery never renders `webhook-short-fail` (M14). |
| § 1.2 hooks | 9 | Covered |
| § 1.3 credential state per tick | 2, 4 | Covered. The fallback is dead code (I6). |
| § 1.3 declared plans and walk | 2, 3 | Covered for all 9 scenarios. W is `W1→W2` by judgement call. |
| § 1.3 rules: common, plan, recovery-apply (R, A), webhook baseline (W), K sides, S-hard stage 1, control at same tree (all except K) | 3, 5, 11, 12, 14, 17 | Covered. Missing: a W rule that the plain render actually ran (C1). |
| § 1.3 a gate timeout never invalidates a run | 7, 8 | Covered |
| § 1.4 webhooks, connection metrics, control plane, gates, `pods.txt`, journal | 5, 7 | Covered |
| § 1.4 APIService status | — | Deferred with V; justified |
| § 1.4 write-up instructions | 18 | Covered (M11) |
| § 1.5 second client | 6 | Covered (M2) |
| § 1.6 gates and samples, timeout from discovery | 7 | Covered. Condition 3 uses the current ConfigMap hash, which is equivalent in every planned stage. Condition 4's "predicted no leaf" branch is a judgement call. |
| § 1.7 restart-choreography control | 8, 9, 19 | Covered |
| § 2 R and R1–R4 | 8, 10, 20, 26 | Covered |
| § 3 W: staggered expiry, per-tick probes, per-attempt artifacts; W1–W4, W6 | 11, 12, 21, 27 | Plain recovery is broken (C1); markers are late (I3); start time deviates (I7) |
| § 4 O and O1–O3, invariant | 13, 22, 28 | Covered. The config invariant is checked in the write-up, as § 13 allows. |
| § 5 K and K1 | 14, 23, 29 | Covered |
| § 6 A and A1–A5 | 15, 24, 30 | Covered; the canary has a hole (I5) |
| § 7 S-staged, S-hard, S1, S1-obs, S2–S4 | 16, 17, 25, 31 | S-staged gate records are hidden (I2) |
| § 8 V | — | Deferred pending the user, as the design requires |
| § 10 discovery items | 1, 6, 7, 11 | Covered, with stop gates. No full smoke runs of the new scenarios (I1). |
| § 11, § 13, § 14 | 26–32, 19 | Covered; the key guard is weak (I4) |

## 2. Findings

### Critical

**C1 — Task 12:218–225, called at :295.**
- **What's wrong:**
  - `"linkerd upgrade $(printf '%q ' "$@") > …"` with no arguments expands to `linkerd upgrade ''` on bash 4 and later. The VM runs 5.2.
  - Because of `cobra.NoArgs`, the command fails and leaves an empty manifest. The apply fails and the Secrets stay deleted.
- **What follows:**
  - The facts record no Secrets, so the run classifies `branch=iii`.
  - The supplied path then recreates the Secrets and the plan walk passes, so the run is valid.
  - W6 then records a harness artefact. No step catches it: Step 7 calls `linkerd upgrade` directly, and there is no W smoke run.
- **Fix:**
  - Build the argument string only when there are arguments: `q=""; [ $# -eq 0 ] || q="$(printf ' %q' "$@")"`.
  - Add a `w-plain-render` validity rule: `recover/plain-render.txt` and `recover/plain-apply.txt` end `[exit 0]`, and `recover/plain-manifest.yaml` is non-empty.
  - Add a fixture test for the rule.

### Important

- **I1 — no end-to-end discovery runs of W, O, K, A, S-staged or S-hard.**
  - Only the control is smoke-run (Task 9). Every bug found in Phase 2 then forces a new control run of about 1¼ hours.
  - Add a Phase 1 task that runs each new scenario once with `run-discovery`, applies the Tasks 21–25 sanity checks, then fixes the harness and commits.
- **I2 — S-staged gate records are filtered out (Task 16, stage names `sNN-restart`).**
  - `restart_and_gate` also writes `gates/<stage>-restart.txt`, and both `gate-table.sh` (Task 18:133) and `control_criteria_check` (Task 8:132) skip `*-restart.txt`.
  - Result: `gate-table.sh` shows nothing for S-staged, and Tasks 25 and 31 break.
  - Fix: rename the stages, rename the capture file, or have the readers select files by their `stage=` line. Add a test.
- **I3 — the W expiry marker uses the time after the tick's collection (Task 12:191–211).** It can name a tick whose `linkerd check` ran before the expiry, which puts the W4 evidence at risk. Compare each `notAfter` with the tick's start time instead, and put that start time in the marker.
- **I4 — `assert_no_keys` greps only the literal `PRIVATE KEY`.**
  - Base64 `key.pem` and `tls.key` values that escape redaction would pass unnoticed.
  - Fix: decode every `LS0tLS1CRUdJTi…` token and die if it contains a private key; unit-test it.
  - In Task 12 Step 7, expect at least four redactions (issuer key and three webhook keys) and add the decode scan.
- **I5 — A's canary Ready check doesn't prove the canary was injected (Task 15:93–106).**
  - After the `--force` upgrade, the injector's new pod may not start until identity can issue. With failurePolicy Ignore, the canary is then admitted without a proxy and is Ready immediately, which would judge A5 backwards.
  - Fix: count Ready only when the pod has a `linkerd-proxy` container, its trust annotation equals the new ConfigMap hash, and its proxy's refresh time is after the pod started. Otherwise record "admitted without a proxy" and re-apply.
- **I6 — collector failures kill the run.**
  - Task 4:82: `fp="$(grep -m1 … | cut …)"` fails under `set -e` with pipefail, so the fallback never runs.
  - Task 7:213 (`_trust_now`), and `_current_pod` at Task 7:249 and Task 17:176: one failed kubectl read kills an hour-long run, most likely during control-plane rollouts.
  - Fix: add `|| true` and treat an empty value as "unreadable".
- **I7 — W recovery starts at T1 + window (Task 12:13, :172).** The design says T3 plus the window, which is T1 + 50 min here. Either implement that, or list it as a judgement call for the user to approve.

### Minor

- **M1:** Task 8's red step says `cr2` should fail; under the old function it passes.
- **M2:** Task 6 Step 7 says the delta line starts with `tcp_open_total{`. Delta-file lines start with the delta value (`15 tcp_open_total{…}`).
- **M3:** in Task 12 Step 7, `grep -c "PRIVATE KEY"` printing 0 exits 1 under the `set -e` that `lib-lab.sh` turns on. The command then stops before `rm`, leaving the unredacted render in the VM's `/tmp`. Use `|| true`.
- **M4:** in Task 1 Step 11, the 15-minute injector certificate means reset, deploy and discovery race the clock. A slow executor trips the stop gate falsely.
- **M5:** for S-hard's `server` endpoint, the lines file is client A's log then client B's, unsorted. The recorded first failure is therefore not the earliest.
- **M6:** in `_a_stage3`, a Pending pod has a null `startTime`; `jq` errors and the pod is treated as not stale.
- **M7:** W's un-injected `inject-probe` pods trigger three `:4191` metric retries each, which slows ticks.
- **M8:** a discovery control run writes `evidence_valid=yes`; mark discovery runs as such.
- **M9:** Task 26's file list says it changes the README status, but no step does. Tasks 26–31 leave the status stale until Task 32.
- **M10:** Task 32's grep uses `\b`, which BSD grep may not support, and `\btick` also matches "ticket".
- **M11:** the reading guide says `--timestamps` log lines carry the VM's local time. `kubectl logs --timestamps` prints UTC with a `Z`; verify before publishing the guide.
- **M12:** the "no shellcheck findings" expectations will fail:
  - SC1010 on `mark discover-gates done` in `discover-gates.sh`.
  - SC2016 on the `bash -c '…'` lines in `scenario-webhook.sh`, `06-anchor-expiry.sh` (twice), `07-anchor-rotation-staged.sh` and `08-anchor-rotation-hard.sh`.
  - Add disable comments.
- **M13:** the plan uses `post-NNNN` where the design says `post-NNN`. Harmless; note it as deliberate.
- **M14:** `failurePolicy=Fail` is first observed in Phase 2. Add a render check to Task 1.
- **M15:** `tick fault-minus10` can take more than 10 s, so faults in O and S-hard fire late. The write-ups should use the recorded fault and swap times, not T_mark.

## 3. Judgement-call verdicts

1. **Gate when no leaf is predicted:** sound. Every gated stage restarts pods after a signer able to issue for them is in place. A timeout records the leaf state on every poll and leaves the cell unclassified.
2. **K repeated as a fresh run:** sound. An in-run repeat would sign a third issuer, which the plan walk rightly rejects. There is a 600 s margin.
3. **S-hard stage 1 met by a successful renewal:** sound and necessary; otherwise S4 can't be falsified. The write-up must check whether a "renewed" leaf chains to the old anchor, which happens if identity wasn't restarted.
4. **W's single tick change with the intermediate state in non-tick files:** sound. No tick runs between the Secret delete and the final apply, and the branch rule is declared in advance. The user should confirm this reading of § 1.3, and it needs the C1 rule.
5. **Manifest redaction:** sound and required; it depends on I4.
6. **A's canary Deployment:** sound in principle, unsound as written (I5).
7. **The 1800 s window for all timed runs:** sound for the control, R and A. W's T1 + window reading needs the user's decision (I7).

## 4. Controller rulings

- **All findings C1, I1–I7 and M1–M15 are accepted,** to be fixed in one pass by the plan's author, then checked in a scoped re-review.
- **I1:** add a Phase 1 task that runs each of the six new scenarios once as a discovery run, before the freeze. Discovery runs may shorten their observation windows through a discovery-only override, which evidence runs must refuse; the override is recorded in the discovery run's artifacts.
- **I7:** W follows the design: recovery starts after T3 plus W's own post-expiry window. W's window is 600 s, not 1800 s. Webhook effects are immediate on each admission call, so 20 per-tick probe rounds after the last expiry are enough, and the run stays bounded. The control, R and A keep 1800 s; O keeps `OUTAGE_S`; S-hard keeps 0.
- **Judgement call 4** (W's single credential change): confirmed. The design's § 1.3 example gives W's plan as `W1 → W2`.
- **Judgement call 3** (S-hard renewal): the S write-up task must check which anchor each "renewed" stage-1 leaf chains to.
- **M11:** verify the timestamp behaviour in discovery; don't assert either reading in the guide until it's recorded.
