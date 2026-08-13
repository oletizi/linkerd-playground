# Development Notes

---

## 2026-08-13: <!-- session title -->

**Goal:** <!-- compose: what we set out to do -->

**Accomplished:**
- <!-- compose -->

**Didn't Work:**
- <!-- compose -->

**Course Corrections:**
- <!-- compose -->

**Insights:**
- <!-- compose -->

**Quantitative (auto-derived from git; verify before publishing):**
- Commits: 47
  - docs(spiffe-demo): record the clean-host replay in the Linux runlog
  - fix(spiffe-demo): repair the documented path; remove the CLI beats (#33)
  - Merge pull request #32 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): retitle demo README around SPIFFE/external-workload onboarding
  - Merge pull request #31 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): add a grounding paragraph to the top of the demo README
  - Merge pull request #30 from oletizi/validate/linux-x86-spiffe-demo
  - Merge pull request #29 from oletizi/docs/production-notes-cleanup
  - docs: move "Made with Claude Code" to a top blockquote (drop footer)
  - docs(spiffe-demo): soften the prerequisites wording
  - fix(spiffe-demo): make the recommended Linux path work end to end
  - fix(spiffe-demo): down.sh must not report "not defined" when libvirt is unreachable
  - feat(spiffe-demo): real libvirt provisioning for the Linux single-host topology
  - docs(spiffe-demo): add MANUAL.md review; correct the ExternalWorkload claim
  - docs(spiffe-demo): lead with the verified Linux path; demote Lima to an appendix
  - fix(spiffe-demo): create+annotate mixed-env in retail apply; complete Linux runlog
  - fix(spiffe-demo): honour APP_UID in run-store-pos.sh; log F5b/F8
  - docs(spiffe-demo): record Linux substrate findings (networking, certs, docs)
  - fix(spiffe-demo): repair VM provisioning scripts; start Linux runlog
  - Merge pull request #28 from oletizi/docs/production-notes-cleanup
  - docs: add "Made with Claude Code" disclaimer to READMEs, manual, and site
  - Merge pull request #27 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): disambiguate 3c registration (SPIRE server, not Linkerd)
  - Merge pull request #26 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): gloss "pinned trust bundle" and "one-time join token" in 3b
  - Merge pull request #25 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): say where the cert commands run (cluster host, one working dir)
  - Merge pull request #24 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): clarify root vs issuer and what UpstreamAuthority does
  - Merge pull request #23 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): introduce the proxy before the identity source references it
  - Merge pull request #22 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): say WHICH process is attested (the proxy, not app/agent)
  - Merge pull request #21 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): explain "attest" — gloss in manual, Concepts section
  - Merge pull request #20 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): explain when to use one trust domain vs several
  - Merge pull request #19 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): relabel README machine references cloud -> cluster
  - Merge pull request #18 from oletizi/docs/production-notes-cleanup
  - docs(spiffe-demo): relabel the Kubernetes host [cloud] -> [cluster]
  - Merge pull request #17 from oletizi/docs/production-notes-cleanup
  - Merge pull request #16 from oletizi/docs/production-notes-cleanup
  - Merge pull request #15 from oletizi/docs/production-notes-cleanup
  - Merge pull request #14 from oletizi/docs/production-notes-cleanup
  - Merge pull request #13 from oletizi/docs/production-notes-cleanup
  - Merge pull request #12 from oletizi/docs/production-notes-cleanup
- Files changed: 33
- Backlog touched: (none)

## 2026-08-09: Deviation callouts in the SPIFFE manual; fixed the docs-site deploy pipeline

**Goal:** Add inline disclaimers to `demos/spiffe-cross-boundary/MANUAL.md` at each point
where the teaching demo deviates from best practice, deep-linking the matching section of
`PRODUCTION-NOTES.md`. Then — prompted by the operator — find and fix why those callouts
weren't reaching the published site.

**Accomplished:**
- Added **13 blockquote callouts** (`> **Demo shortcut:**`) across Parts 1–7 of the
  manual, each naming the shortcut, stating what a real system does instead, and linking
  the specific production-notes section; all 8 anchors verified to resolve.
- **Deperzonified** both docs — "Production backs the root…" → "a real system / real
  deployments…" — so they no longer imply a production incarnation of what is a teaching toy.
- Diagnosed the **stale published site** (operator caught it via the live URL): root cause
  was `netlify.toml` `base = "site"`, so Netlify only rebuilt on `site/` changes; a
  docs-only edit under `demos/` was canceled ("no content change") and never deployed.
  Fixed with a `[build] ignore` rule that rebuilds on `site/` **or** `demos/` changes.
- **Untracked** the two generated site pages (build artifacts, regenerated by `sync-docs`);
  verified from a simulated fresh checkout that the build recreates them with all callouts.
  Eliminates the source/output drift for good.
- Verified end-to-end via the Netlify CLI: a subsequent docs-only edit (PR #17) **triggered
  a build** — the exact case that was silently skipped before.

**Didn't Work:**
- My initial assertion that "Netlify regenerates on every deploy, so the site is always
  fresh" was **wrong** — no qualifying deploy had run; the callout merge was canceled for
  "no content change." I repeated it until the operator pointed at the live page.
- My first structural recommendation (untrack the generated pages) was **unsafe as first
  proposed**: under the old config those tracked `site/` files were load-bearing for
  *triggering* the deploy, so untracking would have made doc edits never publish.

**Course Corrections:**
- Stopped reasoning from inference; verified against the live site and the Netlify deploy
  history (CLI) before drawing conclusions.
- Sequenced the fix correctly: land the trigger fix (watch `demos/`) **first**, which then
  made untracking the artifacts safe — reversing my earlier "untrack now" advice.

**Insights:**
- With `base = "site"`, canonical content living **outside** base (`demos/`) is invisible
  to Netlify's change-detection unless the build's committed output under `site/` also
  changes — a silent-skip footgun that hid a correct build behind a stale deploy.
- Tracking build artifacts *to make the deploy fire* is accidental coupling. Fix the
  trigger, and the artifacts can be untracked — "make illegal states unrepresentable."

**Quantitative (auto-derived from git; verify before publishing):**
- Commits: 8
  - docs(spiffe-demo): clarify the Part 2 'before any SPIFFE' phrasing
  - chore: gitignore .netlify (local CLI state, added by netlify CLI)
  - chore(site): untrack sync-docs output (build artifacts, not source)
  - ci(netlify): rebuild when demos/ changes, not just site/
  - docs(site): regenerate demo pages so committed output matches canonical source
  - docs(spiffe-demo): add networking callout; deperzonify production notes
  - docs(spiffe-demo): reword callouts so they do not imply a production twin
  - docs(spiffe-demo): add inline deviation callouts linking to production notes
- Files changed: 7
- Backlog touched: (none)

## 2026-08-09: Validated the SPIFFE MANUAL from scratch; fixed blocking gaps; closed docs-site

**Goal:** Walk `demos/spiffe-cross-boundary/MANUAL.md` end-to-end *from scratch* to
verify it is correct as written, record every error/gap to an **independent** runlog,
then fix the manual. Also close the shipped `astro-docs-site` roadmap item.

**Accomplished:**
- Stood the demo up **by hand** following the manual on two clean Lima VMs (cluster +
  edge). Reached full end-to-end mTLS + SPIFFE-identity authorization — live: `push
  -> 200`, revoke → `403`, restore → `200`, with `src_client_id=…/store/042/inventory-sync`
  and `tls=true` on the wire (`viz tap`).
- Wrote `demos/spiffe-cross-boundary/runlog.md` — an independent, two-pass record
  (static cross-reference → live confirmation) of every finding.
- Fixed the manual (blocking + cheap + notes): 4 blocking errors (bare `spire-server`
  not on `$PATH`; `ca.crt` never copied to the store; `mixed-env` namespace never
  created; injection never enabled), 3 non-blocking (store prereq, `viz tap -o wide`
  /`src_client_id`, `useradd -M`), plus connectivity/portability/viz notes.
- Closed `design:feature/astro-docs-site` (shipped + live on Netlify).

**Didn't Work:**
- Default Lima `vz` networking gave both VMs the same isolated `192.168.5.15` — no
  VM↔VM reachability; `socket_vmnet` shared needs host sudo I didn't have. Resolved
  with Lima's `user-v2` network (userspace, no sudo, no Tailscale).
- Four of my static predictions were **refuted live** — the manual was correct where I
  feared errors: plain `kubectl apply` for the Gateway CRDs, no `mkdir` for
  `resolved.conf.d`, IP forwarding alone (no MASQUERADE), ECDSA P-256 by default.

**Course Corrections:**
- Adopted a two-pass method — cross-reference the manual against the known-good repo
  scripts first, then confirm each prediction live — so refuted predictions were
  retracted honestly instead of reported as manual "errors."

**Insights:**
- The manual is **substantively correct**; its failures are a few small-but-blocking
  doc gaps, concentrated where it delegates to the repo (namespace + injection live
  only in `echo.yaml`) or assumes a container `$PATH`.
- On a single machine, "two hosts that can reach each other" is the biggest unstated
  hurdle; `user-v2` solves it cleanly. Substrate can't surface true cross-machine
  issues (real NAT, path-MTU) — flagged in the runlog.

**Quantitative (auto-derived from git; boundary over-reached into the prior session's
merge tail — this session is the first two below):**
- Commits (this session): 2
  - chore(roadmap): close design:feature/astro-docs-site
  - docs(spiffe-demo): validate MANUAL from scratch; add runlog; fix blocking gaps
- Files changed: `ROADMAP.md`, `demos/spiffe-cross-boundary/MANUAL.md` (+49/−19),
  `demos/spiffe-cross-boundary/runlog.md` (new).
- Backlog touched: (none)

## 2026-08-09: Docs site finished; SPIRE trust-architecture change (root key off the edge)

**Goal:** Finish + deploy the demo's docs site, then act on a security/best-practice
review of the SPIFFE demo — fix the top finding (the Linkerd root CA key living on the
edge) and harden the trust model, while keeping the demo honest about what stays simplified.

**Accomplished:**
- Finished the Astro + Starlight docs site (mesh-schematic theme, landing demo-mesh,
  Netlify), deployed it, and passed it through a plain-technical-voice tone edit (PRs #6–#9).
- Ran two sub-agent reviews (exploitable security holes + production best-practice
  deviations) → the honest `PRODUCTION-NOTES.md` disclaimer (PR #10); preserved the raw
  reviews durably under `docs/superpowers/reviews/`.
- Designed the SPIRE change via brainstorming → **two** third-party review rounds →
  approved design; wrote an 11-task implementation plan.
- Implemented and **verified live on the two-VM demo**: SPIRE server → in-cluster
  StatefulSet (root as a read-only Secret; NodePort :30081 firewalled to Tailscale);
  agent-only edge (pinned bundle, `discover_workload_path`); non-root proxy (uid 2102)
  attested by `unix:uid:2102`+`unix:path`; app-scoped iptables; SVID
  `…/store/042/inventory-sync`; dashboard identity-provenance panel. **Root key is off the
  edge.** PR #11.

**Didn't Work:**
- Edge Lima VM (2 CPU/4 GiB) sshd reset connections under load; a VM reboot cleared it.
- The SPIRE agent reused a **stale node SVID** from the previous server → `PermissionDenied`.
  Fix: clear the agent keystore on enrollment (now baked into `install-spire-agent.sh`).
- Guessed the SPIRE image tag `1.11.2` (wrong) → pinned to the real current `1.15.2` and
  matched the edge agent to it.
- `pgrep -f` repeatedly self-matched my own command strings (false positives) — use `pgrep -x`.

**Course Corrections:**
- Paused ad-hoc prototyping to write a proper **design before executing** (at the user's
  direction); the two review rounds caught a real bug (`discover_workload_path` is required
  for the `unix:path` selector) and forced honest re-scoping of the security claims.
- Nearly built the "dedicated intermediate on the edge" fix before realizing the live root
  is `pathlen:1` → that would force **re-rooting the whole cluster**. Option 2 (server in
  the cluster) avoids it and removes signing material from the edge entirely.
- Branch was cut from `main` (which lacked PR #10's `PRODUCTION-NOTES`) → merged the
  disclaimer branch in so the doc edits had real files; **PR #11 supersedes #10**.

**Insights:**
- Governing principle (endorsed): **simplify the operational machinery, not the trust
  model** — fix trust-model weaknesses (root-key custody, workload attestation, bootstrap
  authentication); keep + document operational simplifications (single-node/sqlite,
  join-token enrollment, in-cluster Secret root storage, the Void-button RBAC).
- In Linkerd mesh expansion the attested workload is the **proxy**, not the app; on a bare
  host the iptables redirect must be **app-uid-scoped**, not "all but proxy."
- Be honest about boundaries: uid+path is least-privilege isolation between ordinary
  processes, **not** a defense against host-root; an in-cluster Secret is not HSM/offline-root.

**Quantitative (corrected — auto-derivation reported 0; boundary defaulted wrong):**
- Commits on `design/spire-trust-architecture` vs `origin/main`: **16** — design (3),
  plan (1), implementation (11), preserved reviews (1). **35 files, +3038 / −478.**
- PRs this session: #6–#9 (docs site) merged; #10 (disclaimer) folded into **#11** (the
  SPIRE change, open, verified live).
- Backlog touched: (none tracked via backlog).
