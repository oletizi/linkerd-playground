# Task 30: K write-up

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where K1 is judged; nothing in `runs/` is edited.

**Goal:** Judge K1 (design § 5) against the valid K run, with R's 15-minute case completing the comparison, check K's acceptance condition (design § 13), and write `docs/articles/cert-hygiene/notes/lab-evidence-check-threshold.md`.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-check-threshold.md`
- Modify: `docs/articles/cert-hygiene/README.md` ("Start here" list; status)

**Interfaces:**
- Consumes: run `K` (Task 24), runs `RA` and `RB` (Task 21), `S=demos/cert-hygiene/scripts`.
- Produces: the evidence note, cited by Task 33 for the 60-day warning statements.

- [ ] **Step 1: Facts and K's acceptance condition (design § 13)**

Run: `cat $K/validity.txt $K/k-remaining.txt; cat $K/k/minus-calc.txt $K/k/plus-calc.txt; grep -E '^(linkerd_cli_version|linkerd_controller_image)=' $K/versions.txt`
Expected: `evidence_valid=yes`; `k-remaining.txt` starts `result=ok`. The condition is met when both measured remaining-validity values (`issuer_not_after_epoch` minus the start or end epochs) and the four transcripts put the −10m checks under 5 184 000 s and the +10m checks over it.

- [ ] **Step 2: Evidence for K1**

- The issuer rows of all four transcripts: `grep -h -A2 -E 'issuer cert (is valid for at least 60 days|is within its validity period)' $K/k/minus-check.txt $K/k/plus-check.txt $K/k/minus-check-proxy.txt $K/k/plus-check-proxy.txt`. Record each headline's mark (`‼` or `√`) and the detail line.
- The remaining validity for each command, computed from the calc files, in seconds and as days/hours/minutes. Show the subtraction: `issuer_not_after_epoch − check_started_epoch` for minus, `issuer_not_after_epoch − check_ended_epoch` for plus.
- **R's 15-minute case:** from each R run, the same rows in `checks/baseline-check.txt`, and the remaining validity at that tick: `certs/issuer-initial.txt`'s `notAfter` minus the `tick baseline` time.
- K1 is confirmed if the −10m issuer shows the same `‼ issuer cert is valid for at least 60 days` headline as the 15-minute one, and the +10m issuer shows `√`. The threshold then lies between the two recorded remaining-validity values.

- [ ] **Step 3: Write `docs/articles/cert-hygiene/notes/lab-evidence-check-threshold.md`**

```markdown
# Evidence: where linkerd check's 60-day issuer warning starts

- **Run:** `demos/cert-hygiene/runs/20-check-threshold/<K>` — `evidence_valid=yes`
- **Comparison runs:** `demos/cert-hygiene/runs/05-issuer-expiry/<RA>`, `<RB>` (15-minute issuer)
- **Versions:** <from versions.txt>
- **Issuers:** 1440h − 10m (installed), 1440h + 10m (applied with the issuer-only upgrade)

## Acceptance condition (design § 13)

## The measurements
| Issuer | Command | Started / ended (UTC) | Remaining at check time | Headline |

## K1 — the headline flips between the two remaining-validity values
**Verdict:** … **Evidence:** … **Notes:** source-derived: the threshold is `expirationWarningThresholdInDays = 60`, not configurable (source notes § 7)

## What this means for the article
<bullets: what the headline can and cannot tell an operator, with artifact paths>
```

- [ ] **Step 4: README and commit**

Under "Start here" item 3 of `docs/articles/cert-hygiene/README.md`, add:

```markdown
   - [notes/lab-evidence-check-threshold.md](notes/lab-evidence-check-threshold.md) — `linkerd check`'s 60-day issuer warning measured just either side of the boundary.
```

In the status bullet, set the "Written up so far" sentence to: `Written up so far: the repeat of the issuer experiment, the webhook experiment, the identity-outage experiment and the linkerd check threshold experiment.`

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-check-threshold.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record linkerd check threshold observations"
git push
```
