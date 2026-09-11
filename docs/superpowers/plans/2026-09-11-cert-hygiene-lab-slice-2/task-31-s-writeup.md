# Task 31: S write-up

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where S's hypotheses are judged; nothing in `runs/` is edited.

**Goal:** Judge S1, S2, S3, S4 and record S1-obs (design § 7) against the staged and hard runs and the control, check S's acceptance condition (design § 13), and set out the evidence Task 32 rewrites the rotation guidance from. Write `docs/articles/cert-hygiene/notes/lab-evidence-anchor-rotation.md`.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-anchor-rotation.md`
- Modify: `docs/articles/cert-hygiene/README.md` ("Start here" list)

**Interfaces:**
- Consumes: runs `SS` and `SH` (Task 25), control `C`, `S=demos/cert-hygiene/scripts`.
- Produces: the evidence note, including "Evidence for the rotation guidance".

**Judgement rules:** as in the reading guide. A failure counts against S1 only if proxy logs show a certificate or trust error and it falls in a gated sample. Every other application-visible failure goes into S1-obs, timed against pod terminations and compared with the control.

- [ ] **Step 1: Facts**

For each of `SS`, `SH`: `cat $SS/validity.txt; grep harness_tree $SS/git-state.txt $C/git-state.txt; grep -E ' (s[0-9]{2}|s-hard-swap|stage|restart|gate|issuer-updated|done)' $SS/timeline.log`, and `head -n 8 $SS/credential-plan.txt`.
Expected: both valid at the control's tree; S-staged walks four credential states, S-hard two.

- [ ] **Step 2: S's acceptance condition (design § 13)**

- **Staged results separate TLS-attributable failures from rollout disruption, against the control:**
  - List every probe failure in `SS`: `for p in probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream; do bash $S/probe-lines.sh $SS $p | awk '$4 != "ok"'; done`.
  - Place each against the restart windows: each `gates/sNN-restart.txt` from `started_at` to `gate_at`.
  - Place each against pod terminations: the `before` pods' disappearance in the gate's `check` lines.
  - Do the same for the control's restart stages (`bash $S/gate-table.sh $C`, and `probe-lines.sh` on `C` over its stages).
  - A failure is TLS-attributable only if the proxy logs of the pods involved (`logs/pre-sNN/*-linkerd-proxy.txt`, `logs/final/`) show a certificate or trust error at that time: `grep -hiE 'certificate|trust|x509|handshake' <those files>`.
- **Hard rotation records the actual mixed-anchor endpoint states:** for the ticks `stage2-client-a` and `stage3-server`, `grep -E 'lab/(probe-tcp-new|probe-tcp-new-b|server)-' $SH/trust/<tick>.txt` against that tick's `configmap_sha256=` line: which endpoints carry the new bundle and which the old.
- **…and the stage-1 old-leaf renewal and expiry behaviour:** `cat $SH/s-hard/stage1-condition.txt` (`result=met`; per endpoint, the final state line).

- [ ] **Step 3: Evidence per hypothesis**

- **S1 (in S-staged, no new-connection failure attributable to TLS identity or anchor incompatibility at any step):** `bash $S/gate-table.sh $SS` for `s04-restart`, `s08-restart` and `s11-restart`: every gate `pass` and every cell `fail=0`? For any failed gated sample, the proxy-log attribution from Step 2.
- **S1-obs (observation):** the full failure list from Step 2, with each failure's time relative to the nearest pod termination, beside the control's list. This tests the documented "without downtime" claim operationally.
- **S2 (between steps 3 and 4, `linkerd check --proxy` warns "Some pods do not have the current trust bundle and must be restarted"):** `grep -h -A2 'current trust bundle' $SS/checks/s03-upgrade-bundle-check-proxy.txt $SS/checks/s04-restart-check-proxy.txt`, which should show the warning at s03 and not after s04's restarts.
- **S3 (in S-hard, a new connection between endpoints holding different anchors fails: pair A at stage 2, pair B at stage 3):** `bash $S/gate-table.sh $SH`: cells for `stage2-client-a` (pair A) and `stage3-server` (pair B), with the trust states from Step 2. Also report the other cells against the design's matrix.
- **S4 (in S-hard stage 1, unrestarted proxies can't take a renewed certificate chained to the new anchor; they keep their current leaf and fail as it expires):** per endpoint, the final `state=` of `s-hard/stage1-condition.txt`: `expired-failed` supports S4, `renewed` falsifies it for that endpoint. Quote the old leaf's `notAfter`, the renewal counts and the first failure after expiry; cross-check with that proxy's log in `logs/pre-stage2/*-linkerd-proxy.txt` around the swap.

- [ ] **Step 4: Write `docs/articles/cert-hygiene/notes/lab-evidence-anchor-rotation.md`**

```markdown
# Evidence: trust-anchor rotation, staged and one-step

- **Runs:** `demos/cert-hygiene/runs/07-anchor-rotation-staged/<SS>` and `demos/cert-hygiene/runs/08-anchor-rotation-hard/<SH>` — both `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/<C>`, same harness tree
- **Versions:** <from versions.txt>
- **Lifetimes:** long-lived anchors and issuers, leaf 5m (profile `long`)

## Acceptance conditions (design § 13)
| Condition | Met? | Evidence |

## Staged rotation, step by step
<the 11 steps: time, what changed (credential state), gate result>

## S1 — no TLS-attributable failure in the staged rotation
## S1-obs — every application-visible failure, against the control (observation)
## S2 — the trust-bundle warning between steps 3 and 4

## One-step replacement
<timeline; the stage-1 per-endpoint records; the observed matrix beside the predicted one, with per-pod trust states>

## S3 — mixed-anchor pairs fail
## S4 — unrestarted proxies can't take a new-anchor leaf
<Verdict / Evidence / Notes for each>

## Evidence for the rotation guidance
<what an operator should do, step by step, and which artifact supports each point; what the one-step replacement showed goes wrong>

## What this means for the article
<bullets, with artifact paths; whether S's § 13 condition is met>
```

- [ ] **Step 5: README and commit**

Under "Start here" item 3 of `docs/articles/cert-hygiene/README.md`, add:

```markdown
   - [notes/lab-evidence-anchor-rotation.md](notes/lab-evidence-anchor-rotation.md) — rotating a trust anchor by Linkerd's staged procedure, and replacing it in one step.
```

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-anchor-rotation.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record trust-anchor rotation observations"
git push
```
