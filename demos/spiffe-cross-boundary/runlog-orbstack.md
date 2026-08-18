# SPIFFE cross-boundary demo — OrbStack validation runlog

A record of standing the demo up on **OrbStack** on Apple Silicon, to answer one
question: can the two boxes run as native arm64 Linux machines on a Mac, without
x86 emulation?

Short answer: **yes**, with one OrbStack-specific fix. The demo's own scripts ran
unmodified except for the DNS step (F3).

- **Method:** full live, clean start. Two OrbStack machines stand in for the
  manual's "two Linux hosts" — `linkerd-cluster` (Kubernetes/cloud) and
  `linkerd-edge` (the external store). This is the
  [`README.md`](README.md) **"Two physical Linux hosts"** topology, not the
  libvirt one: `host-setup` / `cluster-up` / `edge-up` were never run, since those
  provision libvirt VMs and are Linux-host-only.
- **Motivation:** a demo user reported QEMU x86 running "glacially slow" on Apple
  Silicon and asked whether the demo can run natively. See F2 for how that happens.

Legend: **[BLOCKER]** stops a follower cold · **[GAP]** missing step/context ·
**[NIT]** minor · **✓** verified working.

---

## Environment

- Host: macOS 15.7.4, Apple M4, 16 GiB RAM.
- Substrate: OrbStack 2.2.3 (20963), machines created with
  `orb create --cpus N --memory NG --disk NG ubuntu:24.04 <name>`.
- Guests: Ubuntu 24.04.4 LTS (noble), **arm64**, kernel
  `7.0.14-orbstack-00380-ga7e0a2dc9535`.
- Addresses: cluster `192.168.139.205`, edge `192.168.139.206` (assigned by
  OrbStack; written into `config.local.env`).
- Date: 2026-08-18.

---

## F1 [✓] Two machines, mutually reachable, with zero network configuration

`orb create` gave each machine its own address on a shared subnet. Bidirectional
ping is ~0.08 ms with nothing configured:

```
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.075/0.077/0.080/0.002 ms
```

This is the demo's "bring-your-own IP reachability" precondition satisfied for
free. It is the one place OrbStack is clearly better than the alternatives: the
Lima pass ([`runlog.md`](runlog.md)) had to attach a `user-v2` network by hand
because stock Lima gives every VM the same address, and the libvirt path needs
DHCP reservations on `virbr0`.

## F2 [GAP] `orb create -a amd64` silently gives you an emulated x86 machine

`orb create --help` advertises `Supported CPU architectures: arm64  amd64`, and
its own examples show `orb create -a amd64 fedora foo`. On an Apple Silicon Mac
that flag produces an emulated x86_64 machine — correct, and very slow.

The default is host architecture, so **omitting `-a` is the whole fix**. Nothing
in this repo asks for amd64; but [`README.md`](README.md) leads its verification
section with "Verified end-to-end on Linux/x86_64" and mentions arm64 only as a
later aside, which is enough to steer a careful reader onto an emulated machine
deliberately. That wording is the actual defect behind the original report.

Diagnostic, inside the machine: `uname -m` → `x86_64` means the machine itself is
emulated; recreate it without `-a`.

## F3 [BLOCKER, OrbStack-specific] `net/shim.sh` fails — `systemd-resolved` is masked

`net/shim.sh` ends by writing a `systemd-resolved` drop-in and restarting the
service. In an OrbStack machine that fails:

```
Failed to restart systemd-resolved.service: Unit systemd-resolved.service is masked.
```

OrbStack owns guest DNS: `systemd-resolved` is masked, and `/etc/resolv.conf` is a
symlink to `/opt/orbstack-guest/etc/resolv.conf`, a **read-only** file that
delegates to the macOS resolver.

Everything *before* the DNS step succeeded — the script had already installed the
pod and service routes, and CoreDNS was reachable across the machine boundary:

```
10.42.0.0/16 via 192.168.139.205 dev eth0
10.43.0.0/16 via 192.168.139.205 dev eth0
$ dig +short @10.43.0.10 kubernetes.default.svc.cluster.local
10.43.0.1
```

So only the resolver wiring is broken, not connectivity.

**Fix (verified):** replace the symlink with a real `resolv.conf` that puts
CoreDNS first. Run on the edge machine after `net/shim.sh` fails:

```bash
sudo rm -f /etc/resolv.conf
printf 'search cluster.local\nnameserver 10.43.0.10\nnameserver 0.250.250.200\n' \
  | sudo tee /etc/resolv.conf
```

`0.250.250.200` is OrbStack's own resolver, kept as a fallback. Both cluster and
external names then resolve — CoreDNS forwards what it does not own:

```
$ getent hosts kubernetes.default.svc.cluster.local
10.43.0.1       kubernetes.default.svc.cluster.local
$ getent hosts github.com
172.182.252.133 github.com
```

Caveat not tested: whether OrbStack restores its own `resolv.conf` symlink when a
machine restarts.

## F4 [✓] k3s runs, despite the shared kernel

This was the main open risk — OrbStack machines are lighter than full VMs (F6) —
and it cleared without incident. `cluster/install-k3s.sh` resolved the arm64
binary on its own and the node came up `Ready`:

```
NAME              STATUS   ROLES           VERSION        INTERNAL-IP       KERNEL-VERSION
linkerd-cluster   Ready    control-plane   v1.36.3+k3s1   192.168.139.205   7.0.14-orbstack-... (arm64)
kube-dns ClusterIP (must match COREDNS_ADDR): 10.43.0.10
```

The `kube-dns` ClusterIP matched the `COREDNS_ADDR` default, so no config change
was needed. `cluster/install-linkerd.sh` then finished with
`Status check results are √` (the `‼ proxies are up-to-date` notes are the usual
"a newer edge exists than the pinned `edge-26.7.2`" advisory, not failures).

## F5 [✓] iptables works — both the NodePort restriction and the edge redirect

`cluster/spire/apply.sh` restricted the SPIRE NodePort to the interface facing the
edge (`DROP 6 -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:30081`), and `edge/iptables.sh`
installed the redirect chain intact:

```
Chain PROXY_APP_OUTPUT (1 references)
 RETURN     0    --  *      lo
 REDIRECT   6    --  *      *      redir ports 4140
Chain OUTPUT
 PROXY_APP_OUTPUT  6    --  *      *      owner UID match 1000
```

Both the `REDIRECT` and the `owner UID match` — the parts most likely to be
restricted in a shared-kernel environment — behave normally.

## F6 [NIT] `--cpus` / `--memory` are limits, not guest sizing

Both machines report the host's full resources regardless of what was requested
(`--cpus 4 --memory 6G` and `--cpus 2 --memory 3G` both show 9 CPUs / 7 GiB
inside). Both also run the identical kernel build, confirming OrbStack machines
share one kernel rather than being separate VMs.

Consequence for this demo: the `CLUSTER_*` / `EDGE_*` sizing values in
`config.example.env` do not shape an OrbStack machine the way they shape a libvirt
or Lima VM. Nothing broke on a 16 GiB host, but the two boxes are not
resource-isolated from each other the way the two-machine story implies.

## F7 [NIT] The machine user is uid 501, so `APP_UID=1000` is safe here

The OrbStack guest user inherits the macOS uid (501). `APP_UID=1000` therefore
belongs to nothing else, and the edge's `owner UID match 1000` rule catches only
the demo app. This is the same situation as the Lima pass, and the opposite of the
bare-metal Linux case in [`runlog-linux.md`](runlog-linux.md), where the human
user *is* uid 1000 and their shell traffic gets redirected too.

## F8 [✓] No `/dev/kvm` — the libvirt path cannot run inside an OrbStack machine

Neither machine has `/dev/kvm`. This does not matter for the topology used here
(the machines *are* the two boxes), but it does mean `scripts/host-setup.sh` and
the libvirt path cannot be run *inside* an OrbStack machine — there is no nested
hypervisor to accelerate, and `libvirtd` would have nothing to work with.

## F9 [✓] End to end: identity-based authorization works

Everything from SPIRE attestation through the authorization flip behaved as the
README describes.

- `cluster/spire/apply.sh` registered the workload entry and issued a join token;
  the bundle and root cert relayed to the edge.
- `edge/install-spire-agent.sh` attested with the join token; the agent runs
  unsupervised via `setsid`, as the demo intends.
- `edge/extract-proxy.sh` pulled `cr.l5d.io/linkerd/proxy:edge-26.7.2` (arm64) and
  reported `release 2.363.0`. Its exit with `Invalid configuration: no destination
  service configured` is expected and guarded.
- `edge/run-proxy.sh` → `proxy has identity (uid 2102)`.
- `store-pos/run-store-pos.sh` → `push -> 200`.

`linkerd viz tap` shows the whole point of the demo — a workload on another
machine, authenticated by SPIFFE identity:

```
req id=0:0 proxy=in src=192.168.139.206:47156 dst=10.42.0.15:8090 tls=true
  :method=POST :path=/ingest
  src_client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync
  src_tls=true
  dst_authz_kind=authorizationpolicy dst_authz_name=ingest-allow-store
```

Repointing the `MeshTLSAuthentication` at a different SPIFFE ID (what the
dashboard's **Void** button does) flips the pushes, and restoring it flips them
back:

```
push -> 403 (authorization voided by cloud)
push -> 200
```

Nothing about the network changed between those two states — only the allowed
identity.

---

## Summary

**The demo runs on OrbStack, natively on arm64, with one fix.** Every script ran
unmodified except `net/shim.sh` (F3), whose DNS step needs an OrbStack-specific
replacement. No arch-related failure appeared anywhere: k3s, step-cli, SPIRE, the
Linkerd proxy image and `node:20-alpine` all resolved arm64 builds on their own,
which is what the arch-aware helpers in `lib/common.sh` are for.

For the original report — QEMU x86 crawling on Apple Silicon — the cause is F2,
and the fix is to create machines without `-a amd64`. The contributing defect is
this repo's own wording, which presents x86_64 as the verified architecture and
arm64 as an aside.

Where OrbStack sits against the other macOS option:

| | OrbStack | Lima |
|---|---|---|
| VM-to-VM reachability | works as created | needs `user-v2` attached by hand |
| DNS shim | needs the F3 fix | works as written |
| Resource isolation between boxes | none (shared kernel, F6) | real, per-VM |
| Verified end to end | this runlog | [`runlog.md`](runlog.md) |

Both work. OrbStack trades away the resource isolation and the working DNS step
for networking that needs no setup at all.
