# Task 27: W write-up

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where W's hypotheses are judged; nothing in `runs/` is edited.

**Goal:** Judge W1–W4 and record observation W6 (design § 3) against the Ignore and Fail runs, check W's acceptance condition (design § 13), and write `docs/articles/cert-hygiene/notes/lab-evidence-webhook-expiry.md`.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-webhook-expiry.md`
- Modify: `docs/articles/cert-hygiene/README.md` ("Start here" list)

**Interfaces:**
- Consumes: runs `WI` and `WF` (Task 21), control `C` (Task 19), Task 18 helpers (`S=demos/cert-hygiene/scripts`).
- Produces: the evidence note, cited by Task 32.

**Judgement rules:** confirmed / falsified / inconclusive as in the reading guide. Quote exact responses; W2's error text is a finding, not a prediction. The k3s journal is supplementary only: a missing journal line is a result, never a falsification.

- [ ] **Step 1: Facts**

For each of `WI`, `WF`: `cat $WI/validity.txt; grep harness_tree $WI/git-state.txt $C/git-state.txt; grep -E ' (t_mark|webhook-expired|admission-probes|recover-[a-z]+|propagated|done) ' $WI/timeline.log; grep failurePolicy $WI/webhooks/baseline.txt`
Expected: both valid at the control's tree; three `webhook-expired` markers; `failurePolicy=Ignore` in `WI` and `Fail` in `WF`.

- [ ] **Step 2: W's acceptance condition (design § 13), per run**

- **Each webhook's expiry phase is recorded:** the three `webhook-expired` markers, with the first tick after each, and that tick's `webhooks/<tick>.txt` and `checks/<tick>-check.txt`.
- **A healthy baseline proves each probe:** `cat $WI/admission-baseline.txt` (`result=ok`, five `ok:` lines).
- **Exact responses and object states:** `for f in $WI/admission/*/*.response.txt; do printf '%s %s\n' "${f#"$WI"/admission/}" "$(tail -n 1 "$f")"; done` lists every attempt's exit status by phase. `grep -L 'name: linkerd-proxy$' $WI/admission/post-*/inject-probe-*.observed.yaml` lists pods admitted without a proxy.
- **Checks and recovery-branch artifacts:** `recover/branch.txt`, `recover/plain-facts.txt`, `recover/plain-manifest.yaml`, `recover/plain-propagation.txt`, `controlplane/recover-plain.txt`, `admission/recovered/*-recover-plain.*`, and the `supplied` counterparts for branches ii and iii.

- [ ] **Step 3: Evidence per hypothesis**

Let the phases be: before T1; T1–T2 (proxy-injector expired); T2–T3 (proxy-injector and policy-validator expired); after T3 (all three). Map each `post-NNNN` directory to a phase by NNNN (seconds after T1) against the markers' times.

- **W1 (Ignore: each expired webhook's probe gets through):** in `WI`, for each phase from its webhook's expiry on: (a) `inject-probe-*` created (`[exit 0]`) and its observed pod has no `linkerd-proxy`; (b) `policy-invalid-*` accepted (`[exit 0]`) once the policy-validator has expired; (c) `serviceprofile-invalid-*` accepted once the sp-validator has expired. Before each webhook's own expiry, its probe must still behave as at baseline: that is what isolates each webhook.
- **W2 (Fail: each expired webhook's probes are rejected, valid ones included):** in `WF`, the same phases, with each affected attempt's response. Quote the exact error text of one attempt per webhook, e.g. `grep -h 'Error' $WF/admission/post-*/inject-probe-*.response.txt | head -n 1`.
- **W3 (mesh traffic unaffected):** `for p in probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream; do bash $S/probe-lines.sh $WI $p | awk '$4 != "ok"' | head; done` for both runs, limited to lines before the `recover-delete` marker; compare with `C`'s probe lines over the same interval.
- **W4 (`linkerd check` goes fatal on each "… webhook has valid cert" row after that webhook's expiry):** `grep -h 'webhook has valid cert' $WI/checks/<first tick after each marker>-check.txt`, and the same rows one tick before each marker.
- **W6 (observation: which recovery branch a plain upgrade produces for supplied credentials):** `cat $WI/recover/branch.txt $WF/recover/branch.txt`; quote the facts lines, the propagation log's last line, and `grep -c redacted recover/plain-manifest.yaml` as proof the manifest was recorded. For ii and iii, quote `recover/supplied-facts.txt`. No verdict, "Observed:" instead.
- **Supplementary:** `grep -c -i 'failed calling webhook' $WI/logs/final/k3s-journal.txt $WF/logs/final/k3s-journal.txt`, with one quoted line if any.

- [ ] **Step 4: Write `docs/articles/cert-hygiene/notes/lab-evidence-webhook-expiry.md`**

```markdown
# Evidence: webhook serving certificates expiring one at a time

- **Runs:** `demos/cert-hygiene/runs/02-webhook-expiry-ignore/<WI>` (failurePolicy Ignore) and `demos/cert-hygiene/runs/02-webhook-expiry-fail/<WF>` (Fail) — both `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/<C>`, same harness tree
- **Versions:** <from versions.txt>
- **Credentials:** lab-supplied webhook serving certificates (not how Linkerd normally runs), lifetimes 15m / 25m / 35m; anchor and issuer long-lived
- **T1, T2, T3:** <UTC per run>

## Acceptance conditions (design § 13)
| Condition | Ignore | Fail | Evidence |

## Phases
<per run: phase, window, which webhooks have expired, the attempts in it>

## W1 — with Ignore, each expired webhook's probe gets through
## W2 — with Fail, each expired webhook's probes are rejected
## W3 — mesh traffic is unaffected
## W4 — linkerd check goes fatal per webhook
<Verdict / Evidence / Notes for each>

## W6 — recovery branch (observation)
**Observed:** …

## Supplementary: the k3s journal

## What this means for the article
<bullets for the "pods without a proxy" and "validation skipped" rows, with artifact paths; whether W's § 13 condition is met; the credential-model caveat (lab-supplied static certificates) on every claim about recovery>
```

- [ ] **Step 5: README and commit**

Under "Start here" item 3 of `docs/articles/cert-hygiene/README.md`, add:

```markdown
   - [notes/lab-evidence-webhook-expiry.md](notes/lab-evidence-webhook-expiry.md) — webhook certificates expiring one at a time, under each failure policy, and how recovery went.
```

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-webhook-expiry.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record webhook-expiry observations"
git push
```
