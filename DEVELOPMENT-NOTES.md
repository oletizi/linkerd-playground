# Development Notes

---

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
