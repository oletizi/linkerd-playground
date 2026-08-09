# Development Notes

---

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
