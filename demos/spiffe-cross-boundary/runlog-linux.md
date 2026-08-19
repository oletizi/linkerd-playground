# Linux validation runlog — spiffe-cross-boundary

A second validation pass, complementing [`runlog.md`](runlog.md). Where that one
followed [`MANUAL.md`](MANUAL.md) by hand on macOS/arm64, this one drives the
repo's **automation scripts** (`just demo spiffe-cross-boundary …`) on
**Linux/x86_64**, to answer two questions the first pass could not:

1. does the demo work on Linux and on amd64, and
2. do the scripts work at all? (the macOS pass ran the manual by hand and consulted
   the scripts only for cross-reference, so several script paths had never executed)

Findings tagged **[BLOCKER]** stop a follower cold · **[BUG]** wrong as written ·
**[GAP]** missing step/context · **[NIT]** minor · **✓** verified correct.
Findings marked **platform-independent** are not Linux-specific — they reproduce on
macOS too and were simply masked by the first pass's method.

## Environment

- Host: Ubuntu 26.04 LTS, x86_64, 8 cores, 15.4 GiB RAM. KVM available (an ACL
  grants `orion` rw on `/dev/kvm`; the user is *not* in the `kvm` group). No
  passwordless sudo on the host.
- Substrate, first attempt: Lima 2.2.0 driving QEMU/KVM (not macOS `vz`), Ubuntu
  24.04 cloud image, guest arch x86_64. Host tooling installed per F2.
  **Abandoned** — see F4b: Lima's only VM-to-VM option on Linux repeatedly crashed
  QEMU under download load.
- Substrate, second attempt (the one that carried the run): two **libvirt/KVM**
  VMs on the default `virbr0` bridge, same Ubuntu 24.04 cloud image, static
  addresses `192.168.122.10` (cluster) and `192.168.122.11` (edge). virbr0 is a
  real host bridge with a tap device per VM, so both directions route natively
  with no overlay — and the QEMU socket-netdev code that aborts under Lima is
  never reached.
- Started: 2026-08-12.

> **On substrate choice.** Ubuntu 24.04 is the image the repo itself pins in both
> Lima provisioners, kept here for parity with the macOS pass. It is an LTS, in
> standard support until 2029 — but the pin is two years old and worth revisiting
> as maintenance.

## F1 [BUG, platform-independent] `just demo spiffe-cross-boundary cluster-up` fails

`scripts/lib-vm.sh` sets `HERE` to the **demo root**; `scripts/cluster-up.sh` and
`scripts/edge-up.sh` set `HERE` to the **scripts dir**, then source `lib-vm.sh`,
which silently clobbers it. The subsequent `"$HERE/../provisioners/lima/*.yaml"`
therefore resolves to `demos/provisioners/lima/cluster.yaml`:

```
[cluster-up.sh] creating linkerd-cluster
level=fatal msg="open /home/orion/work/linkerd-playground/demos/provisioners/lima/cluster.yaml: no such file or directory"
```

Not Linux-specific — this breaks on macOS too. The macOS runlog followed
MANUAL.md by hand and created the VMs manually, so the Justfile provisioning path
was never exercised. `down.sh` sources the same lib but does not use `HERE`
afterward, so it is unaffected.

Fix applied: drop the `..` in both scripts (paths are relative to the demo root
that `lib-vm.sh` establishes).

## F1b [BUG, platform-independent] `vm_shell` passes a doubled `--`

With F1 fixed, both provisioning scripts still exit non-zero on their last line.
`scripts/lib-vm.sh` defines `vm_shell() { local name="$1"; shift; limactl shell "$name" -- "$@"; }`
— it supplies the `--` itself — but both callers pass another one:

```bash
vm_shell "$CLUSTER_VM" -- bash -lc 'uname -m && echo cluster-vm-ready'
```

so the guest receives `bash -- -lc …`:

```
/bin/bash: --: invalid option
error: Recipe `cluster-up` failed on line 9 with exit code 2
```

The VM itself is created and Running, so this is cosmetic in effect but fails the
recipe — `just demo spiffe-cross-boundary cluster-up` always reports failure.
Also platform-independent. Fix applied: drop the caller-side `--` in both scripts.

## F2 [GAP] Host prerequisites on Linux are undocumented

README's "Prerequisites" names two Linux hosts and Lima, but on a fresh Ubuntu box
none of the host-side tooling exists (`limactl`, `just`). Neither is packaged:
`lima` is in neither apt nor snap on Ubuntu 26.04; `just` is in apt (1.45.0) but
that needs root. Both install fine as user binaries from GitHub releases:

```bash
curl -fsSLO https://github.com/lima-vm/lima/releases/download/v2.2.0/lima-2.2.0-Linux-x86_64.tar.gz
mkdir -p ~/.local/lima && tar -C ~/.local/lima -xzf lima-2.2.0-Linux-x86_64.tar.gz
ln -sf ~/.local/lima/bin/limactl ~/.local/bin/limactl
```

QEMU (`qemu-system-x86_64`, `qemu-img`) was already present. Lima on Linux drives
QEMU/KVM rather than macOS `vz`; no `socket_vmnet` is needed for the path used here.

## F3 [GAP] Default VM sizing does not fit a 16 GiB Linux desktop

Defaults are cluster 4cpu/8GiB + edge 2cpu/4GiB = 12 GiB, against ~8.2 GiB
available on a 15.4 GiB desktop with a browser open. Overridden in
`config.local.env` to cluster 6GiB / edge 2GiB.

## F4 [GAP → ✓ works] VM-to-VM networking: `user-v2` is the only Lima option on Linux

Lima's default QEMU user-mode NAT gives every VM the same `192.168.5.15` with no
path between VMs, so the README's "bring your own L3 reachability" precondition
needs satisfying explicitly. The macOS pass used Lima's `user-v2` network; on
Linux that is not merely *a* choice, it is the **only** one — the other three
modes in the stock `~/.lima/_config/networks.yaml` (`shared`, `bridged`, `host`)
are all implemented via `socket_vmnet`, which is macOS-only. Anything else
(host bridge + tap) requires root on the host.

Attached per-VM, which needs no host sudo and no edit to the repo's provisioner
YAMLs:

```bash
limactl edit linkerd-cluster --network lima:user-v2   # while stopped
limactl edit linkerd-edge    --network lima:user-v2
```

Result — the same addresses the macOS pass got, and bidirectional reachability:

```
cluster  eth0  192.168.104.1/24
edge     eth0  192.168.104.3/24
edge $ ping -c2 192.168.104.1 → 0% loss, rtt avg 0.480 ms
```

so `CLUSTER_NODE_ADDR=192.168.104.1`, `EDGE_ADDR=192.168.104.3`. k3s picks up
`192.168.104.1` as its node InternalIP by itself, and `kube-dns` lands on
`10.43.0.10`, matching the stock `COREDNS_ADDR`. **✓** as documented.

Note that with `user-v2` attached, Lima gives the guest *only* that interface —
it replaces the default slirp NIC rather than supplementing it, so all traffic,
including bulk internet downloads, rides the user-v2 datapath. That matters for
F4b.

## F4b [BLOCKER, Linux-specific — intermittent] QEMU aborts under load on the `user-v2` datapath

Partway through `cluster/install-k3s.sh` (downloading the ~60 MB k3s binary) the
cluster VM vanished. Not an OOM — QEMU hit an assertion in its own network code
and dumped core:

```
qemu[stderr]: qemu-system-x86_64: net/net.c:2172: net_fill_rstate: Assertion `size == 0' failed.
Driver stopped due to error: `signal: aborted (core dumped)`
```

`net_fill_rstate` handles the length-prefixed framing on QEMU's socket-backed
netdevs, which is how Lima wires a guest to the `user-v2` userspace gateway. Host
QEMU is 10.2.1 (Debian `1:10.2.1+ds-1ubuntu3.2`) on Ubuntu 26.04.

It is a **throughput-triggered race, not a deterministic failure**: `limactl start`
followed by re-running the same script completed fine (the k3s binary had already
landed before the crash, so the retry moved far less data). Nothing is corrupted —
the VM disk persists and the run resumes — but any bulk transfer can kill the VM,
and the Linkerd install plus image pulls move far more than k3s did.

macOS is not exposed to this: Lima there runs on `vz`, which implements `user-v2`
over a different datapath, so the QEMU socket-netdev assertion is unreachable.
This is the one finding so far that is genuinely specific to Linux hosts, and it
is a property of the *substrate*, not of the demo.

Mitigations for a Linux follower, in order of preference: give the VMs a real
host bridge + tap (root on the host, sidesteps the socket netdev entirely); or
run the two roles on two actual Linux machines, which is what the demo documents
anyway and where the whole question disappears; or simply retry — the run is
resumable, subject to F4c.

## F4c [BUG, platform-independent] `gen-certs.sh` idempotence check tests existence, not validity

Fallout from the F4b crash, but the underlying weakness is in the script. The abort
took the VM down while `~/linkerd-certs/*` was still in page cache, so all four
files survived the reboot at **zero length**:

```
-rw------- 1 orion orion 0 Aug 12 00:57 ca.crt
-rw------- 1 orion orion 0 Aug 12 00:57 ca.key
-rw------- 1 orion orion 0 Aug 12 00:57 issuer.crt
-rw------- 1 orion orion 0 Aug 12 00:57 issuer.key
```

`gen-certs.sh` guards regeneration with `if [ ! -f ca.crt ]`, so on the retry it
saw the file, skipped `step certificate create` entirely, and exited 0 — reporting
success while leaving the trust anchor empty. The failure surfaced two steps later
in `install-linkerd.sh`, as an error that points nowhere near the real cause:

```
Error: No certificates found
...
error: no objects passed to apply
```

A follower who hit this would reasonably start debugging Linkerd. Testing validity
rather than existence (e.g. `step certificate inspect ca.crt >/dev/null 2>&1`)
would both catch the truncation and make the script honestly idempotent. Recovery
is just `rm -rf ~/linkerd-certs` and re-run.

## F7 [BUG, platform-independent] README's copy-into-guest recipe expands `~` on the host

README tells a Lima user to copy the repo in and then invoke scripts as:

```
limactl shell <vm> -- bash ~/linkerd-playground/demos/spiffe-cross-boundary/<script>
```

The `~` there is unquoted, so the **host** shell expands it before `limactl` ever
runs. Lima's guest home is never the host's — here host `/home/orion` vs guest
`/home/orion.guest` (on macOS, `/Users/x` vs `/home/x.linux`) — so the guest gets
a path that does not exist:

```
bash: /home/orion/linkerd-playground/demos/spiffe-cross-boundary/cluster/gen-certs.sh: No such file or directory
```

Quoting so the guest expands it works: `limactl shell <vm> bash -lc 'bash ~/linkerd-playground/…'`.

Separately, the `tar` recipe one line earlier copies `<repo>`, and it must be the
**repo root**, not the demo directory — every script resolves
`$(cd "$HERE/../.." && pwd)/lib/common.sh`. Copying just
`demos/spiffe-cross-boundary` leaves `lib/common.sh` missing and every script dies
on the source line. The README's `<repo>` placeholder is correct but easy to read
as "the thing you're working in", and the abbreviated `<demo>/` paths used
everywhere else in the doc encourage exactly that misreading.

## F9 [BLOCKER, platform-independent] the RetailCloud path never creates its namespace

Following the README straight through, `cluster/retail/apply.sh` dies on its first
command:

```
== retail-cloud app code -> ConfigMap ==
Error from server (NotFound): error when creating "STDIN": namespaces "mixed-env" not found
```

Nothing in the RetailCloud path creates `mixed-env`. It is declared in exactly one
place — `cluster/echo.yaml` — which belongs to the **appendix** "original CLI
beats" path that the README tells RetailCloud users *not* to run ("RetailCloud and
the beats share one edge proxy, so run one or the other"). `MANUAL.md` gets it
right at L477-478, so this is specific to the scripted path. The macOS pass
followed the manual, which is why it never surfaced.

**The obvious workaround is a trap.** A reader who fixes this the natural way —
`kubectl create namespace mixed-env` — gets a namespace with no
`linkerd.io/inject: enabled` annotation (`echo.yaml` carries it; a bare `create`
does not, and `retail-cloud.yaml` has no pod-level inject annotation of its own).
`retail-cloud` then runs **unmeshed**: no proxy, so no mTLS, no identity for the
`AuthorizationPolicy` to match, and a Void button that changes nothing. Every
symptom is silent — the app still serves, the dashboard still renders, and the
demo simply stops demonstrating what it claims to.

Fix applied: `apply.sh` now creates the namespace if absent and always applies the
inject annotation, with a comment explaining why the annotation is load-bearing.

## F10 [ERROR] the "Inspect the traffic" tap output is documented wrong

README's verification step is:

```bash
linkerd -n mixed-env viz tap deploy/retail-cloud
```

> Each inbound row shows `tls=true` and `client_id=spiffe://…/store/042/inventory-sync`
> (with `src_external_workload=store-pos`)

Three things are wrong, against Linkerd `edge-26.7.2`:

1. **The plain command shows no identity at all.** Default `tap` output stops at
   `tls=true`; `-o wide` is required for any identity field. As written, the
   reader runs the command and cannot see the thing the section exists to show.
2. **The field is `src_client_id`, not `client_id`.**
3. **`src_external_workload` does not exist in the output.** Grepping the wide
   output for it returns nothing.

What actually appears, and it does prove the claim:

```
req id=1:0 proxy=in src=192.168.122.11:47914 dst=10.42.0.15:8090 tls=true
  :method=POST :path=/ingest
  src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
  src_tls=true dst_authz_kind=authorizationpolicy dst_authz_name=ingest-allow-store
  dst_srv_kind=server dst_srv_name=retail-ingest
```

`dst_authz_name=ingest-allow-store` is a bonus the README doesn't mention and is
arguably the most convincing field present — it names the authorization policy
that admitted the request.

## F11 [NIT] `apply.sh` double-counts the certificates in the bundle

```bash
echo "bundle -> $HOME/spire-bundle.pem ($(grep -c CERTIFICATE "$HOME/spire-bundle.pem") cert(s))"
```

prints `2 cert(s)` for a bundle containing **one** certificate, because
`grep -c CERTIFICATE` matches both the `BEGIN` and `END` lines. Confirmed: the
exported `bundle.pem` is 599 bytes, one PEM block, byte-identical in size to
`ca.crt`. Harmless, but it invites a reader to think the bundle contains a chain.
`grep -c 'BEGIN CERTIFICATE'` is the fix.

## F6 [BLOCKER, CONFIRMED live — platform-independent] `cluster/spire/apply.sh` hard-requires Tailscale

`cluster/spire/apply.sh` runs under `set -euo pipefail` and calls
`bash "$HERE/firewall.sh"` partway through. `firewall.sh` does:

```bash
IFACE="${TAILSCALE_IFACE:-tailscale0}"
ip link show "$IFACE" >/dev/null 2>&1 || { echo "no $IFACE interface on this host" >&2; exit 1; }
```

With no `tailscale0` present, `firewall.sh` exits 1 and `set -e` aborts `apply.sh`
**before** it registers the workload entry, exports the bundle, and prints the join
token — i.e. before every output the edge box needs. README calls the Tailscale
overlay "strictly optional; the demo doesn't depend on it", and describes a flat
LAN as the default path; the scripted path does depend on it.

Distinct from the existing runlog entry at L156-163, which records the *manual's*
version of this as a **[GAP]** (the hardening recipe doesn't apply, NodePort stays
open on all interfaces). Via the scripts it is not a missing-hardening gap but a
hard stop. Masked on macOS because that run used the Tailscale overlay recipe and
followed MANUAL.md by hand rather than running the scripts.

**Confirmed live.** Run unmodified on the libvirt topology (no `tailscale0`), the
StatefulSet deploys and then:

```
partitioned roll out complete: 1 new pods have been updated...
no tailscale0 interface on this host          <- exit 1
```

It aborts before `entry create`, before `bundle show`, and before
`token generate` — so the edge box gets no workload registration, no trust bundle
and no join token. Every subsequent step is blocked. Re-running with
`TAILSCALE_IFACE=enp1s0` (the VM's real inter-box NIC) completed and produced all
three, which keeps the rule's intent: restrict the NodePort to the trusted
inter-host interface.

The existing runlog entry at L156-163 records the manual's version of this as a
**[GAP]** — the hardening recipe doesn't apply, so the NodePort stays open. Via
the scripts it is not a missing-hardening gap but a hard stop, on the path the
README calls the default.

## F5 [GAP, Linux-specific — CONFIRMED] uid 1000 collision on a Linux host

`edge/iptables.sh` redirects `--uid-owner ${APP_UID:-1000}` egress into the proxy,
and `store-pos` runs as `--user 1000:1000 --network host`. On a macOS host the
Lima guest user is uid 501, so uid 1000 belongs to nothing else. On a Linux host
whose user is uid 1000, the Lima guest's interactive user is *also* uid 1000,
because Lima maps the host user's uid into the guest. Confirmed on the cluster VM:

```
$ limactl shell linkerd-cluster -- bash -lc 'id -u; whoami'
1000
orion
```

So on a Linux host, `edge/iptables.sh` redirects not just `store-pos` but every
TCP connection the interactive `limactl shell` user makes. `sudo`-run commands
(uid 0) and the proxy itself (uid 2102) are unaffected, and the demo's own
remaining steps all run via `sudo`, so the happy path survives — but any
user-level `curl`/`apt`/`git` in the edge VM after `iptables.sh` is silently
routed through the proxy. On macOS the guest user is uid 501, so uid 1000 belongs
to nothing else and the collision cannot occur.

`APP_UID` is already configurable in `config.local.env`; the gap is that nothing
warns a Linux user to change it, and 1000 is the worst possible default there.

## F5b [BUG, platform-independent] changing `APP_UID` silently breaks the demo

Discovered while preparing the fix for F5. `APP_UID` is only half-honoured:

- `edge/iptables.sh` reads `APP_UID="${APP_UID:-1000}"` and redirects that uid;
- `store-pos/run-store-pos.sh` **hardcodes** `docker run … --user 1000:1000`.

So the documented remedy for F5 — set `APP_UID` in `config.local.env` — makes the
two disagree: the redirect rule targets the new uid while the container still runs
as 1000, whose traffic is no longer redirected. `store-pos` then talks to
`retail-cloud` without going through the proxy at all, so it has no SPIFFE
identity and the authorization policy rejects it. The failure looks like a policy
or identity bug, nowhere near the uid.

Fix applied: `run-store-pos.sh` now sources the config and uses
`--user "${APP_UID}:${APP_UID}"`.

## F8 [BUG, platform-independent] `install-k3s.sh` races CoreDNS and exits 1

The script's last two lines query the cluster immediately after the k3s installer
returns, but CoreDNS has not been created yet:

```
NAME              STATUS     ROLES    AGE   VERSION
linkerd-cluster   NotReady   <none>   0s    v1.36.3+k3s1
Error from server (NotFound): services "kube-dns" not found
```

Under `set -euo pipefail` that is exit 1, so the step reports failure on a
perfectly good install. Reproduced identically on both substrates, so it is not
Linux-specific — just never noticed, since the macOS pass ran the manual by hand.

It also breaks the README's very next instruction — *"Confirm the printed
`kube-dns` ClusterIP matches `COREDNS_ADDR`"* — because nothing is printed. A
follower has no way to perform the check they are told to perform. Waiting for the
service first (`kubectl -n kube-system rollout status deploy/coredns`, or a poll)
would fix both. Once CoreDNS settles, the value is correct: `10.43.0.10`, matching
the stock `COREDNS_ADDR`.

---

# Verified working on Linux/x86_64

With the fixes above applied, the demo runs end to end and demonstrates what it
claims. Nothing below required an arch-specific or OS-specific change: every
upstream artifact resolved a working amd64 build on its own
(`step` .deb via `dpkg --print-architecture`, `spire-*-linux-amd64-musl`, k3s
`sha256sum-amd64.txt`, and multi-arch images for `linkerd2-proxy`,
`spire-server` and `node:20-alpine`).

| Component | Result |
|---|---|
| `cluster/gen-certs.sh` | ✓ ECDSA P-256 root + intermediate, `step-cli` 0.30.6 resolved for amd64 |
| `cluster/install-k3s.sh` | ✓ k3s v1.36.3+k3s1, node InternalIP correct, kube-dns `10.43.0.10` (matches stock `COREDNS_ADDR`) — modulo F8 |
| `cluster/install-linkerd.sh` | ✓ **93/93 `linkerd check` green**, control plane + viz |
| `cluster/spire/apply.sh` | ✓ after F6 — StatefulSet ready, workload entry registered, bundle + join token issued |
| `net/shim.sh` | ✓ both CIDR routes installed, cluster DNS resolving across the boundary |
| `edge/install-spire-agent.sh` | ✓ `spire-agent` 1.15.2, join-token attestation, `Agent is healthy.` |
| `edge/extract-proxy.sh` | ✓ `linkerd2-proxy` 2.363.0 extracted from the image |
| `edge/iptables.sh` | ✓ uid-scoped REDIRECT chain installed |
| `store-pos/run-store-pos.sh` | ✓ container up and pushing |
| `cluster/retail/apply.sh` | ✓ after F9 — ExternalWorkload Ready, app + policy applied, NodePort 30080 |
| `edge/run-proxy.sh` | ✓ non-root uid 2102, SPIRE-issued SVID |

## The claims, checked

**Cross-boundary SPIFFE identity.** The proxy on the edge box obtains its identity
from the SPIRE agent, chained to the cluster's trust anchor:

```
INFO linkerd2_proxy: Local identity is spiffe://root.linkerd.cluster.local/store/042/inventory-sync
INFO daemon:identity: Certified identity id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
```

**mTLS with that identity, from outside the cluster.** `viz tap` on the receiving
deployment (see F10 for the doc corrections):

```
req proxy=in src=192.168.122.11 dst=10.42.0.15:8090 tls=true :path=/ingest
  src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
  src_tls=true dst_authz_name=ingest-allow-store
```

**Identity-based authorization, with no network change.** Driving the dashboard's
own Void button (`POST /api/policy {"allow":false}`, which exercises the RBAC Role
the app holds to patch its own `MeshTLSAuthentication`):

```
push -> 200                                    # before
push -> 403 (authorization voided by cloud)    # after voiding
push -> 200                                    # after restoring
```

The dashboard reflects it (`"voided":true` → `false`), and `/api/data` shows the
link live with both identities and `ageMs` in the low seconds. `/` and `/tutorial`
both serve.

**The root key never leaves the cluster.** `/opt/spire/certs/` on the edge holds
only `bundle.pem` and `ca.crt` (599 bytes each, the public root); the guard in
`install-spire-agent.sh` that refuses to run if `ca.key` is present was satisfied
throughout.

## Notable positive: the default LAN path is now verified

The macOS pass ran over the optional Tailscale overlay, leaving the README's
**default** flat-LAN static-route path unverified. This run exercised it directly
— two hosts on one L2 segment, `net/shim.sh` installing the pod/service routes and
pointing cluster DNS at CoreDNS — and it works:

```
10.42.0.0/16 via 192.168.122.10 dev enp1s0
10.43.0.0/16 via 192.168.122.10 dev enp1s0
$ getent hosts kubernetes.default.svc.cluster.local
10.43.0.1       kubernetes.default.svc.cluster.local
```

That is the path most readers will take, and it had never been run before.

## Verdict

**The demo works on Linux/x86_64.** Nothing about Linux or amd64 broke it — the
one genuinely Linux-specific finding (F4b) is a QEMU bug in a substrate *choice*,
not in the demo, and disappeared entirely on libvirt.

The more useful result is that driving the **scripts** rather than the manual
exposed six defects the macOS pass could not have seen, two of them
(F6, F9) hard blockers on the README's own documented path, and one (F9's
workaround trap) capable of leaving a follower with a demo that appears to run but
silently proves nothing.

---

# Second pass — clean-host replay (2026-08-12)

An independent re-run after the fixes above landed, on the same host but from a
clean slate (no VMs, no ssh config), following the **README verbatim** without
consulting this runlog — the point being to read the doc the way a first-time
follower does. It found two more blockers, both in the section every follower
must pass through, and both invisible to anyone who already had the environment
in their head.

## F12 [BLOCKER, platform-independent] the `S`/`D` shorthand cannot work as written

"Build it" opens by defining the shorthand every later command block uses:

```bash
S="ssh -F ~/.ssh/linkerd-playground.conf"
D=~/linkerd-playground/demos/spiffe-cross-boundary
```

Both lines are wrong, in opposite directions, and together they break **every**
command block in the section.

`S` puts the tilde inside double quotes, where bash never expands it. The first
command fails before reaching the network:

```
Can't open user config file ~/.ssh/linkerd-playground.conf: No such file or directory
```

`D` is the subtler one and the same class of defect as F7 — except F7 is in the
optional Lima appendix, while this is on the **verified path**. The tilde is
unquoted, so it expands on the *host*, but `D` is only ever used inside commands
that run in the *guest*:

```
$ D=~/linkerd-playground/demos/spiffe-cross-boundary; echo "$D"
/home/orion/linkerd-playground/...     # host home
$ ssh linkerd-cluster 'echo $HOME'
/home/demo                             # guest home
```

So every `bash $D/…` step would have died on a path that does not exist in the
guest. Fixed by using `$HOME` in `S` (expands, since it is a variable) and
single-quoting `D` (so the guest shell expands the tilde), with a note in the
README explaining why the two differ.

That F7 and F12 are the same mistake in two places suggests the tilde-across-a-
shell-boundary trap is worth a standing check on any new doc snippet.

## F13 [BLOCKER, platform-independent] the `linkerd` CLI is on no shell's `PATH`

"Inspect the traffic" tells the reader to run:

```bash
linkerd -n mixed-env viz tap deploy/retail-cloud -o wide
```

which fails:

```
timeout: failed to run command 'linkerd': No such file or directory
```

`install-linkerd.sh` does `export PATH="${HOME}/.linkerd2/bin:${PATH}"`, but that
applies to its own process only — nothing persists it. The binary is really there,
and reachable from **no** shell a follower would use:

| how you reach the box | `command -v linkerd` |
|---|---|
| `ssh host '<command>'` (the README's own style) | not found |
| `bash -lc` / interactive login | not found |
| inside `install-linkerd.sh` | found (process-local export) |

Ubuntu's `~/.bashrc` returns early for non-interactive shells, so even adding it
there would not fix the `ssh host '<command>'` form the README uses throughout.
Fixed by symlinking into `/usr/local/bin` next to the `kubectl` k3s already puts
there, which works in every case above. This also makes the script's own
`command -v linkerd` idempotence check meaningful on a re-run.

## ✓ Teardown, verified

`just demo spiffe-cross-boundary down` does what the README claims, and needed no
fix:

- both domains undefined; all four volumes gone, including the two `-seed.iso`
  files that `--remove-all-storage` does not always catch and `down.sh` deletes
  explicitly;
- **idempotent** — a second run reports `not defined` for both boxes, exit 0;
- **partial state** — with only Box A present it destroyed it and cleanly reported
  the edge as not defined;
- the ~600 MB cached cloud image is kept, so a rebuild does not re-download;
- **the host is left rebuildable**: `cluster-up` after teardown recreated the VM on
  fresh disks at the same address and reached `cluster-vm-ready`.

Teardown deliberately leaves the two DHCP reservations in libvirt's `default`
network. That is not a leak — `lib-libvirt.sh` uses deterministic MACs and
`dhcp_reserve` deletes any stale entry for the MAC before adding, so a rebuild
reuses them without conflict (confirmed by the rebuild above). The generated
`~/.ssh/linkerd-playground{,.conf}` also survive, pointing at hosts that no longer
exist until the next build. The README does not claim either is removed.

The bare-metal teardown instructions remain **unverified** — they need physical
hosts.

## Also this pass

- The `host-setup` step could not be re-executed (no passwordless sudo on this
  host, unchanged since F2), but every effect it produces was verified already
  present: the five packages, `libvirtd` enabled, the `default` network active, a
  storage pool, and `libvirt`/`kvm` group membership. It was a genuine no-op here,
  not a skipped step.
- Two script messages claimed "tailnet" on the libvirt path (`spire/apply.sh` and
  `retail/apply.sh`), a leftover from the macOS pass's overlay. Both are now
  topology-neutral, and the SPIRE echo no longer hardcodes a port that config
  already carries.
- The **CLI "beats" variant was removed** — the appendix documenting it is gone and
  the scripts had decayed past use: their `just` targets ran on the *host* while
  the scripts require kubectl/linkerd on the cluster VM, `beat1b` was never wired
  into the Justfile, and `beat1` expected a Lima-era hostname. Beat 3's direction
  (authorized mTLS *to* the edge) is the one thing RetailCloud does not
  demonstrate; that coverage was dropped deliberately.
- The dashboard loads Cytoscape from `unpkg.com`, so the **browser** needs
  internet for the topology to render. Not a defect, but it rules out an
  air-gapped demo.

## Second-pass verdict

The demo itself was never broken — every fix in this pass is documentation or
packaging. But both findings sat in the two sections a follower cannot skip, and
neither would be caught by anyone who already has `linkerd` on their `PATH` and a
working ssh alias in muscle memory. **A doc is only verified when it is replayed
from a clean host by someone reading it literally.**

With F12 and F13 fixed, the README now runs start to finish as written: `push ->
200` with the SPIFFE identity in `viz tap -o wide`, Void producing a real 403 and
restoring cleanly, and teardown returning the host to a rebuildable state.

# Third pass — regression replay on bare metal (2026-08-18)

A regression run, not a discovery run. The arm64/OrbStack work
([`runlog-orbstack.md`](runlog-orbstack.md)) rewrote surfaces this path shares:
"Build it"'s `S` shorthand became a shell function, and `lib/common.sh` /
`lib-libvirt.sh` gained the host-architecture guard. The question here was
narrow — **does the Linux/x86_64 libvirt path still run start to finish as the
README describes it?** — so the README was again followed literally, from a host
with no VMs defined.

## Environment

- Host: the same box as the first two passes. Ubuntu 26.04 LTS, kernel
  7.0.0-29-generic, x86_64, AMD Ryzen 3 3100 (4c/8t), 15.4 GiB RAM (12 GiB free),
  330 GiB free disk. KVM present, user in `libvirt` and `kvm`.
- Starting state: no libvirt domains, `default` network active, the ~600 MB
  Ubuntu 24.04 cloud image already in `~/.cache/linkerd-playground` from the
  earlier passes, so no re-download. `host-setup` was a verified no-op again (no
  passwordless sudo here; every effect it produces was already present).
- `config.local.env` carries the example's values verbatim.

## F14 [BLOCKER, Linux-specific] `virt-install` is present but does not run under a shadowing `python3`

The very first provisioning command died before creating anything:

```
$ just demo spiffe-cross-boundary cluster-up
[cluster-up.sh] creating linkerd-cluster (4 vcpu, 6144MiB, 40GiB) at 192.168.122.10
Traceback (most recent call last):
  File "/usr/bin/virt-install", line 5, in <module>
    from virtinst import virtinstall
  File "/usr/share/virt-manager/virtinst/__init__.py", line 8, in <module>
    import gi
ModuleNotFoundError: No module named 'gi'
```

`python3-gi` *is* installed, and `virt-install` *is* installed. The failure is
that `/usr/bin/virt-install` is a Python script with a `#!/usr/bin/env python3`
shebang, so it runs under whichever `python3` comes first on `PATH`. This host
has Homebrew on Linux, whose `python3` shadows the system one:

```
$ which -a python3
/home/linuxbrew/.linuxbrew/bin/python3
/usr/bin/python3
$ /usr/bin/python3 /usr/bin/virt-install --version
5.1.0
```

Brew's interpreter cannot see the distro's `gi` in
`/usr/lib/python3/dist-packages`, so the import fails. Homebrew is one instance
of a broad class — pyenv, conda, and an activated virtualenv all shadow the
system `python3` the same way, and none of them is exotic on a developer's Linux
box.

The demo's preflight did not catch it because it tests **existence**, not
**execution**:

```bash
for c in virsh virt-install qemu-img cloud-localds curl ssh; do
  command -v "$c" >/dev/null 2>&1 || die "missing '$c'. ..."
done
```

`command -v virt-install` succeeds on a binary that cannot run, so the follower
gets a Python traceback in virt-install's own voice, mid-provision, with nothing
naming the actual cause. It reads as a broken demo.

Fix applied: `lib-libvirt.sh` now asks `virt-install --version` after the
existence loop and, on failure, reports the captured error alongside the
shadowing diagnosis and the one-line workaround. Verified both directions on this
host — with the shadowing `python3` first it exits 1 with the new message and
provisions nothing; with `PATH=/usr/bin:$PATH` it passes and `cluster-up` reaches
`cluster-vm-ready`. Workaround for a follower who hits it:

```bash
PATH=/usr/bin:$PATH just demo spiffe-cross-boundary cluster-up
```

## The README, replayed

With `PATH` corrected, every documented checkpoint produced its documented
output. Nothing else needed a fix.

| Step | README claims | Observed |
|---|---|---|
| `cluster-up` / `edge-up` | two VMs at `.10` / `.11`, ssh config written | both `*-vm-ready`, `uname -m` = `x86_64` |
| `gen-certs.sh` | trust anchor + issuer | root CA `root.linkerd.cluster.local`, valid 2026-08-18 → 2036-08-15 |
| `install-k3s.sh` | prints kube-dns ClusterIP, must match `COREDNS_ADDR` | `10.43.0.10` — matches the default |
| `install-linkerd.sh` | ends `Status check results are √` | verbatim, k3s v1.36.3+k3s1, Linkerd edge-26.7.2 |
| `spire/apply.sh` | StatefulSet + NodePort + registration + join token | entry registered on `unix:uid:2102` + the proxy path; NodePort 30081 restricted to `enp1s0`; token printed |
| bundle relay | root key never leaves the cluster | only `bundle.pem` + `ca.crt` (603 B each) reach Box B |
| `net/shim.sh` | routes + `*.cluster.local` resolver | `pod=10.42.0.0/16 svc=10.43.0.0/16 dns=10.43.0.10`, exit 0 (the OrbStack `systemd-resolved` caveat is not a Linux/libvirt problem) |
| `install-spire-agent.sh` | ends `Agent is healthy.` | verbatim |
| `extract-proxy.sh` | exits `Invalid configuration: no destination service configured` | verbatim |
| `iptables.sh` | redirect for `APP_UID` | `PROXY_APP_OUTPUT`, uid 1000 → `:4140` |
| `run-store-pos.sh` before Box A | `push error: ENOTFOUND` | verbatim |
| `retail/apply.sh` | namespace, ExternalWorkload, app, policy, dashboard URL | rollout complete, `http://192.168.122.10:30080/` |
| `run-proxy.sh` | `proxy has identity (uid 2102)` | verbatim |
| store-pos after | `push -> 200` | verbatim (`ECONNREFUSED` for a few seconds first, while the proxy binds) |
| `viz tap … -o wide` | `src_client_id=spiffe://…/store/042/inventory-sync`, `dst_authz_name=ingest-allow-store` | verbatim, plus `tls=true` and `dst_srv_name=retail-ingest` |
| Void | `push -> 403 (authorization voided by cloud)` | verbatim; `/api/data` flips to `voided:true` |
| restore | pushes resume | `push -> 200` within one poll |

The dashboard served HTTP 200 on `/` and `/tutorial`, and `/api/data` carried both
identities — `retail-cloud.mixed-env.serviceaccount.identity.linkerd.cluster.local`
and `spiffe://root.linkerd.cluster.local/store/042/inventory-sync`.

Two notes on what the run does **not** prove:

- `linkerd check` emits three `‼` version-drift warnings (CLI and control plane
  at edge-26.7.2, latest edge 26.8.2). They are advisory and do not change the
  `√` verdict, but the demo is pinned behind the current edge.
- The end-to-end build ran against the branch tip before the architecture guard
  landed. The guard was pulled in afterward and `cluster-up` re-run green on this
  host; since it derives the amd64 URL that was previously hardcoded, the x86_64
  provisioning path is byte-identical either way. The arm64 libvirt branch stays
  unexercised here, as its own commit says.

## Third-pass verdict

The Linux/x86_64 path has **not** regressed: the arm64 work left it intact, and
the `S`-as-a-function rewrite copy-pastes and runs correctly under bash. One new
blocker, and it is the same lesson as F12 and F13 in a different costume — the
demo assumed a property of the follower's machine (here, that `python3` is the
system one) that the preflight never checked. **Every host assumption the scripts
rely on should be tested by executing it, not by looking for it.**

# Fourth pass — operator hand replay of the combined branch (2026-08-18)

The passes above each validated one line of work. This one validated the
**merge candidate**: the arm64/OrbStack support, the ergonomics pass on top of it,
and the Linux preflight fix from the third pass, assembled on a single branch and
run as one tree. Splitting the validation would have meant shipping a "verified"
claim against a combination that had never been assembled, so nothing merged until
this replay passed.

Driven **by hand by the operator**, reading the README, on the same Ubuntu 26.04 /
x86_64 host, from a torn-down slate — no domains, no volumes. Unlike the third
pass, the agent did not run the demo; it watched, diagnosed what the operator hit,
and fixed it live on the branch under validation, so every fix below was itself
exercised by the remainder of the run.

## F15 [BLOCKER, Linux-specific] the preflight told the operator to fix `PATH` by hand

F14's guard correctly diagnosed the shadowed-`python3` failure and then handed
back a chore: prefix `PATH=/usr/bin:$PATH` on every provisioning command. That is
the same defect class it was meant to cure. It is one more thing to remember on
every invocation, it silently changes which of *everything else* the command gets,
and the interpreter `virt-install` needs is not a preference anyone should be
expressing.

Fix: when `virt-install` cannot run under the inherited interpreter, retry it
under `/usr/bin/python3` and use that for the provisioning call, reporting the
substitution in one line. The error is now raised only when neither interpreter
can run it, and it says the fallback was tried and points at `python3-gi` rather
than at `PATH`. Verified in all three states, and the fallback's invocation was
checked with `virt-install --dry-run` over the exact argument set `vm_create`
passes.

The captured error also stopped being truncated to its last line. That truncation
had only ever been exercised against one failure shape, and a traceback's last
line is not reliably the informative one.

## F16 [BLOCKER, platform-independent] a pasted command block ran on past its own failure

Every multi-command block in "Build it" was a bare list of newline-separated
commands, and they are meant to be pasted as a unit. The operator pasted
`cluster-up` and `edge-up` together. `cluster-up` died in preflight; `edge-up` ran
anyway and ended with `edge-vm-ready`. The failure had scrolled off, and the last
thing on screen read like success. The next command failed with

```
ssh: connect to host 192.168.122.10 port 22: No route to host
```

against a Box A that had never been created — a symptom that points at the
network, three steps from a cause that was a preflight error.

`set -e` does not help here: these are separate top-level invocations in an
interactive shell, not a script. All five blocks now chain with a trailing `&&`,
so the first failure ends the run where it happened.

## F17 [BUG, platform-independent] `&&` cannot see a failed copy in the relay step

Chaining step 3 with `&&` looked like it closed the same hole there, and did not.
Each copy is a **pipeline**, and a pipeline's exit status is its last command's:

```
$ cat /nonexistent | tee dest ; echo $?
0
```

So a `cat` that finds nothing still leaves `tee` succeeding, an **empty** file
lands, and the step reports success. The consequence surfaces steps later as an
agent that cannot attest, with nothing pointing back at a zero-byte `bundle.pem`.

Documenting it was tried first and rejected: a reader told to go check three files
by hand is a reader who skips it on the run where it matters. The block now
defines a `relay` helper whose remote side ends in `sudo test -s`, putting "did a
non-empty file actually land?" last in the pipeline, where the `&&` chain reads
it. Verified against a live guest — missing source exits 1, empty source exits 1,
real content exits 0 and arrives intact, and a failed relay stops the relays after
it. It does not prevent the zero-byte file from being created, since `tee` has run
by then; it prevents that file from being mistaken for a good one.

## F18 [GAP] `status` stopped short of the address you want from it

`status` reported both boxes and not the one fact an operator runs it for — where
to point a browser. That address is not derivable from config: the host half
depends on the topology, the port half is a NodePort Kubernetes allocates. It now
asks the cluster through the same `cluster/retail/url.sh` that "Build it" uses,
and stays silent whenever there is no answer yet (no ssh config, cluster
unreachable, app not deployed), because a half-built demo is the normal state for
someone running `status`.

Worth recording as its own hazard: written as `[ -n "$url" ] && log …`, the final
test would have made an absent URL the **script's exit status** under `set -e`, so
`status` would have exited 1 on every run before step 5 while looking fine. It is
an `if`.

## ✓ End state, observed

With the demo built by hand and left running:

```
push -> 200
```

```
req id=0:0 proxy=in src=192.168.122.11:35286 dst=10.42.0.15:8090 tls=true
  :method=POST :path=/ingest
  src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
  src_tls=true dst_authz_kind=authorizationpolicy dst_authz_name=ingest-allow-store
```

The dashboard served HTTP 200 and reported both identities —
`retail-cloud.mixed-env.serviceaccount.identity.linkerd.cluster.local` and
`spiffe://root.linkerd.cluster.local/store/042/inventory-sync` — with
`voided:false, reporting:true`. k3s v1.36.3+k3s1, Linkerd edge-26.7.2.

## Fourth-pass verdict

Four defects, and not one of them was in the demo's mechanism — SPIFFE identity,
mTLS and the authorization policy behaved correctly throughout, as they have since
the first pass. All four were in the **seam between the documentation and the
operator's machine**: an interpreter the scripts assumed, a paste that outran its
own failure, a pipeline that reported success for a file that never arrived, and a
status line that withheld the address.

The through-line from F12 and F13 holds, and sharpens. Those found that a doc is
only verified when it is replayed literally from a clean host. This pass adds:
when the failure mode is the operator's environment or the operator's shell, the
fix belongs in the code, not in a sentence telling them what to do about it. Three
of these four were first "fixed" with prose — a note about `PATH`, a note about
checking three files — and each of those notes was replaced by something that
simply works.

Also this pass:

- The `S`-as-a-function shorthand from the arm64 work pastes and runs correctly
  under bash.
- `linkerd check` still emits three advisory version-drift warnings (edge-26.7.2
  against a latest edge of 26.8.2). They do not change the `√` verdict, but the
  demo is pinned behind current edge and it is worth a look as maintenance.
- The arm64 libvirt branch remains **unexercised**: it needs an arm64 Linux host
  with KVM, which this is not. `--boot uefi` is still written but unrun.
