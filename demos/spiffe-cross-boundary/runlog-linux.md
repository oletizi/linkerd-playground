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
- Substrate: Lima 2.2.0 driving QEMU/KVM (not macOS `vz`), Ubuntu 24.04 cloud
  image, guest arch x86_64. Host tooling installed per F2.
- Started: 2026-08-12.

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

## F4 [pending] VM-to-VM networking

Lima's default QEMU user-mode NAT gives every VM `192.168.5.15` with no path
between VMs. Satisfying the README's "bring your own L3 reachability"
precondition on Linux uses the same mechanism the macOS run used: Lima's
`user-v2` network (userspace, no host sudo; gateway 192.168.104.1, already
defined in the stock `~/.lima/_config/networks.yaml`). The repo's provisioner
YAMLs declare no network, so this must be attached per-VM.

## F6 [BLOCKER, suspected — platform-independent] `cluster/spire/apply.sh` hard-requires Tailscale

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

Workaround for this run: `TAILSCALE_IFACE=<inter-VM iface>`, which keeps the
intent (restrict the NodePort to the trusted inter-host interface).

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
To re-confirm on the edge VM (where the rule actually gets installed).
