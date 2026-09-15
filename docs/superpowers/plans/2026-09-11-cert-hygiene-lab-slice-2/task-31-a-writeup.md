# Task 31: A write-up

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where A's hypotheses are judged; nothing in `runs/` is edited.

**Goal:** Judge A1–A5 (design § 6) against the valid A run and the control, check A's acceptance condition (design § 13), and record the facts for Task 33's R/O/A comparison. Write `docs/articles/cert-hygiene/notes/lab-evidence-anchor-expiry.md`.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-anchor-expiry.md`
- Modify: `docs/articles/cert-hygiene/README.md` ("Start here" list; status)

**Interfaces:**
- Consumes: run `A` (Task 25), control `C` (Task 20), `S=demos/cert-hygiene/scripts`.
- Produces: the evidence note, including a "For the comparison" section.

**Judgement rules:** as in the reading guide. A's fault is the anchor's own expiry, so T_mark is exact. A5 is an inference to test, not an assumption: say which stage the canary was proven in (Ready, injected, carrying the new bundle, with a leaf obtained after it started), and whether stage 1's own rollouts had already restarted identity.

- [ ] **Step 1: Facts**

Run: `cat $A/validity.txt; grep harness_tree $A/git-state.txt $C/git-state.txt; grep -E ' (t_mark|applied|rolled|recover|a-stage[0-9][a-z-]*|a-canary|restart|gate|done)' $A/timeline.log; grep -iE 'not after' $A/certs/trust-anchor.txt $A/certs/issuer-initial.txt`
Expected: valid at the control's tree; T_mark equals the anchor's `notAfter`; the issuer's `notAfter` is later.

- [ ] **Step 2: A's acceptance condition (design § 13)**

- **Per-proxy final-leaf timing:** the table of Step 3's A2 exists for every lab proxy.
- **Identity CSR evidence:** Step 3's A1 quotes identity log lines and events.
- **Checks:** Step 3's A4 quotes the rows before and after T_mark.
- **The named recovery stages exist, including whether an identity/control-plane restart was needed:**
  - markers `a-stage1-apply` through `a-stage5`;
  - `recover/linkerd-upgrade.txt` ending `[exit 0]`;
  - `controlplane/a-stage1-before.txt` and `-after.txt`;
  - the `a-canary` lines with their `recover/*-canary-*-state.txt` files;
  - either the `a-stage3 not needed` marker or the `recover/a-stage3-*` files.

- [ ] **Step 3: Evidence per hypothesis**

- **A1 (identity refuses every CSR from T_mark on):** `grep -E 'could not process CSR|issued certificate' $A/logs/pre-recover/identity.txt | head -n 5`. Compare the first refusal's time with T_mark, and check for any issuance line between T_mark and `a-stage1-apply` (there should be none). Then `grep -c IssuerValidationFailed $A/events/*.txt`.
- **A2 (each pair works until its own final pre-expiry leaf expires; failures staggered):**
  - For each lab proxy, from the first `post-N` tick: `bash $S/pod-series.sh $A '' control_identity_cert_refresh_timestamp_seconds | awk '$1 == "post-1"'`, and the same for `control_identity_cert_expiration_timestamp_seconds` (an empty prefix matches every lab pod; the tick is field 1, with no leading space, so `awk '$1 == "post-1"'` is what matches it — `grep ' post-1 '` matches nothing). The refresh value before T_mark is the last successful issuance; the expiration value is that leaf's `notAfter`.
  - Build a table: proxy, last issuance (T+), leaf `notAfter` (T+).
  - The first failure per pair: `bash $S/probe-lines.sh $A probe-tcp-new <t_mark UTC> | grep -m1 ' fail '` (and the same for `probe-tcp-new-b` and `probe-http`). Compare each pair's first failure with the earlier of its two endpoints' leaf expiries.
  - Give the spread of leaf expiries and of first failures across proxies. Staggered means the spread is well above one probe interval.
- **A3 (new connections fail once the relevant leaves expire; new pods never become Ready):** the pairs' failures after their leaves expire (from A2), and the Ready condition in `pods/post-*-probe-new-*.yaml` through the window.
- **A4 (`linkerd check` goes fatal on "trust anchors are within their validity period"):** `grep -h -A1 'trust anchors are within their validity period' $A/checks/fault-minus10-check.txt $A/checks/fault-plus10-check.txt`.
- **A5 (recovery needs identity restarted):**
  - Did the upgrade's own rollouts restart identity? Compare the identity pod's UID in `controlplane/a-stage1-before.txt` and `a-stage1-after.txt`.
  - When was the canary proven? The `a-canary` lines and `recover/a-stage2-canary-*-state.txt`: proven in `a-stage2`, only in `a-stage3`, or never. A `state=no-proxy` line means the canary was admitted without a proxy and re-applied; report it, because it means the injector was not serving at that moment.
  - `recover/a-stage3-stale.txt`, if stage 3 ran.
  - Identity log lines after `a-stage1-apply` (`logs/a-stage2/identity.txt`).
  - The stage-4 gate: `bash $S/gate-table.sh $A`.

- [ ] **Step 4: Write `docs/articles/cert-hygiene/notes/lab-evidence-anchor-expiry.md`**

```markdown
# Evidence: trust-anchor expiry

- **Run:** `demos/cert-hygiene/runs/06-anchor-expiry/<A>` — `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/<C>`, same harness tree
- **Versions:** <from versions.txt>
- **Lifetimes:** anchor 20m, issuer 120m (outlives the anchor), leaf 5m (profile `anchor-short`)
- **T_mark (anchor notAfter):** <UTC>

## Acceptance conditions (design § 13)
| Condition | Met? | Evidence |

## Timeline

## A1 — identity refuses every CSR from T_mark on
## A2 — each pair works until its own final leaf expires; failures are staggered
<the per-proxy table>
## A3 — new connections fail; new pods never become Ready
## A4 — linkerd check goes fatal on the anchor's validity period
## A5 — does recovery need identity restarted? (a tested inference)
<Verdict / Evidence / Notes for each>

## The recovery stages
<stage 1 to 5, what each recorded, including every canary state>

## For the comparison with issuer expiry and the identity outage
- Fault: …
- Was the signer valid? …
- Could workloads reach the identity service? …
- How failure spread: …
- What recovery took: …
- What linkerd check showed: …

## What this means for the article
<bullets for the trust-anchor row and the recovery guidance, with artifact paths; whether A's § 13 condition is met>
```

- [ ] **Step 5: README and commit**

Under "Start here" item 3 of `docs/articles/cert-hygiene/README.md`, add:

```markdown
   - [notes/lab-evidence-anchor-expiry.md](notes/lab-evidence-anchor-expiry.md) — a trust anchor expiring, how failures spread, and what recovery took.
```

In the status bullet, set the "Written up so far" sentence to: `Written up so far: the repeat of the issuer experiment, the webhook experiment, the identity-outage experiment, the linkerd check threshold experiment and the trust-anchor expiry experiment.`

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-anchor-expiry.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record trust-anchor expiry observations"
git push
```
