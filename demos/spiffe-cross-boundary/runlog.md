# SPIFFE cross-boundary demo — manual validation runlog

An **independent** record of an attempt to stand up the demo *from scratch* by
following [`MANUAL.md`](MANUAL.md) **exactly as written**, to find where the manual
is wrong, incomplete, or assumes unstated context.

- **Method:** full live, clean start. Two Lima VMs on a single macOS host stand in
  for the manual's "two Linux hosts" (`cluster` = the Kubernetes/cloud host, `edge`
  = the external store host). The manual's demo steps (Linkerd, SPIRE, proxy,
  policy) are run **by hand** inside those VMs, following the manual — not the repo's
  automation scripts. The scripts/configs are consulted only to *confirm* whether a
  manual discrepancy is real.
- **Rule:** when the manual says to run command X, run exactly X. Only after
  recording what happens do I deviate to get unblocked, and I record the deviation.

Legend: **[BLOCKER]** stops a literal follow-er cold · **[ERROR]** wrong as written
· **[GAP]** missing step/context a follower needs · **[NIT]** minor · **✓** verified
correct as written.

---

## Environment

- Host: macOS (Darwin 24.6.0), 16 GiB RAM, Apple Silicon (aarch64).
- Substrate: Lima (`vz`), Ubuntu 24.04 cloud image. `docker` + `lima` + `tailscale`
  + `kubectl` on host. `linkerd`, `step`, `spire-*` NOT on host (installed per-VM as
  the manual/substrate requires).
- Started: 2026-08-08.

**Connectivity substrate (satisfies the manual's "bring-your-own IP reachability"
precondition):** default Lima `vz` networking puts every VM on an isolated user-mode
NAT — both VMs came up as `192.168.5.15`, unable to reach each other. `socket_vmnet`
(the `shared`/bridged path) is installed but not wired up (`/opt/socket_vmnet`
missing, no lima sudoers, host sudo is password-gated). I attached Lima's **`user-v2`**
network to both VMs (userspace, no host sudo): cluster = `192.168.104.1`, edge =
`192.168.104.3`, bidirectional ping ~1 ms. So `CLUSTER_NODE_ADDR=192.168.104.1`,
`EDGE_ADDR=192.168.104.3`.

**Caveat — single host vs. the two-machine design.** The demo was originally designed
for **two separate physical machines**. This validation runs both roles as Lima VMs on
one Mac. That is a faithful stand-in for the manual's *steps*, but a single host can
**mask** genuinely cross-machine concerns (MTU/path-MTU, real NAT traversal, asymmetric
routing, clock skew, firewalling between hosts). Findings that could be substrate
artifacts are flagged **[substrate?]**.

---

> **Two passes.** Pass A is a line-by-line cross-reference of the manual against
> the repo's known-good scripts/configs (which automate the same steps) — it
> predicts where a literal follower breaks. Pass B confirms each prediction live in
> the VMs. Every finding below is tagged **[xref]** (Pass A, predicted) until
> upgraded to **[live]** (Pass B, confirmed) or **[live-refuted]**.

## Prerequisites (MANUAL "Prerequisites")

- **[GAP] [xref]** The prereqs *name* the tools (linkerd CLI edge channel, `step`,
  `spire-server`/`spire-agent`, a container runtime, `iptables`) but give **no
  install commands**. A follower on a bare Ubuntu VM must source all of them
  themselves. The repo automates each (`install-linkerd.sh` curls
  `run.linkerd.io/install-edge`; `gen-certs.sh` resolves+installs the `step` .deb;
  `install-spire-agent.sh` downloads the pinned SPIRE tarball). Reasonable for a
  "prerequisites" heading, but worth an explicit pointer.
- **[ERROR] [xref]** Prereqs say the **store** host needs "the SPIRE binaries
  (`spire-server`, `spire-agent`)". But Part 3 runs the server **in the cluster** and
  states the store "runs the **agent only**." The store never needs `spire-server`;
  listing it contradicts the body and misleads the follower into installing an
  unnecessary (and, per the security model, undesirable) binary on the less-trusted
  host.
- **[GAP] [xref]** "a Kubernetes cluster (k3s is fine)" — no install guidance, yet
  the whole manual hard-codes **k3s defaults**: pod CIDR `10.42.0.0/16`, svc CIDR
  `10.43.0.0/16`, CoreDNS `10.43.0.10`. A follower on any other cluster/CIDR must
  rewrite later literals. The repo also trims k3s (`--disable=traefik,servicelb`,
  `--write-kubeconfig-mode=644`) to fit RAM — unmentioned in the manual.
- **[GAP/portability] [live]** The hard-coded IPs are only valid on a default k3s
  install and are **not portable**: pod CIDR `10.42.0.0/16`, svc CIDR `10.43.0.0/16`,
  CoreDNS `10.43.0.10`. Confirmed matching on this k3s (v1.36.3) — but any other
  distro (kubeadm, EKS, GKE, kind) uses different ranges, and even k3s can be
  reconfigured. The manual partly mitigates (it labels them "k3s defaults" and shows
  `kubectl -n kube-system get svc kube-dns` to find CoreDNS), but Parts 2/4 then
  **reuse the literals** (`10.43.0.10`, `linkerd-dst-headless…:8086`) without
  reminding the follower to substitute their own. A non-k3s follower silently
  mis-routes. Recommend a single "discover your cluster's values" callout that the
  later parts reference by variable.

---

## Part 1 — One root of trust (cloud)

- **✓ [live]** The two `step certificate create` commands run clean; `step certificate
  inspect ca.crt` confirms **ECDSA / 256-bit** — the manual's "Linkerd requires ECDSA
  P-256, `step` uses that profile by default" claim holds.
- **✓ [live-refuted]** (manual L92) Predicted the plain `kubectl apply -f
  <gateway-standard-install.yaml>` would fail the 262144-byte client-side annotation
  limit and need `--server-side`. **It did NOT** — plain apply succeeded on k3s
  v1.36.3 (k8s 1.36) with gateway-api v1.2.1. The manual is **correct as written**;
  the repo's `--server-side` is a harmless defensive alternative, and the manual even
  matches the linkerd CLI's own printed post-install instructions. Prediction retracted.
- **✓ [live]** (manual L93-98) `linkerd install --crds`, `linkerd install` with the
  custom `--identity-*` cert files, and `linkerd check` all succeed. Client-side apply
  of the CRDs did **not** hit the annotation limit either. Part 1 is clean end-to-end.

## Part 2 — Networking prerequisite (store)

- **✓ [live-refuted]** (manual L127) Predicted `tee …/resolved.conf.d/cluster.conf`
  would fail for a missing directory. **It did NOT** — `/etc/systemd/resolved.conf.d`
  already exists on the Ubuntu 24.04 cloud image, so the manual's bare `tee` works.
  Prediction retracted (the repo's `mkdir -p` is defensive, not required here).
- **✓ [live]** (manual L125-126) `ip route add` for both CIDRs succeeded (no
  pre-existing routes on a flat start). **[NIT]** still stands: `add` would error
  `File exists` if a route were already present (overlay case) — the repo uses
  `replace`; harmless for the documented flat-LAN path.
- **✓ [live-refuted]** After only the manual's routes + cluster DNS (and k3s's own IP
  forwarding), the edge reached a **service ClusterIP** (`10.43.0.10:53` OPEN) and
  resolved `kubernetes.default.svc.cluster.local`. So the manual's claim that the
  cloud host "must have IP forwarding on" is **sufficient** — no MASQUERADE/SNAT
  needed, contrary to my `[substrate?]` worry. Part 2 is correct as written.
- **[GAP] [live]** The one real gap is unchanged: VM↔VM reachability is a genuine
  precondition the manual punts on. On default Lima there is none; I had to attach
  `user-v2` first (see Environment). Not a manual bug — but a from-scratch follower on
  a laptop needs this called out, because "two Linux hosts that can reach each other"
  is doing a lot of quiet work.

## Part 3 — SPIRE server (cloud) + agent (store)

- **[ERROR] [live — CONFIRMED]** (manual L208, L209-210, L256-260) The bare
  `kubectl -n spire exec spire-server-0 -- spire-server …` form **fails**:
  > `OCI runtime exec failed: … exec: "spire-server": executable file not found in $PATH`
  The `ghcr.io/spiffe/spire-server:1.15.2` image does not put the binary on `$PATH`.
  All three server commands (bundle show, token generate, entry create) must use the
  **full path** `/opt/spire/bin/spire-server` (as `cluster/spire/apply.sh` does).
  **This is the highest-impact confirmed manual error** — a literal follower is
  blocked at the first SPIRE command in 3b and again in 3c.
- **[GAP] [live — CONFIRMED]** Part 3a gives the full `server.cfg` inline but **not**
  the StatefulSet / Service / NodePort manifest — it only points at `cluster/spire/`.
  I had to deploy the repo's `spire-server.yaml`; the manual text alone is
  insufficient to stand up the server. (The manual is honest that "the demo does this
  in `cluster/spire/`", but a "from-scratch by hand" reader still can't proceed
  without the repo file.)
- **✓ [live]** 3a deploy sequence (`create namespace spire` → `create secret
  spire-upstream-ca` from `ca.crt`/`ca.key` → `create configmap spire-server-config`
  from `server.cfg` → `kubectl apply -f spire-server.yaml`) succeeds; StatefulSet
  rolls out; the `UpstreamAuthority "disk"` server signs under the Linkerd root.
- **✓ [live]** 3c `entry create` registers `…/store/042/inventory-sync` with the two
  selectors (`unix:uid:2102`, `unix:path:/opt/linkerd-proxy/linkerd-proxy`) — verified
  via `entry show`. Join token minted for the agent.
- **[note → feeds Part 4c] [live]** `spire-server bundle show` output (`bundle.pem`,
  copied to the store in 3b) is **byte-identical** to `ca.crt` (same SHA-256
  fingerprint, single root cert). This matters for the Part 4c fix below: the trust
  anchors the proxy needs are already present on the store as `bundle.pem`.
- **✓ [live]** 3b store side: agent renders `agent.cfg`, reaches the SPIRE NodePort
  (`192.168.104.1:30081` OPEN through the routes from Part 2), attests with the join
  token, and `spire-agent healthcheck` passes — the Workload API socket is serving.
- **[NIT] [live]** (manual L237) writes bare `spire-agent run`; that assumes the agent
  binary is on `$PATH`. Where the follower installed it (I used `/opt/spire/bin`)
  determines whether the bare form works — the manual never says where to place it.
- **[GAP] [live]** Part 3a says to "restrict that NodePort to your overlay (a host
  firewall rule scoped to the Tailscale interface)" and points at
  `cluster/spire/firewall.sh`, which hard-requires a `tailscale0` interface. On any
  non-Tailscale connectivity (my `user-v2` case, or a flat LAN) there is **no**
  `tailscale0`, so the manual's only hardening recipe doesn't apply and no substitute
  is given — the NodePort stays open on all interfaces. Defense-in-depth only (the
  pinned bundle + join token are the real auth), but the manual presents it as *the*
  way to restrict it.

## Part 4 — Data-plane proxy on the store

- **[ERROR] [live — CONFIRMED, blocking]** (manual L322) `TRUST_ANCHORS="$(cat
  /opt/spire/certs/ca.crt)"` reads a file the manual **never places on the store** —
  Part 3b (L211) copies only `bundle.pem`. Run verbatim, the proxy dies immediately:
  > `cat: /opt/spire/certs/ca.crt: No such file or directory`
  > `ERROR linkerd_app::env: LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="" is not valid: InvalidTrustAnchors`
  > `Invalid configuration: invalid environment variable`
  This is the **single break that stops the demo dead** for a literal follower. **Fix
  (two options):** (a) in 3b also copy `ca.crt` to `/opt/spire/certs/ca.crt` (what the
  README does); or (b) since `bundle.pem` is byte-identical to `ca.crt` (proved in
  Part 3), point `TRUST_ANCHORS` at the already-copied `bundle.pem`. After copying
  `ca.crt`, the proxy certifies on the spot:
  `Certified identity id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`.
- **✓ [live]** 4a extraction (`docker create/cp/rm` of
  `cr.l5d.io/linkerd/proxy:edge-26.7.2`, copying `/usr/lib/linkerd/linkerd2-proxy`)
  works as written; binary is proxy release `2.363.0`. (Aside: the standalone proxy
  has **no** `--version` flag — invoking it exits rc=64 `no destination service
  configured`; the manual correctly never runs `--version`, and the repo's
  `extract-proxy.sh` guards it with `|| true`.)
- **✓ [live]** 4b iptables chain (`PROXY_APP_OUTPUT`: `-o lo RETURN`, `REDIRECT
  --to-port 4140`, `OUTPUT -m owner --uid-owner 1000`) installs exactly as written.
- **✓ [live]** 4c launch (`sudo -E setpriv --reuid=2102 …`) preserves the exported
  `LINKERD2_PROXY_*` env and runs the proxy as the non-root uid; once trust anchors
  are present it obtains + holds the SVID. The env-preservation reasoning is correct.
- **[NIT] [live]** (manual L324) `sudo useradd -r -u 2102 …` emits
  `useradd warning: linkerd-proxy's uid 2102 is greater than SYS_UID_MAX 999` — the
  `-r` (system account) flag conflicts with a uid above the 0–999 system range. The
  account is still created and everything works, but the manual's exact command throws
  a warning a careful follower will stop on. Drop `-r`, or use a uid ≤ 999.

## Part 5 — ExternalWorkload

- **[ERROR] [live — CONFIRMED, blocking]** The manual applies the `ExternalWorkload`
  (and later the app + policies) into namespace **`mixed-env`**, but **never creates
  that namespace** — it only ever creates `spire` (L183). Applying Part 5 verbatim
  fails: `Error from server (NotFound): … namespaces "mixed-env" not found`. In the
  repo the namespace is created **only** by `cluster/echo.yaml` (the abstract-echo
  variant), which the automated flow applies first; the RetailCloud path assumes it
  already exists. **Fix:** add `kubectl create namespace mixed-env` (Part 5, before the
  ExternalWorkload).
- **[ERROR] [live — CONFIRMED]** That same missing namespace object is where the repo
  sets **`annotations: { linkerd.io/inject: enabled }`** (echo.yaml). The manual never
  mentions injection, yet Part 6 calls `retail-cloud` "a normal meshed pod" and Part 7
  depends on it being meshed (a `Server` only governs meshed pods; the store's mTLS
  push is only accepted by a meshed receiver). Without the annotation the app comes up
  **unmeshed** and Part 7's identity policy silently does nothing. **Fix:** create
  `mixed-env` with `linkerd.io/inject: enabled` (or annotate the deployment).
- **✓ [xref→live]** Once the namespace exists, the `ExternalWorkload` +
  status-subresource patch match `cluster/retail/store-pos.yaml`. Manual omits only a
  nonfunctional `location` label. Ports/identity/serverName all match. _applied below._

- **✓ [live]** After the namespace fix, Part 5 ExternalWorkload applies and the status
  `Ready` patch takes; Part 6 `retail-cloud` rolls out; Part 7 `Server` +
  `MeshTLSAuthentication` + `AuthorizationPolicy` all apply cleanly.
- **[NIT] [live]** Verifying "is it meshed?" is non-obvious on edge-26.x: the proxy is
  a **native sidecar** (`initContainers: linkerd-init linkerd-proxy`,
  `restartPolicy: Always`), not a `.spec.containers` entry. A follower checking
  `containers` sees only `web` and may wrongly conclude injection failed. Pod is
  `2/2 Ready` and annotated by the proxy-injector. (Not a manual bug — a verification
  footgun worth a one-line note.)

## Part 6 — Application + data flow

- **✓ [xref]** retail-cloud ports (`:8080` http, `:8090` ingest) and store-pos client
  (`--user 1000`, POST to `…:8090/ingest`) match `retail-cloud.yaml` /
  `store-pos/run-store-pos.sh`. Part 6 is prose (no exact `docker run`), so nothing
  to break literally. _data-flow verified below._

## Part 7 — Authorization by identity

- **✓ [live]** `Server` (port `ingest`, `proxyProtocol: HTTP/1`),
  `MeshTLSAuthentication` (store SPIFFE ID), and `AuthorizationPolicy` apply and
  **function**: default-deny on `:8090` admits only the store's SPIFFE ID. Proven by
  the live 200 (allowed) → 403 (revoked) → 200 (restored) transition below. API
  versions (`policy.linkerd.io/v1beta3`, `v1alpha1`) are accepted as written.
- **✓ [live]** End-to-end data flow works: `store-pos` (uid 1000, edge) → iptables
  redirect → `linkerd2-proxy` → mTLS as `store/042/inventory-sync` → retail-cloud
  ingest `:8090` → `push -> 200`.

## Part 8 — Verify

- **✓ [live]** Core claim holds exactly: `kubectl patch meshtlsauthentication
  allow-store` to `/nobody` flips the store's pushes to **403** ("authorization voided
  by cloud"); restoring the identity returns them to **200**. "Nothing about the
  network moved — only which identity was allowed" is demonstrably true.
- **✓ [live]** mTLS + SPIFFE identity are visible on the wire — with `-o wide`:
  `src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`,
  `src_tls=true`, `dst_srv_name=retail-ingest`, `dst_authz_name=ingest-allow-store`.
- **[ERROR] [live — CONFIRMED]** Part 8's description of the tap row is inaccurate on
  three counts: (1) the command it gives (L478, `linkerd viz tap deploy/retail-cloud`,
  **no `-o wide`**) prints `tls=true` but **not** the identity fields; (2) the field
  is named **`src_client_id`**, not `client_id`; (3) **`src_external_workload=store-pos`
  never appears** in tap output — there is no such column. Fix: use `viz tap -o wide`
  and describe the real fields (`src` = the edge IP, `src_tls=true`,
  `src_client_id=<the store SPIFFE ID>`), or soften the prose.
- **[GAP] [live — CONFIRMED]** Part 8 needs `viz`, which Part 1 marks **optional**;
  and if `viz` is installed **after** the workload (natural if Part 1's viz step was
  skipped then added for Part 8), `tap` reports `tap not enabled … restart these pods`
  — the workload must be `rollout restart`ed so the tap-injector configures its proxy.
  Neither the optionality nor the restart is reconciled. Promote `viz` to required
  (installed in Part 1, before the workloads) or add a non-viz verification path.

---

## Summary of findings

**Headline: the demo genuinely stands up from scratch and works end-to-end.** With
the fixes below applied, an external workload on a second host obtains a SPIFFE SVID
from SPIRE, joins the Linkerd mesh via a standalone proxy, and its pushes to the
in-cluster service are authorized **by identity** — proven live: `push -> 200`,
revoke → `403`, restore → `200`, with `src_client_id=spiffe://…/store/042/inventory-sync`
and `src_tls=true` on the wire. The architecture and almost every command are correct
as written. But a reader following the manual **literally** is stopped four times.

### Blocking — a literal follower cannot proceed until these are fixed

1. **Part 3b/3c — `spire-server` not on `$PATH`.** `kubectl -n spire exec
   spire-server-0 -- spire-server …` fails `executable file not found in $PATH`
   (image `ghcr.io/spiffe/spire-server:1.15.2`). Use `/opt/spire/bin/spire-server`
   for all three commands (bundle show, token generate, entry create).
2. **Part 4c — trust anchors file never copied to the store.** `TRUST_ANCHORS="$(cat
   /opt/spire/certs/ca.crt)"` reads a file 3b never creates (3b copies only
   `bundle.pem`). Proxy dies `InvalidTrustAnchors`. Fix: also copy `ca.crt` to the
   store in 3b (as the README does), or point `TRUST_ANCHORS` at `bundle.pem` (proved
   byte-identical to `ca.crt`).
3. **Parts 5-7 — `mixed-env` namespace never created.** Only `spire` is created.
   Applying the ExternalWorkload/app/policies fails `namespaces "mixed-env" not
   found`. Add `kubectl create namespace mixed-env`.
4. **Parts 6-7 — injection never enabled on `mixed-env`.** The manual calls
   retail-cloud "a normal meshed pod" and Part 7 needs it meshed, but never sets
   `linkerd.io/inject: enabled` (the repo hides this in `echo.yaml`). Without it the
   app is unmeshed and the identity policy is inert. Annotate the namespace (or the
   deployment).

### Non-blocking errors (wrong as written, but the demo limps on)

5. **Prerequisites — store does not need `spire-server`.** Prereqs list both SPIRE
   binaries for the store; Part 3 runs the server in the cluster and the store "runs
   the agent only." Drop `spire-server` from the store prereqs.
6. **Part 8 — tap row described inaccurately.** Field is `src_client_id` (not
   `client_id`), it only shows with `-o wide` (the given command omits it), and
   `src_external_workload=store-pos` is not a real tap field. Correct the command/prose.
7. **Part 4c — `useradd -r -u 2102` warns** `uid 2102 is greater than SYS_UID_MAX
   999`. Harmless but alarming; drop `-r` or use a uid ≤ 999.

### Gaps (missing steps / unstated context a from-scratch follower needs)

8. **Connectivity precondition** ("two Linux hosts that can reach each other") is the
   biggest unstated hurdle. On a laptop (default Lima) there is no VM↔VM reachability;
   I had to attach a `user-v2` network first. Worth an explicit callout / pointer.
9. **No install commands** for the named prereq tools (`linkerd` edge CLI, `step`,
   SPIRE, k3s). Acceptable for a prereqs section, but pointers would help.
10. **Portability of hard-coded IPs.** `10.42.0.0/16`, `10.43.0.0/16`, `10.43.0.10`
    are k3s defaults reused as literals in Parts 2/4; a non-k3s follower silently
    mis-routes. Add a "discover your cluster's values" callout.
11. **Part 3a delegates the SPIRE StatefulSet/Service manifest** to `cluster/spire/`;
    the manual text alone can't stand up the server.
12. **Part 3a NodePort hardening** is only given as a Tailscale-interface firewall
    (`tailscale0`); no substitute for non-Tailscale connectivity.
13. **Part 8 viz** is optional in Part 1 but required in Part 8, and a late install
    needs a workload `rollout restart` before `tap` works.

### Predictions from the static cross-reference that the live run REFUTED

The manual is correct as written on all of these (my Pass-A worries were wrong):
`kubectl apply -f` for the Gateway API CRDs works (no `--server-side` needed);
`/etc/systemd/resolved.conf.d` already exists (no `mkdir`); IP forwarding alone
suffices for edge→pod/svc routing (no MASQUERADE); `step` yields ECDSA P-256.

### Fixes applied to MANUAL.md (this session)

Per the "blocking + cheap errors + key notes" decision, the following were edited into
`MANUAL.md` (the 4 blocking errors, the 3 non-blocking errors, and 3 key-gap notes):

- **Blocking:** full-path `/opt/spire/bin/spire-server` in 3b/3c (×3); copy `ca.crt`
  (as well as `bundle.pem`) to the store in 3b; `kubectl create namespace mixed-env`
  + `linkerd.io/inject=enabled` at the top of Part 5.
- **Non-blocking:** store prereq now lists `spire-agent` only; Part 8 uses
  `viz tap -o wide` and the correct `src_client_id` field (dropped the nonexistent
  `src_external_workload`); `useradd -M …` instead of `-r` (kills the SYS_UID_MAX warning).
- **Key notes:** connectivity/VM-to-VM callout in Prerequisites; k3s-defaults
  portability note in Part 2; `viz install` promoted into Part 1 with the late-install
  restart caveat.

Gaps left as-is by decision (deferred): install commands for prereq tools (#9), the
full SPIRE StatefulSet manifest inlined (#11), a non-Tailscale NodePort hardening
recipe (#12).

### Substrate caveat

Both hosts ran as Lima VMs on one 16 GiB Mac over a `user-v2` network. This exercises
the manual's *steps* faithfully but cannot surface genuinely cross-machine issues
(real NAT, path-MTU, asymmetric routing, host firewalling). None of the findings above
are substrate artifacts — they are all doc/command issues that would bite on real
hardware identically. The demo was originally designed for two separate machines.
