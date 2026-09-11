# Task 28: O write-up

Part of the [slice 2 plan](README.md). Read its Global Constraints first, then [`notes/lab-evidence-reading-guide.md`](../../../articles/cert-hygiene/notes/lab-evidence-reading-guide.md). This is where O's hypotheses are judged; nothing in `runs/` is edited.

**Goal:** Judge O1–O3 (design § 4) against the valid O run and the control, check O's acceptance condition (design § 13), and record the facts Task 32's R/O/A comparison needs. Write `docs/articles/cert-hygiene/notes/lab-evidence-identity-outage.md`.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-identity-outage.md`
- Modify: `docs/articles/cert-hygiene/README.md` ("Start here" list)

**Interfaces:**
- Consumes: run `O` (Task 22), control `C`, Task 18 helpers (`S=demos/cert-hygiene/scripts`).
- Produces: the evidence note, including a "For the comparison" section with the rows Task 32 needs.

**Judgement rules:** as in the reading guide. O2 is marked **open** in the design; judge it from the no-restart window only, before any restart stage.

- [ ] **Step 1: Facts**

Run: `cat $O/validity.txt; grep harness_tree $O/git-state.txt $C/git-state.txt; grep -E ' (t_mark|fault|fault-identity-down|applied|rolled|recover-identity-up|identity-pod|stage|restart|gate|done)' $O/timeline.log`
Expected: valid at the control's tree.

- [ ] **Step 2: O's acceptance condition (design § 13)**

- **The credential and configuration invariant holds:** `head -n 3 $O/credential-plan.txt` (`result=ok`, one observed state), and `grep -h 'deploy linkerd/linkerd-identity' $O/controlplane/*.txt | awk '{print $NF}' | sort | uniq -c` prints **one** `template_sha256=` value (the replica count changes; the template must not).
- **The outage outlasts the leaf window:** the time from `fault-identity-down` to `recover-identity-up` exceeds 320 s (5-minute leaf plus 20 s skew); quote both markers.
- **The no-restart recovery window is evaluated before any restart stage:** `stage stage1-norestart` precedes `restart stage2-client-a` in `timeline.log`, and `gates/stage1-norestart.txt` has its samples.

- [ ] **Step 3: Evidence per hypothesis**

- **O1 (proxies keep working until their current leaf expires; then new connections fail):** each proxy's leaf expiry during the outage: `bash $S/pod-series.sh $O probe-tcp-new control_identity_cert_expiration_timestamp_seconds` (and `probe-tcp-new-b`, `server`), read at the last tick before `fault` and during `post-N`. The first failure per pair: `bash $S/probe-lines.sh $O probe-tcp-new <fault UTC> <recover-identity-up UTC> | grep -m1 ' fail '` (and `probe-tcp-new-b`). Compare each first failure with the later of the pair's two leaf expiries; the bound is leaf lifetime plus skew after the outage start.
- **O2 (after identity returns, expired proxies re-certify with no restart):** over the `stage1-N` ticks, `bash $S/pod-series.sh $O probe-tcp-new control_identity_cert_refresh_timestamp_seconds` and the `{result="ok"}` refresh counter, for the proxies whose leaves expired during the outage; the `stage1-norestart` samples (`bash $S/gate-table.sh $O`); and those proxies' logs in `logs/pre-stage2/*-linkerd-proxy.txt` after `recover-identity-up`. Confirmed if refresh times move past `recover-identity-up` and the no-restart samples succeed; falsified if they stay expired through the window.
- **O3 (pods created during the outage never become Ready until identity returns):** the Ready condition and container statuses in `pods/post-*-probe-new-*.yaml` and `pods/post-*-restart-target-*.yaml`, the `Events:` in the matching `-describe.txt`, and the first `pods/stage1-*` snapshot where they are Ready, if any.
- **Control-plane identity:** from `controlplane/fault-before.txt`, `fault-after.txt` and `recover-identity-up.txt`, quote the identity pod's UID before and after: recovery ran in a new identity process while the credentials stayed the same.

- [ ] **Step 4: Write `docs/articles/cert-hygiene/notes/lab-evidence-identity-outage.md`**

```markdown
# Evidence: identity-service outage

- **Run:** `demos/cert-hygiene/runs/09-identity-outage/<O>` — `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/<C>`, same harness tree
- **Versions:** <from versions.txt>
- **Lifetimes:** long-lived anchor and issuer, leaf 5m; outage 900 s
- **T_mark (identity scaled to zero):** <UTC>

## Acceptance conditions (design § 13)
| Condition | Met? | Evidence |

## Timeline

## O1 — proxies work until their current leaf expires
## O2 — expired proxies re-certify on their own after identity returns (open question)
## O3 — pods created during the outage never become Ready until identity returns
<Verdict / Evidence / Notes for each>

## The restart stages after recovery
<gate-table cells beside the control's>

## For the comparison with issuer and anchor expiry
- Fault: …
- Was the signer valid? …
- Could workloads reach the identity service? …
- How failure spread: …
- What recovery took: …
- What linkerd check showed: …

## What this means for the article
<bullets for the identity-outage row, with artifact paths; whether O's § 13 condition is met>
```

- [ ] **Step 5: README and commit**

Under "Start here" item 3 of `docs/articles/cert-hygiene/README.md`, add:

```markdown
   - [notes/lab-evidence-identity-outage.md](notes/lab-evidence-identity-outage.md) — what happened while the identity service was down, and after it came back.
```

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-identity-outage.md docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record identity-outage observations"
git push
```
