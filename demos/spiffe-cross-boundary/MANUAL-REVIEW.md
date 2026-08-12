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

_Made with [Claude Code](https://claude.com/claude-code)._
