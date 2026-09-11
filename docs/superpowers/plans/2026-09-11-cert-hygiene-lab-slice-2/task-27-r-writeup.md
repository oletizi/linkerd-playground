# Task 27: R write-up

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then [`docs/articles/cert-hygiene/notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md) (Task 18). This is where R's hypotheses are judged; nothing in `runs/` is edited.

**Goal:** Judge R1–R4 (design § 2) against both valid R runs and the control, check R's acceptance condition (design § 13), and say which of the first issuer run's open questions the re-run answers. Write `docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry-rerun.md`.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry-rerun.md`
- Modify: `docs/articles/cert-hygiene/README.md` ("Start here" list; status)

**Interfaces:**
- Consumes: runs `RA`, `RB` (Task 21), control `C` (Task 20), the helpers `probe-lines.sh`, `pod-series.sh`, `gate-table.sh` (Task 18), the first issuer write-up `notes/lab-evidence-issuer-expiry.md`.
- Produces: the evidence note, which Task 33 cites. Its last section, "What this means for the article", lists per claim: supported / narrowed / not supported, with the artifact paths.

**Judgement rules:** confirmed (quoted evidence shows the prediction directly), falsified (quoted evidence shows something else), inconclusive (say which observation would decide it). Quote exact lines with paths relative to the run directory; times as T+N from `t_mark` (R's fault is the issuer's own expiry, so T_mark is exact); label anything from the source notes as source-derived. Where the two runs disagree, give both, and give no single verdict unless both support it.

- [ ] **Step 1: Facts every section needs**

Let `RA`, `RB`, `C` be the run directories (run labels, not hypothesis IDs) and `S=demos/cert-hygiene/scripts`. Every command below is shown for `RA`; run it for `RB` too.

Run: `cat $RA/validity.txt; grep harness_tree $RA/git-state.txt $C/git-state.txt; grep -E ' (t_mark|recover|recover-apply|issuer-updated|stage|restart|gate|done)' $RA/timeline.log; grep -E '^(linkerd_cli_version|linkerd_controller_image|kubernetes_version|config_PROFILE|config_POST_EXPIRY_WINDOW_S)=' $RA/versions.txt`
Expected: `evidence_valid=yes`; the same `harness_tree_sha256` in both runs and the control. If not, stop: Task 21 isn't done.

- [ ] **Step 2: R's acceptance condition (design § 13), for each run**

- **Workload `linkerd-proxy` logs:** `grep -h 'proxy=yes' $RA/logs/pre-stage2/pods.txt` and `ls $RA/logs/pre-stage2/ | grep -c 'linkerd-proxy.txt$'`: every listed lab pod has one.
- **Per-pod continuous probe history:** `bash $S/probe-lines.sh $RA probe-tcp-new | awk 'NR == 1 { print } END { print }'` prints the first and last lines: they must span from before `tick baseline` to after `tick verify`, across the pods the stages replaced (listed in `probes/*/pods.txt`).
- **Gated recovery stages:** `bash $S/gate-table.sh $RA` lists `stage1-norestart`, `stage2-client-a`, `stage3-server`, `stage4-all`.
- **Established-connection claims name protocol and duration:** met by R4's section if it states both.

- [ ] **Step 3: Evidence per hypothesis**

- **R1 (HTTP reuses a pre-T_mark connection):** `bash $S/pod-series.sh $RA probe-http tcp_open_total | grep 'direction="outbound"' | grep 'server.lab.svc.cluster.local:8080'`. Compare the value at `fault-minus10` with every `post-N` tick up to the `stage3-server` restart. Count HTTP outcomes after T_mark: `bash $S/probe-lines.sh $RA probe-http <t_mark UTC> <stage2 restart UTC> | awk '{print $4}' | sort | uniq -c`. Confirmed if the counter does not rise while `probe-http` keeps succeeding.
- **R2 (pre-existing proxies' TLS handshake to identity fails):** `grep -hiE 'identity|handshake|certif|valid' $RA/logs/pre-stage2/*-linkerd-proxy.txt | head -n 30`, and `grep -m5 'could not process CSR' $RA/logs/pre-recover/identity.txt`. Classify what the workload proxies log after the issuer was replaced: handshake errors toward the identity service, or certificate-validation errors. Quote one line of each kind found. Cross-check with each proxy's `control_identity_cert_refreshes_total{result="error"}` over the `stage1-N` ticks: `bash $S/pod-series.sh $RA probe-tcp-new 'control_identity_cert_refreshes_total'`.
- **R3 (only fresh/fresh cells succeed):** `bash $S/gate-table.sh $RA`. Label each endpoint fresh or stale from its `leaf` line: fresh when `refresh` is after the `recover-apply` marker's time. Build the observed matrix beside the predicted one (design § 2), with each cell's `ok/fail` counts. A timed-out gate's cell is unclassified: quote its `unmet=`. Put the control's cells for the same stages beside them: `bash $S/gate-table.sh $C`.
- **R4 (the stream survives the 30-minute window):** `bash $S/probe-lines.sh $RA probe-tcp-stream | grep -E ' (connect|closed) '`, and the last `ok` before any `closed`. State the protocol (opaque TCP through the mesh) and the measured duration from T_mark to the last `ok`. Note whether the connection ended at the `stage3-server` restart (by design) or earlier.

- [ ] **Step 4: Write `docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry-rerun.md`**

Use this structure, filling every section from Steps 1–3:

```markdown
# Evidence: identity issuer expiry, re-run twice

- **Runs:** `demos/cert-hygiene/runs/05-issuer-expiry/<RA>` and `<RB>` — both `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/<C>` — `evidence_valid=yes`, same harness tree (`harness_tree_sha256=<hex>`)
- **Versions:** <from versions.txt>
- **Lifetimes:** anchor 720h, issuer 15m, leaf 5m (profile `issuer-short`); replacement issuer 8760h; post-expiry window 1800 s
- **T_mark (issuer notAfter):** <RA UTC>, <RB UTC>

## Acceptance conditions (design § 13)
| Condition | first run | second run | Evidence |

## Timeline
<one table per run: UTC, T+, marker>

## R1 — HTTP reuses a pre-expiry proxy connection
**Verdict:** … **Evidence:** … **Notes:** …

<the same form for R2, R3 (with the observed-versus-predicted matrix and the control's cells), R4>

## Agreement between the two runs

## What the re-run answers from the first issuer run's open questions
<one bullet per "Still open" item in findings.md that this evidence bears on: answered / narrowed / still open>

## What this means for the article
<one bullet per claim, with artifact paths; state that R's § 13 condition is or isn't met>
```

- [ ] **Step 5: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, under "Start here" item 3, add after the `lab-evidence-issuer-expiry.md` line:

```markdown
   - [notes/lab-evidence-issuer-expiry-rerun.md](notes/lab-evidence-issuer-expiry-rerun.md) — two repeats of the issuer-expiry experiment with fuller recording, and which open questions they answer.
```

In the "Second round of lab experiments" status bullet, set the sentence after "every experiment has been run." to: `Written up so far: the repeat of the issuer experiment. The other write-ups are in progress; until each is done, its results are not findings.`

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry-rerun.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record issuer-expiry re-run observations"
git push
```
