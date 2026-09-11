# Task 10: Record observations

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** Judge H1–H8 (spec § 4.2) and the unpredicted HTTP observation against the valid #5 run. Compare the control where § 4.4 says a human must. Write the result into the article folder, citing evidence by path. This is the only place hypotheses are judged (spec § 5). Nothing in `runs/` is edited.

**Files:**
- Create: `docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry.md`
- Modify: `docs/articles/cert-hygiene/README.md` (file list + status)
- Modify: `docs/superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md` (§ 8 "Settled by" cells for the rows #5 settles)

**Interfaces:**
- Consumes: the valid `runs/05-issuer-expiry/<stamp>/` and the matching `runs/00-baseline-control/<stamp>/` (Task 9)
- Produces: `evidence-05-issuer-expiry.md`, which article drafting cites.

**Judgement rules:**
- **Confirmed:** quoted evidence shows the predicted behaviour directly.
- **Falsified:** quoted evidence shows different behaviour.
- **Inconclusive:** the evidence can't decide it. Say what extra observation would.
- Every verdict quotes the exact lines it rests on, with the file path relative to the run directory, and times related to `T_mark` (from the `t_mark` line in `timeline.log`).
- Label source-derived explanations as such. Don't present them as observed.

- [ ] **Step 1: Gather the facts every section needs**

Let `R=demos/cert-hygiene/runs/05-issuer-expiry/<stamp>` and `C=` the control run.

Run: `grep -E ' (t_mark|applied|rolled|recover|recover-apply|issuer-updated|restart|recovered|recovery|done) ' $R/timeline.log; grep notAfter $R/certs/issuer-initial.txt; cat $R/validity.txt $C/validity.txt`
Expected: `T_mark` equals the issuer's `notAfter`, and both runs say `evidence_valid=yes`. If either isn't valid, stop: Task 9 isn't done.

- [ ] **Step 2: Extract the evidence per hypothesis**

Use these commands. Each result goes into the matching section of Step 3.

- **H1 (refresh cadence):** `for f in $R/metrics/pre-*.txt $R/metrics/fault-*.txt; do echo "$f $(grep -m1 sampled_at_epoch "$f")"; grep -E 'refresh|expiration' "$f" | head -n 6; done`. The refresh timestamps per pod should get closer together as `T_mark` nears.
- **H2 (simultaneous leaf expiry):** from `$R/metrics/fault-minus10.txt`, every `$LEAF_EXPIRY_METRIC` value compared with `T_mark`.
- **H3 (identity refuses CSRs):**
  - `grep -c IssuerValidationFailed $R/events/*.txt`
  - `grep -m3 'could not process CSR' $R/logs/pre-recover/identity.txt`
  - the identity pod's READY column in `$R/pods/post-*.txt`

  **Competing prediction (source):** the identity pod's proxy requires TLS on port 8080 (`requireTLSOnInboundPorts "8080"` in the identity chart), and its own leaf also expired at `T_mark`. Other proxies' CSRs may therefore fail at the TLS handshake and never reach the controller, in which case `IssuerValidationFailed` comes only from the identity pod's own proxy. To tell the two apart, check which proxies' logs show a handshake error against which show a validation error: `$R/logs/pre-recover/identity-proxy.txt` and the `*-linkerd-proxy.txt` files.
- **H4 (retry every 10s):** `grep -h 'Failed to obtain identity' $R/logs/pre-recover/*-linkerd-proxy.txt | head`. Compute the spacing between consecutive timestamps for one pod.
- **H5 (new connections fail at T_mark):** the first `fail` after `T_mark` in `$R/probes/probe-tcp-new.log`, and the last `ok` before it.
- **HTTP (no prediction):** the same boundary in `$R/probes/probe-http.log`. Report it as observed.
- **H6 (established session survives):**
  - `grep -c ' connect ' $R/probes/probe-tcp-stream.log` should print 1.
  - The `ok` lines after `T_mark` carry the same `conn=`.
  - Look for any `closed` or `end-of-stream` line, and note when it happened.
- **H7a / H7b (post-expiry pods never Ready; the rollout stalls):** the `status.conditions` and `containerStatuses` in `$R/pods/post-*-probe-new-*.yaml` and `$R/pods/post-*-restart-target-*.yaml`, plus the `Events:` in the matching `-describe.txt`. Also `tail -n 2 $R/pods/post-*-rollout.txt`. Show that the old `restart-target` pod stayed Running.
- **H8 (recovery chain without restarts):**
  - `resourceVersion` across `$R/secrets/pre-recover-identity-issuer.txt` and `$R/secrets/recover-*-identity-issuer.txt`
  - `issuer_cert_ttl_seconds` across `$R/metrics/post-*.txt` and `$R/metrics/recover-*.txt`
  - the `issuer-updated` marker
  - leaf-metric values after it
  - probe recovery times
  - which `recovery …` line was reached, and any `restart` markers

  **Confound to rule out:** `linkerd upgrade` re-renders the control plane, so control-plane pods may have restarted for that reason alone. Compare the `linkerd` namespace rows (AGE, RESTARTS) across `$R/pods/post-*.txt` and `$R/pods/recover-*.txt` before attributing the recovery to a hot reload.
- **Control comparison (§ 4.4):** list every `‼` line in `$R/checks/*.txt` that isn't a certificate-lifetime warning, and confirm the same line appears in `$C/checks/*.txt`. Explain any that don't.

- [ ] **Step 3: Write `docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry.md`**

Use this structure, filling every section from Step 2:

```markdown
# Evidence: scenario #5, identity issuer expiry

- **Run:** `demos/cert-hygiene/runs/05-issuer-expiry/<stamp>` — `evidence_valid=yes`
- **Control:** `demos/cert-hygiene/runs/00-baseline-control/<stamp>` — `evidence_valid=yes`, same harness tree
- **Versions:** <linkerd_cli_version, linkerd_controller_image, kubernetes_version from versions.txt>
- **Lifetimes:** anchor <ANCHOR_LIFETIME>, issuer <ISSUER_LIFETIME>, leaf <LEAF_LIFETIME>
- **T_mark (issuer notAfter):** <UTC>

## Timeline
<the Step 1 markers, with times relative to T_mark>

## H1 — refresh cadence approaching T_mark
**Verdict:** confirmed | falsified | inconclusive
**Evidence:** <quoted lines, with paths>
**Notes:** <what it means; label anything source-derived>

<one section in this form for each of H2, H3 (including the competing prediction), H4, H5, the HTTP observation (no verdict, "Observed:" instead), H6, H7a, H7b, H8 (including the control-plane restart confound)>

## Control comparison
<non-certificate warnings in both runs, or the explanation for any difference>

## What this means for the article brief
<one bullet per spec section 8 row that #5 settles, stating what the evidence supports; mark every claim that still rests on source reading alone>
```

- [ ] **Step 4: Update the spec and the article README**

In the spec's § 8 table, set the "Settled by" cell of the issuer-expiry row, and the `#5` part of the `linkerd check` row, to `#5 — see docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry.md`.

In `docs/articles/cert-hygiene/README.md`:
- Add to the file list: `- [evidence-05-issuer-expiry.md](evidence-05-issuer-expiry.md) — hypotheses H1–H8 judged against the valid issuer-expiry run, with quoted evidence.`
- Set the `#5 Issuer expiry` row to `Observations recorded: evidence-05-issuer-expiry.md`.
- Set the `Lab harness` row to `Built (plan complete)`.

- [ ] **Step 5: Commit**

```bash
git add docs/articles/cert-hygiene/notes/lab-evidence-issuer-expiry.md docs/articles/cert-hygiene/README.md docs/superpowers/specs/2026-09-10-cert-hygiene-demo-lab-design.md
git commit -m "cert-hygiene record issuer-expiry observations"
git push
```
