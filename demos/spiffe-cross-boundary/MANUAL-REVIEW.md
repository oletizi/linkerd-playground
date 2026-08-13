# MANUAL.md review — can you stand up the demo from it?

**Short answer: no, not from the manual alone.** Two parts stop a literal follower
cold, and one whole part contains no commands at all. Everything else is accurate —
and in one place the manual is *more* correct than the README was.

This review cross-references [`MANUAL.md`](MANUAL.md) against a working
Linux/x86_64 deployment (see [`runlog-linux.md`](runlog-linux.md)), and live-tests
the claims that could only be settled empirically. It complements
[`runlog.md`](runlog.md), which followed the manual by hand on macOS; findings that
runlog already raised and that are **still open** are marked *(carried over)*.

Legend: **[BLOCKER]** stops a follower cold · **[ERROR]** wrong as written ·
**[GAP]** missing step/context · **[NIT]** minor · **✓** verified correct.

---

## M1 [BLOCKER] Part 6 contains no commands

Part 6 ("The application and the data flow", L524-550) describes `store-pos` and
`retail-cloud` in prose — what they do, which ports they listen on, why `:8080` is
unprotected and `:8090` is the meshed ingest — and then **stops**. There is no
manifest for `retail-cloud`, no `docker run` for `store-pos`, no ConfigMap for the
app code.

A follower reaching Part 6 has a cluster, a trust anchor, SPIRE, a proxy with an
SVID, and an `ExternalWorkload` — and no way to deploy either application. They
must break out of the manual and borrow `cluster/retail/retail-cloud.yaml`,
`cluster/retail/apply.sh` and `store-pos/run-store-pos.sh` from the repo.

This also breaks Part 7, which selects `port: ingest` by **name** and
`podSelector: { matchLabels: { app: retail-cloud } }` by label. Neither the port
name nor the label appears anywhere in the manual, so a reader writing their own
Deployment has no way to know what to call them, and the `Server` would silently
select nothing.

Minimum fix: give Part 6 the two commands and the container-port name/labels that
Part 7 depends on.

## M2 [BLOCKER] Part 4a never creates `/opt/linkerd-proxy`

```bash
[store] id=$(sudo docker create cr.l5d.io/linkerd/proxy:$LINKERD_VERSION)
[store] sudo docker cp "$id:/usr/lib/linkerd/linkerd2-proxy" /opt/linkerd-proxy/linkerd-proxy
```

`docker cp` will not create the destination directory. Run verbatim on a clean
host, confirmed live:

```
$ sudo docker cp "$id:/usr/lib/linkerd/linkerd2-proxy" /opt/manual-test/linkerd-proxy
invalid output path: directory "/opt/manual-test" does not exist
exit=1
```

The repo's `edge/extract-proxy.sh` does `sudo mkdir -p /opt/linkerd-proxy` first;
the manual dropped it. One line fixes it.

## M3 [ERROR] Part 5's ordering claim, and the README's, overstate the `ExternalWorkload`

The manual launches the proxy in **4c**, then creates the `ExternalWorkload` in
**Part 5**. The README asserts the opposite ordering is mandatory:

> The proxy fetches its inbound policy from the cluster, so the `ExternalWorkload`
> must exist before it starts.

Tested directly: with the `ExternalWorkload` **deleted entirely**, the proxy was
restarted from scratch and came up clean —

```
proxy has identity (uid 2102)
$ grep -icE "error|fail" /tmp/linkerd-proxy.log
0
```

— and the store kept pushing successfully, still over mTLS, still attributed, still
authorized:

```
push -> 200
tap: tls=true
     src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
     dst_authz_name=ingest-allow-store
$ kubectl -n mixed-env get externalworkload
No resources found in mixed-env namespace.
```

So for the push-only RetailCloud flow the `ExternalWorkload` is **inert**: identity
comes from SPIRE, and the `MeshTLSAuthentication` matches the SPIFFE ID string
directly, neither of which consults the resource. The manual's ordering is
therefore *not* a bug — but its justification is wrong. Part 5 says:

> In the push-only RetailCloud the store isn't dialed by anyone, so this is
> nominal — but the resource still gives the workload its mesh identity, which is
> what we need.

The first clause is right; the claim after the dash is not. The resource matters
for the **inbound/server** direction — routing to the workload as an endpoint, and
the inbound policy `LINKERD2_PROXY_POLICY_WORKLOAD` resolves against — which is
exercised by the appendix's beat3, not by RetailCloud.

Both documents should say the same true thing: the `ExternalWorkload` is required
to reach the store *as a server*; the push path works without it.

## M4 [GAP] *(carried over)* `spire-server.yaml` is never shown

Part 3a says "Deploy it as a StatefulSet ... (the demo does this in
`cluster/spire/`)" and then:

```bash
[cluster] kubectl apply -f spire-server.yaml    # StatefulSet + NodePort :30081
```

The manual inlines `server.cfg` and `agent.cfg` in full but never this file, so the
one document that promises to explain "every configuration file" requires an
unexplained one. Already raised as runlog.md #11; still open.

## M5 [GAP] *(carried over)* NodePort hardening is still Tailscale-only

Part 3a, L239-240: "restrict that NodePort to your overlay (a host firewall rule
scoped to the Tailscale interface)". On the flat-LAN path the manual itself
presents in Part 2, there is no `tailscale0`. The scripted equivalent had the same
assumption and it was a hard failure — see runlog-linux.md F6 — now fixed with
`SPIRE_NODEPORT_IFACE`. The manual should name the general case: the interface the
store reaches the cluster host on.

## M6 [GAP] No install commands for the tools the manual requires

Prerequisites name `linkerd` (edge), `step`, `spire-agent`, a container runtime and
`iptables`, with no way to obtain any of them. The repo automates each
(`install-linkerd.sh` curls `run.linkerd.io/install-edge`; `gen-certs.sh` resolves
the `step` .deb per `dpkg --print-architecture`; `install-spire-agent.sh` fetches
`spire-<ver>-linux-<arch>-musl.tar.gz`). Compounding it, Part 3b invokes bare
`spire-agent`, which assumes both that it is installed *and* that it is on `$PATH`
— the manual never says where to put it. Already raised as runlog.md L153-155;
still open.

## M7 [NIT] `$LINKERD_VERSION` and `$TOKEN` are used but never assigned

Prerequisites say "We'll call it `$LINKERD_VERSION`" and Part 4a interpolates it;
Part 3b's `-joinToken "$TOKEN"` refers to the token printed by the command two
blocks earlier. Neither is ever assigned, so both expand empty if pasted. An
`export LINKERD_VERSION=edge-26.7.2` in Prerequisites and a `TOKEN=...` line in 3b
would close it.

## M8 [GAP] uid 1000 is unsafe on a real store host

Part 4b redirects "the store-pos app (uid 1000)" and states the invariant as "app
uid 1000 → the proxy; all other host traffic → normal networking". On a bare-metal
Linux box uid 1000 is normally the primary human user, so that second clause is
false there — the operator's own shell traffic is redirected too. The manual is the
document most likely to be followed on a real host rather than a throwaway VM, so
it is the one that most needs the warning. See runlog-linux.md F5.

## M9 [NIT] `sudo -E setpriv` depends on the host's sudoers policy

Part 4c relies on `sudo -E` to carry ten exported `LINKERD2_PROXY_*` variables into
`setpriv`. That works only where `env_reset`/`env_delete` do not strip them; the
repo's `run-proxy.sh` carries a comment noting it "already preserves it on this
host", which is an admission that it is host-dependent. Worth a note, since the
failure mode — proxy exits with `no destination service configured` — looks like a
config error rather than an environment-stripping one.

---

## Verified correct

- **Part 1** — cert commands, profiles and ECDSA P-256 match `gen-certs.sh`
  exactly; Gateway API v1.2.1 pin and the `linkerd install` flags match
  `install-linkerd.sh`. The instruction to stay in `~/linkerd-certs` because later
  steps read the files by relative name is correct and easy to get wrong. ✓
- **Part 2** — the static-route + `systemd-resolved` recipe is exactly what
  `net/shim.sh` performs, and this run verified it end to end on a flat network. ✓
- **Part 3a/3b configs** — the inlined `server.cfg` and `agent.cfg` match
  `cluster/spire/server.cfg` and `edge/spire/agent.cfg` byte-for-byte in substance
  (repo adds only `log_level`). ✓
- **Part 3b's cert copy** — copies **both** `bundle.pem` and `ca.crt`, with the
  note that `ca.crt` is what Part 4c reads. This was runlog.md's blocking
  Part 4c **[ERROR]** and it is **now fixed**. ✓
- **Part 3c** — selectors (`unix:uid:2102`, `unix:path:/opt/linkerd-proxy/linkerd-proxy`)
  and parent/SPIFFE IDs match the registered entry verbatim. ✓
- **Part 4c env** — all ten variables match `edge/run-proxy.sh`, including the
  easily-missed detail that `POLICY_SVC_NAME` and `DESTINATION_SVC_NAME` are both
  the `linkerd-destination` service account. ✓
- **Part 5 manifest** — `workload.linkerd.io/v1beta1`, labels, `meshTLS.identity`,
  `serverName` and the `ports`/`workloadIPs` block match
  `cluster/retail/store-pos.yaml`; the status-subresource patch is correct and the
  reason it is needed is correctly explained. ✓
- **Part 5 namespace** — creates **and annotates** `mixed-env`. The scripted path
  did neither, which was a blocker (runlog-linux.md F9) whose natural workaround
  silently leaves `retail-cloud` unmeshed. **The manual is right here and the
  README was wrong.** ✓
- **Part 7** — all three policy resources match `cluster/retail/authz.yaml`; the
  revoke patch reproduces the Void button's effect, verified 200 → 403 → 200. ✓
- **Part 8** — uses `-o wide` and names `src_client_id`. **The manual is correct
  and the README was wrong** (runlog-linux.md F10, since fixed). ✓

## Verdict

The manual is **conceptually sound and factually accurate** — every config it
inlines matches the working deployment, and twice it is correct where the README
was not (namespace annotation, tap output). Its explanations of *why* each piece
exists hold up against the running system.

As a *procedure*, it is not yet followable end to end. Three things account for
almost all of that: Part 6 has no commands (M1), Part 4a is missing a `mkdir`
(M2), and `spire-server.yaml` is never shown (M4). Fixing those three would make
the manual self-contained; M3 is a correctness fix to a claim both documents get
wrong, and M5-M9 are accuracy and safety polish.

---

# Second pass — validated as an intuition-builder (2026-08-12)

**Why a second pass.** The first pass judged the manual as a *procedure*: can a
literal follower stand the demo up from it? That is the README's job. The manual's
job — it is published as *The manual* on the site, next to *Concepts* — is to build
a correct mental model of how SPIFFE and SPIRE work. Judged against **that** bar,
most of the first pass's blockers stop being blockers, and a different class of
finding matters more: sentences a reader can absorb and come away **wrong**.

There are five of those, plus four gaps. They are cheap to fix and none of them
requires re-running anything.

**Method.** Read start-to-finish as a learner, then every load-bearing claim
cross-checked against upstream sources rather than against this repo (the first
pass already did repo fidelity, and found it exact). Sources: `linkerd2-proxy`
`linkerd/app/src/env.rs`, the `linkerd-control-plane` Helm chart, Linkerd's
server-policy docs, and Linkerd's own *Adding non-Kubernetes workloads* task page.
**No live cluster this pass** — the host carries no `k3s`, `kubectl`, `docker`,
`step` or `spire-agent`; empirical claims cited below come from
[`runlog-linux.md`](runlog-linux.md). Nothing here needed a cluster to settle.

Legend: **[ERROR]** teaches something false · **[GAP]** the model has a hole ·
**[NIT]** minor.

**Disposition.** The four [ERROR]s — C1-C4, everything factually wrong — are **fixed
in `MANUAL.md`**, as is the side finding in `concepts.md`. The gaps and nits (C5-C9)
are **recorded here, not applied**; C5 in particular is deferred by an explicit
decision, not an oversight (see its Status note).

---

## C1 [ERROR] Part 5 says the `ExternalWorkload` is where the workload's identity comes from

L508-510, unchanged since the first pass flagged it as M3:

> In the push-only RetailCloud the store isn't dialed by anyone, so this is
> nominal — **but the resource still gives the workload its mesh identity, which is
> what we need.**

The clause after the dash is false, and it is the most damaging sentence in the
document, because the manual's whole thesis is *identity travels in the
certificate*. Part 3 spends three subsections establishing that SPIRE attests the
proxy and issues it an SVID; Part 5 then tells the reader a Kubernetes resource is
what "gives" it that identity. A reader who believes both cannot answer the
question the demo exists to answer: **what would still work if the cluster forgot
this workload existed?**

Empirically: everything on the push path. With the `ExternalWorkload` deleted
outright, the proxy came up clean, pushes stayed at `200`, `tls=true`, and
`src_client_id` still resolved to the store's SPIFFE ID (first pass, M3).

The same lean appears earlier, in **mental-model item 4** (L48-50): "tells Linkerd
this off-cluster process exists **and what identity it carries**". Presenting the
resource as one of "four things that have to line up" overstates it for the flow the
manual actually builds.

The true version is more interesting than the false one, and C2 supplies it: the
`ExternalWorkload` is the cluster's **model** of the workload — how to route to it
as a *server*, and what its *inbound* policy attaches to. The README already says
this (L216-220); the manual never got the same edit.

## C2 [ERROR] Part 4c inverts the direction of `IDENTITY_SERVER_NAME`

L447-448:

> **`IDENTITY_SERVER_ID` / `IDENTITY_SERVER_NAME`** — the SPIFFE ID this proxy
> should obtain and **the SNI it presents**.

SNI is a *client-side* extension, so "the SNI it presents" points the reader
outbound — at the store→cloud connection the whole demo is about. Both variables
are in fact **inbound**. From `linkerd2-proxy`, `linkerd/app/src/env.rs`:

```rust
/// Configures the TLS Id of the proxy inbound server. The value is expected to match the
/// DNS or URI SAN of the leaf certificate that will be provisioned to this proxy.
pub const ENV_IDENTITY_IDENTITY_SERVER_ID: &str = "LINKERD2_PROXY_IDENTITY_SERVER_ID";

/// Configures the server name of this proxy. This value is expected to match the value
/// that clients include in the SNI extension of the ClientHello, whenever they try to
/// establish a TLS connection that shall be terminated by this proxy
pub const ENV_IDENTITY_IDENTITY_SERVER_NAME: &str = "LINKERD2_PROXY_IDENTITY_SERVER_NAME";
```

`SERVER_NAME` is the name **clients use to address this proxy**, not one it emits.
`SERVER_ID` is the identity its own leaf must carry.

This is worth fixing for more than accuracy: it is the missing half of C1. These two
variables are exactly the `ExternalWorkload`'s `meshTLS.identity` and
`meshTLS.serverName` (Part 5, L497-498) — the same pair of values written on both
sides of the boundary. *That* is why they must match, and it explains in one stroke
what the resource is for: both halves describe how the mesh reaches the store **as a
server**. Nothing on the push path consults either.

## C3 [ERROR] "Trust domain" is conflated with the trust anchor's common name

Two places:

- L22-24 (Convention): "The trust domain throughout is `root.linkerd.cluster.local`
  (**Linkerd's default**)."
- L100-101 (Part 1): "`root.linkerd.cluster.local` is the trust anchor's common
  name; **the trust domain in every SPIFFE ID derives from it**."

Linkerd's default trust domain is `cluster.local`, not `root.linkerd.cluster.local`.
From `charts/linkerd-control-plane/values.yaml`:

```yaml
identityTrustDomain: ""
# @default -- clusterDomain
```

`root.linkerd.cluster.local` is the default *trust anchor common name*, which is a
different thing. And nothing derives one from the other: SPIRE's trust domain is a
config value, set by hand in `server.cfg` and `agent.cfg` (both L4 in the manual's
own listings) to a string that happens to match the CN. Linkerd's own task page
picks the same string, which is presumably where the demo got it — but it is a
convention, not a derivation.

The manual contradicts itself here, one Part later. Part 4c's control-plane
identities (L435, L437) are:

```
linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local
```

— in-cluster naming, under trust domain `cluster.local`. So the trust domain is
*not* `root.linkerd.cluster.local` "throughout": two different naming schemes are on
screen at once, and both validate fine.

Which is the lesson worth teaching, and it is currently invisible. What makes this
one trust domain is the **shared root** — not a shared name. The demo demonstrates
that and then tells the reader the opposite.

## C4 [ERROR] Part 7 says mesh membership is what a default-open port admits

L559: "By default a meshed port is open to **any meshed client**."

Linkerd's default inbound policy is `all-unauthenticated` — "allow all requests",
meshed or not. The sentence implies being in the mesh is itself an authorization
gate, which is precisely the misconception this demo exists to dispel: *location and
membership are not authorization; identity is.* Part 6 even relies on the truth two
pages earlier — the unmeshed browser loads `:8080` because no `Server` protects it.

Fix is one word: open to **any** client.

## C5 [GAP] The payoff sentence is never written: how the cloud actually decides

The manual assembles every piece of the authorization decision and never states the
decision itself. Part 1 establishes chaining to a shared root. Part 3 establishes
that SPIRE issues an SVID naming the workload. Part 7 establishes a policy listing
an allowed SPIFFE ID string. The sentence that joins them —

> the client's certificate chains to the trust anchor; the SPIFFE ID is the URI SAN
> inside that certificate; `MeshTLSAuthentication` compares that string

— appears nowhere. Neither does the term **URI SAN**, so a reader is never told
*where in the certificate* the identity lives, or that policy matching is a string
comparison against a cryptographically-verified field. It reads as though the
SPIFFE ID and the certificate are two loosely-associated facts.

For a document whose purpose is intuition, this is the paragraph readers came for.
Part 8 is its natural home — `src_client_id` in the tap output *is* that field.

> **Status: deferred, deliberately.** This is the one finding in the second pass that
> is an *addition* rather than a correction, and it was held back when C1-C4 were
> applied. Nothing in the manual is wrong for want of it; the pieces are all present
> and only the joining sentence is missing. Whoever picks this up: the paragraph needs
> to name the **URI SAN** explicitly, and say that `MeshTLSAuthentication` matching is
> a string comparison against that field *after* chain validation — those two facts
> are what the document never states anywhere.

## C6 [GAP] The identity belongs to the proxy — so does anything that can reach the proxy

Part 4b is careful and correct about *whose traffic is redirected*: uid 1000 only,
so the SPIRE agent and the host are untouched. Part 3c is careful and correct about
*who may obtain the identity*: uid 2102 running that exact binary. Both are good.

What is never said is that these are different questions, and that the second one
has a back door. The proxy's outbound listener is `127.0.0.1:4140`
(`DEFAULT_OUTBOUND_LISTEN_ADDR` in `env.rs`), and any local process can connect to
it directly — no uid check, the redirect is merely what makes it *automatic* for the
app. So on the store host the practical boundary is "who can open a socket to the
proxy", not "who runs as uid 1000".

The reader's natural conclusion from Part 6 — *the store app was authenticated* — is
wrong in a way that matters: the app is never attested, never holds a key, and is
authorized only in the sense that it sits behind a process that is. The manual says
the first half of this repeatedly ("not the app itself, which never talks to
SPIRE"); it never draws the consequence.

[Production notes](PRODUCTION-NOTES.md#security-boundaries-what-this-does-and-does-not-protect)
covers host-root compromise but not this, so it is not caught downstream either.

## C7 [NIT] `bundle.pem` and `ca.crt` are the same bytes here, and the manual doesn't say so

Part 3b (L296-299) copies both to the store and distinguishes their roles precisely
— the agent's pinned server bundle, and the anchor the proxy validates peers
against. Pedagogically right, and worth keeping.

But in this topology they are the same certificate: SPIRE chains directly to the
Linkerd root, so `spire-server bundle show` emits that root. Confirmed at
599 bytes each, one PEM block (runlog-linux.md F11). A reader who diffs them finds
them identical and concludes one of the two explanations must be wrong.

One clause fixes it and teaches the distinction better than silence does: *these
happen to be the same certificate in this setup, because SPIRE chains straight to
the Linkerd root — they are different roles that would diverge the moment SPIRE
chained to an intermediate instead.*

## C8 [NIT] The agent's socket path arrives from nowhere

Part 3b (L344-346) tells the reader the agent exposes the Workload API at
`/tmp/spire-agent/public/api.sock`, and Part 4c points the proxy at it. That path
appears in neither `agent.cfg` listing — it is SPIRE's default `socket_path`. A
reader tracing "where is this configured?" through the file finds nothing. Say it's
the default.

## C9 [GAP] Part 7's selectors reference names Part 6 never introduces

This is the one piece of the first pass's M1 that survives the change of bar. Most
of M1 does not: prose describing what `store-pos` and `retail-cloud` do is
appropriate for a document explaining mechanics, and a reader is not stuck without a
`docker run`.

But Part 7's `Server` selects `port: ingest` **by name** and
`podSelector: { app: retail-cloud }` **by label**, and neither name nor label
appears anywhere in the manual. That is not a copy-paste gap; it is a comprehension
gap — *how does a `Server` find what it protects?* is a question the manual poses
and then declines to answer. Part 6 naming the two container ports and the label
would close it in three lines.

---

## Re-scoring the first pass

Under the intuition bar rather than the procedure bar:

| First pass | Was | Now |
|---|---|---|
| M1 Part 6 has no commands | BLOCKER | mostly **not a finding** — but see C9 |
| M2 missing `mkdir /opt/linkerd-proxy` | BLOCKER | **NIT** — a follower hits it and fixes it in one line |
| M3 `ExternalWorkload` claim | ERROR | **still the top finding** — restated as C1/C2 |
| M4 `spire-server.yaml` never shown | GAP | **stands** — the manual promises "every configuration file" |
| M5 NodePort hardening is Tailscale-only | GAP | **NIT** at this bar |
| M6 no install commands for tooling | GAP | **not a finding** |
| M7 `$LINKERD_VERSION` / `$TOKEN` unassigned | NIT | **not a finding** |
| M8 uid 1000 unsafe on a real host | GAP | **stands**, and C6 is the conceptual half of it |
| M9 `sudo -E` / sudoers | NIT | **not a finding** |

## Side finding, outside the manual

The *Concepts* page — the reader's other half of this material — gives the store's
SPIFFE ID as `spiffe://root.linkerd.cluster.local/store-pos`
(`site/…/concepts.md` L32). The real ID, everywhere else in the demo, is
`spiffe://root.linkerd.cluster.local/store/042/inventory-sync`. A reader moving
between the two pages sees two different identities for one workload.

## Second-pass verdict

As an intuition-builder the manual is **good and close to very good**. Its structure
is the right one — four things that must line up, then each one built and explained
— and its best passages have no equivalent in the upstream docs: the two-signing-
paths-under-one-root diagram (L115-119), the identity-vs-connectivity split in
Part 2, "you can't redirect everything-except-the-proxy on a bare host" in Part 4b,
and the insistence in Part 3 that the *proxy* is the attested workload, not the app
and not the agent. Those are the parts a reader will remember, and they are correct.

The problems are concentrated and local. **C1-C4 are four sentences**, each
teaching something false, each fixable in a line — and C1/C2 are one idea (the
`ExternalWorkload` and the two `SERVER_*` variables are the *inbound* story) that
would strengthen the document rather than just correct it. **C5 is the missing
payoff paragraph**, the largest addition proposed here and still only a paragraph.
C6-C9 are polish.

Nothing in the conceptual architecture needs rework. No claim checked against
upstream sources this pass was wrong except the four named above, and the first
pass's finding that every inlined config matches the working deployment still
holds.

---

_Made with [Claude Code](https://claude.com/claude-code)._
