# Manual follow-through runlog — spiffe-cross-boundary (Linux, 2026-08-12)

A third validation pass. [`runlog.md`](runlog.md) followed [`MANUAL.md`](MANUAL.md)
by hand on macOS/arm64; [`runlog-linux.md`](runlog-linux.md) drove the repo's
**scripts** on Linux/x86_64. This pass follows **MANUAL.md by hand on Linux/x86_64**,
on freshly-created hosts with no prior demo state, to answer one question:

**Can you stand the demo up by doing what the manual says?**

**Yes — the demo runs, and every claim it makes about the running system checked
out.** But it took **eight interventions** the manual does not contain, three of
which fail *silently or misleadingly* rather than loudly. The full path was walked:
`200` on the store's pushes, `tls=true`,
`src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync` in
`tap`, and `200 → 403 → 200` across the revoke.

Findings tagged **[BLOCKER]** stops a follower cold · **[GAP]** missing
step/context · **[NIT]** minor · **✓** verified correct. Findings that restate a
still-open item from [`MANUAL-REVIEW.md`](MANUAL-REVIEW.md) are marked
*(reconfirmed)* with the original tag.

## Environment

- Host: Ubuntu 26.04, x86_64, 8 cores, 15.4 GiB RAM, no passwordless sudo.
- Two **libvirt/KVM** VMs on `virbr0` (the topology `runlog-linux.md` F4b settled
  on), Ubuntu 24.04 cloud image: `192.168.122.10` (cluster, 4 vcpu/6 GiB) and
  `192.168.122.11` (store, 2 vcpu/3 GiB). Provisioned with the repo's
  `scripts/cluster-up.sh` / `edge-up.sh` — substrate only. **Nothing else in this
  run used the repo's scripts**; every step below is MANUAL.md's own commands,
  except where a finding says otherwise.
- Versions, all current-at-run rather than the repo's pins: k3s **v1.36.3+k3s1**,
  Linkerd **edge-26.8.1** (repo pins `edge-26.7.2`), SPIRE **1.15.2** server and
  agent, `step` **0.30.6**, Gateway API **v1.2.1** (the version the manual pins),
  proxy `linkerd2-proxy` release 2.364.0.
- Host-side note, not a demo finding: `virt-install` failed with
  `ModuleNotFoundError: No module named 'gi'` because a Homebrew `python3` shadows
  `/usr/bin/python3` on this host and `virt-install`'s shebang is
  `#!/usr/bin/env python3`. Running the provisioner with `PATH=/usr/bin:$PATH`
  fixes it.

---

## The interventions, in the order a follower hits them

| # | Where | What the manual is missing | Fails how |
|---|---|---|---|
| N6 | Prereqs / Part 1 | `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` | loudly |
| M6 | Prereqs | install commands for k3s, `linkerd`, `step`, `spire-agent` | loudly |
| N1 | Part 2 | `sudo mkdir -p /etc/systemd/resolved.conf.d` | **silently** |
| N5 | Part 3a | `spire-server.yaml` is never shown | loudly |
| N9 | Part 3b | `sudo mkdir -p /opt/spire/certs`, and any copy command at all | loudly |
| N3 | Part 3b → 4c | `ca.crt` must be world-readable | **misleadingly** |
| N2 | Part 4a | `sudo mkdir -p /opt/linkerd-proxy` | loudly |
| N4 | Part 6 | the entire section has no commands (and needs `--network host`) | **silently** (N7) |

---

## N1 [BLOCKER, new] Part 2's resolver drop-in writes to a directory that does not exist

Part 2, run verbatim on a clean Ubuntu 24.04 store host:

```
+ printf '[Resolve]\nDNS=10.43.0.10\nDomains=~cluster.local\n'
+ sudo tee /etc/systemd/resolved.conf.d/cluster.conf
tee: /etc/systemd/resolved.conf.d/cluster.conf: No such file or directory
+ sudo systemctl restart systemd-resolved
```

`/etc/systemd/resolved.conf.d/` is not present on the stock cloud image. This is
the same omission as M2 (Part 4a's missing `mkdir`) but strictly worse, because
of what happens next: `tee` prints the config **to stdout** — so the terminal
shows the exact text the reader expected to see written — and the following
`systemctl restart systemd-resolved` **succeeds**. Nothing looks wrong. The
failure surfaces two Parts later as the proxy being unable to resolve
`linkerd-dst-headless.linkerd.svc.cluster.local`.

The repo's `net/shim.sh` has the missing line (L25, `sudo mkdir -p
/etc/systemd/resolved.conf.d`); the manual dropped it, exactly as it dropped the
`/opt/linkerd-proxy` one.

With the `mkdir` added, Part 2 is correct as written and end-to-end verified:

```
10.42.0.0/16 via 192.168.122.10 dev enp1s0
10.43.0.0/16 via 192.168.122.10 dev enp1s0
10.42.0.9  linkerd-dst-headless.linkerd.svc.cluster.local
```

k3s turns on `net.ipv4.ip_forward` itself, so the manual's "the cluster host must
have IP forwarding on" needed no action. ✓

## N3 [BLOCKER, new] The trust anchor lands unreadable, and Part 4c blames the certificate

Part 3b says to copy `ca.crt` to `/opt/spire/certs/ca.crt`. `step` writes it
**0600**, and the natural copy (`sudo cp`) preserves that. Part 4c then reads it
as the *operator*, not as root:

```bash
[store] export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"
```

```
cat: /opt/spire/certs/ca.crt: Permission denied
+ export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS=
TRUST_ANCHORS length: 0
```

`export` swallows the failure — command substitution's exit status is discarded —
so the proxy starts with an empty variable and dies on:

```
ERROR ThreadId(01) linkerd_app::env: LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="" is not valid: InvalidTrustAnchors
Invalid configuration: invalid environment variable
```

`InvalidTrustAnchors` reads as *"your certificate is malformed"*. It is a file
permission. A follower will go and re-inspect `ca.crt`, which is fine, before
they think to check whether `cat` could read it.

`sudo chmod 644 /opt/spire/certs/ca.crt` fixes it, and is safe — `ca.crt` is a
public certificate; the secret half (`ca.key`) never leaves the cluster, which is
the whole point of Part 3a. The manual should say so at the copy step in 3b: it
already distinguishes the two files' roles there, and "make it world-readable,
it's public" reinforces the lesson rather than diluting it.

**The repo's scripted path is exposed to the same trap** — `edge/run-proxy.sh` L17
is the identical `cat`, and only escapes it if the copy happened to land
world-readable.

## N6 [BLOCKER, new] On k3s — the distro the manual names — the `linkerd` CLI has no kubeconfig

The first `linkerd` command in Part 1, on a stock k3s install:

```
$ linkerd install --crds
Unable to install the Linkerd control plane. Cannot connect to the Kubernetes cluster:
error configuring Kubernetes API client: invalid configuration: no configuration
has been provided, try setting KUBERNETES_MASTER environment variable
```

k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml` and installs a `kubectl`
symlink that finds it automatically — so `kubectl apply` (which the manual runs
first, for the Gateway API CRDs) works fine, and only the `linkerd` binary fails.
The contrast makes it look like a Linkerd problem.

`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` is the whole fix. Since the manual
names k3s ("k3s is fine") this hits every follower who takes that suggestion.

## N4 [BLOCKER] *(reconfirmed, was M1/C9)* Part 6 still has no commands

Unchanged. To get past Part 6 I copied out of the repo:
`retail-cloud/{server.js,index.html,tutorial.html}` into a ConfigMap,
`cluster/retail/retail-cloud.yaml` (Deployment + Service + the ServiceAccount and
RBAC the Void button needs), and the `docker run` line from
`store-pos/run-store-pos.sh`. Part 7 applied cleanly afterwards **because** the
borrowed Deployment happens to carry `app: retail-cloud` and name its container
port `ingest` — the two strings Part 7 selects on and the manual never states.

## N7 [GAP, new] `store-pos` only gets redirected because it runs in the host network namespace

Part 6: "Because it runs as `--user 1000`, its outbound POST is redirected through
the proxy." The uid is necessary but not sufficient. Part 4b's rule lives in the
**host's** `nat` table; a container in its own network namespace has its own, and
its traffic never meets that rule — it would reach the cluster unproxied and
unauthenticated (a `403` once Part 7 lands, or worse, an unnoticed plaintext `200`
before it). The working invocation is `--network host` (as
`store-pos/run-store-pos.sh` does), which the manual never mentions.

This matters more than a missing flag, because Part 4b's careful explanation of
*why* the redirect is uid-scoped invites exactly the wrong inference: that the uid
is what does the work.

## N8 [GAP, new] Between Part 4c and Part 5 the proxy warns in a loop, and the manual doesn't say it's expected

Launching the proxy in 4c — as the manual orders it, before the `ExternalWorkload`
exists — produces the "Certified identity" line the manual tells you to look for,
and then this, on a backoff, indefinitely:

```
INFO daemon:identity: linkerd_app: Certified identity id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
WARN watch{port=4191}: linkerd_app_inbound::policy::api: Unexpected policy controller
  response; retrying with a backoff grpc.status=Some requested entity was not found
  grpc.message="unknown server"
```

It is benign and it stops the moment Part 5 applies the `ExternalWorkload` (8
warnings here, none after). It is also a neat demonstration of the point Parts 4c
and 5 now make correctly — the `ExternalWorkload` is the **inbound** story, and
this warning is the proxy failing to fetch *inbound* policy for its own admin port
while the *outbound* push path is entirely unaffected. Worth one sentence, both to
stop a follower debugging it and because it makes the lesson concrete.

## N9 [GAP, new] Part 3b never creates `/opt/spire/certs`, and never gives a copy command

The copy is a comment block, not a command:

```
# Copy BOTH public files to the store …
#   bundle.pem -> /opt/spire/certs/bundle.pem
#   ca.crt     -> /opt/spire/certs/ca.crt
```

The directory doesn't exist (`ls: cannot access '/opt/spire/certs/'`), and
`/opt/spire/agent.cfg` — where 3b's config listing has to end up — is only
inferable from the `-config` path in the `spire-agent run` line below it. Same
class as M2/N1.

## N10 [GAP, new] No SPIRE version guidance anywhere

The manual is careful about `$LINKERD_VERSION` ("use it everywhere — the
standalone proxy binary must match the control plane") and silent about SPIRE. The
agent must be compatible with the server, and the server's version is only
discoverable from `spire-server.yaml` — the file N5 says is never shown. I matched
the repo's `1.15.2` on both sides; it is also currently the latest release, so a
follower installing "latest agent" is fine **today** and has no way to know when
that stops being true.

## N11 [NIT, new] Part 4c's proxy runs in the foreground with no supervision

```bash
[store] sudo -E setpriv --reuid=2102 --regid=2102 --clear-groups /opt/linkerd-proxy/linkerd-proxy
```

blocks the terminal, and the ten `LINKERD2_PROXY_*` exports live only in that
shell, so the follower must invent backgrounding (`setsid … >/tmp/linkerd-proxy.log 2>&1 &`)
before Part 5. Part 3b flags the equivalent for the agent (`# (a service unit in
practice)`); 4c has no such note.

---

## Reconfirmed from earlier passes

- **M2 [BLOCKER] `docker cp` into a non-existent `/opt/linkerd-proxy`** — reproduces
  verbatim on edge-26.8.1: `invalid output path: directory "/opt/linkerd-proxy"
  does not exist`, `exit=1`.
- **N5/M4 [GAP] `spire-server.yaml` is never shown** — still the one config the
  "every configuration file" document doesn't inline. Copied from
  `cluster/spire/spire-server.yaml`.
- **M5 [GAP] NodePort hardening is Tailscale-only** — no `tailscale0` on a flat
  LAN, so the step was skipped; SPIRE's `:30081` stayed open on every interface
  for the whole run.
- **M6 [GAP] no install commands for the required tooling** — k3s, `linkerd`,
  `step` and `spire-agent` all had to be sourced independently. One live wrinkle:
  `step`'s release asset is now `step-cli_0.30.6-1_amd64.deb` (a Debian revision
  suffix), so the obvious URL 404s; the repo's `gen-certs.sh` avoids this by
  resolving the asset from the GitHub API.
- **M7 [NIT] `$LINKERD_VERSION` / `$TOKEN` are never assigned** — both had to be set
  by hand.
- **M8 [GAP] uid 1000 on a real host** — bit for real here: uid 1000 on the store VM
  is `demo`, the login account. From the moment Part 4b's rule lands, every *new*
  outbound TCP connection from the operator's own shell is redirected into the
  proxy. Established sessions survive (the `nat` table is only consulted for new
  conntrack entries), which is precisely why it goes unnoticed.
- **C7 [NIT] `bundle.pem` and `ca.crt` are the same bytes** — confirmed again:
  `diff` reports identical, 599 bytes, one `BEGIN CERTIFICATE`.

---

## Claims settled empirically this pass

### C1/M3 reconfirmed on edge-26.8.1: the push path does not need the `ExternalWorkload`

Deleted outright, mid-run, with the store pushing:

```
$ kubectl -n mixed-env delete externalworkload store-pos
externalworkload.workload.linkerd.io "store-pos" deleted from mixed-env namespace
$ docker logs --tail 4 store-pos
push -> 200   push -> 200   push -> 200   push -> 200
$ kubectl -n mixed-env get externalworkload
No resources found in mixed-env namespace.
```

The manual's current text (Part 5, post-C1-fix) is right.

### C6 half-refuted: the identity is borrowable, but not the way C6 says

C6 asserts the proxy's outbound listener is a back door: *"any local process can
connect to it directly — no uid check, the redirect is merely what makes it
automatic for the app."* The conclusion is right; the mechanism is not.

**Connecting directly to `127.0.0.1:4140` does not work.** As root, addressing the
listener with the target in a `Host:` header:

```
root via 127.0.0.1:4140 -> 502
```

because the outbound proxy routes by the redirect's original destination
(`SO_ORIGINAL_DST`), not by `:authority` — and for a direct connection that
destination is the listener itself:

```
outbound:proxy{addr=127.0.0.1:4140}: linkerd_app_core::errors::respond: HTTP/1.1 request
  failed error=endpoint 127.0.0.1:4140: … Outbound proxy cannot initiate connections
  on the loopback interface
```

**The identity is trivially borrowable a different way** — by *being* uid 1000,
which any root process can do at will, and which is the same one-line move an
operator uses to test:

```
$ sudo setpriv --reuid=1000 --regid=1000 --clear-groups curl -X POST … /ingest
impostor as uid 1000 -> 200
```

An unrelated `curl`, never attested, never holding a key, pushed a payload the
cloud accepted as `store/042/inventory-sync`. And an unproxied client on the same
host is refused, which is the policy doing its job:

```
root direct to pod -> 403
```

So C6's real content survives and sharpens: the attested party is the **proxy**;
the app is authorized only by *co-location with a uid*. The boundary is "who can
run as uid 1000", not "who can open a socket to 4140".

---

## Verified correct

Everything below was run as written and behaved as documented.

- **Part 1** — both `step` invocations, ECDSA P-256 by default, the stay-in-one-directory
  instruction (four later steps do read the files by relative name), the Gateway
  API pin, and all three `--identity-*` flags. `linkerd check` came back all-`√`
  on edge-26.8.1. ✓
- **Part 2** — route + resolver recipe, once N1's `mkdir` is supplied. ✓
- **Part 3a** — the inlined `server.cfg` deployed unmodified (its trailing
  `# mounted from the Secret` comment is valid HCL); the Secret and ConfigMap
  commands are correct; the server came up and minted its intermediate under the
  Linkerd root. ✓
- **Part 3b** — the inlined `agent.cfg` attested **first try**, no edits:
  `Node attestation was successful`, then
  `Creating X509-SVID … spiffe://root.linkerd.cluster.local/store/042/agent`, and
  `spire-agent healthcheck` → `Agent is healthy.` The `/opt/spire/bin/` full-path
  note is right — the binary is not on `$PATH` in the container. ✓
- **Part 3c** — the entry created verbatim; both selectors and the parent ID match
  what the agent then attested. ✓
- **Part 4b** — all four `iptables` rules correct; the resulting table is exactly
  the documented invariant. ✓
- **Part 4c** — all ten environment variables correct, and the log line the manual
  says to look for appeared verbatim:
  `Certified identity id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`. ✓
- **Part 5** — namespace creation *and* the inject annotation (`retail-cloud` came
  up `2/2`, i.e. meshed); the `ExternalWorkload` manifest; and the status-subresource
  patch, which is genuinely required and correctly explained. ✓
- **Part 7** — all three resources applied clean and `port: ingest` /
  `app: retail-cloud` selected the borrowed Deployment. The revoke patch produced
  `push -> 403 (authorization voided by cloud)` within seconds, and restoring it
  returned `push -> 200`. ✓
- **Part 8** — `tap -o wide` shows precisely what the manual claims, plus the
  `dst_srv_name` / `dst_authz_name` it mentions:

```
req id=0:0 proxy=in src=192.168.122.11:45772 dst=10.42.0.18:8090 tls=true
  :method=POST :path=/ingest
  src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
  src_tls=true dst_srv_kind=server dst_srv_name=retail-ingest
  dst_authz_kind=authorizationpolicy dst_authz_name=ingest-allow-store
rsp … :status=200
```
✓

Installing `viz` before the workloads (Part 1's reason for putting it there) did
what it promises: `tap` saw `retail-cloud` with no rollout restart. ✓

---

## Verdict

**The manual's content is sound and its explanations hold up under execution** —
this pass found no false statement about the running system, and several places
where following it exactly produced the documented output on the first attempt
(the SPIRE agent's attestation, the proxy's `Certified identity` line, the whole
of Parts 7 and 8). Two years of version drift — Linkerd `edge-26.8.1` against the
repo's `edge-26.7.2` pin, k3s v1.36, SPIRE 1.15.2 — changed nothing.

**As a procedure it is still not self-contained**, and the gap is narrower and
more fixable than "Part 6 has no commands". Five of the eight interventions are
one line each (`mkdir` ×3, `chmod`, `export KUBECONFIG`), and three of those fail
in ways that send a follower somewhere other than the actual cause:

- N1 prints the config it did not write and then reports success.
- N3 reports `InvalidTrustAnchors` for a file it could not read.
- N7 fails only *silently and later*, as a `403` from the wrong-looking place.

Those three are worth more than the two remaining "borrow it from the repo" gaps
(N4, N5), which at least fail loudly and obviously. A follower who hits N1 or N3
has no way to tell, from the error alone, that the manual left something out.
