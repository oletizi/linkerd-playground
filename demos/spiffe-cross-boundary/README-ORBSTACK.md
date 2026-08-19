# Setup recipe — two boxes with OrbStack on macOS

The demo needs two Linux hosts that can reach each other. On an Apple Silicon Mac,
[OrbStack](https://orbstack.dev/) gives you two native arm64 Linux machines in
about a minute, already able to talk to each other.

This page covers **only** the substrate: creating the machines and wiring your
shell to them. When you reach the end, you follow [`README.md`](README.md) →
**Build it** exactly as written — every command there works unchanged. There is
one deviation along the way, flagged in step 5.

Verified end to end; findings in [`runlog-orbstack.md`](runlog-orbstack.md).

> `scripts/cluster-up.sh` and `scripts/edge-up.sh` do **not** drive OrbStack —
> off Linux they fall back to Lima. Create the machines here instead; you never run
> `host-setup`, `cluster-up`, or `edge-up`.

---

## 1. Create the two machines

```bash
orb create --cpus 4 --memory 6G --disk 40G ubuntu:24.04 linkerd-cluster
orb create --cpus 2 --memory 3G --disk 20G ubuntu:24.04 linkerd-edge
```

> **Do not pass `-a amd64`.** OrbStack can build x86_64 machines on Apple Silicon,
> and its own `--help` examples show the flag — but on an arm64 Mac that means
> emulation, and the demo becomes unusably slow. Omitting `-a` gives you your
> host's architecture, which is what you want.

Confirm you got native machines — both must say `aarch64` on an Apple Silicon Mac:

```bash
orb -m linkerd-cluster uname -m
orb -m linkerd-edge uname -m
```

Install the packages the two boxes need:

```bash
orb -m linkerd-cluster bash -lc 'sudo apt-get update -qq && sudo apt-get install -y -qq curl iptables jq'
orb -m linkerd-edge    bash -lc 'sudo apt-get update -qq && sudo apt-get install -y -qq curl iptables jq docker.io'
```

## 2. Point the config at the machines

The demo's scripts need the two addresses OrbStack assigned. They read them from
`config.local.env`. This writes that file:

```bash
just demo spiffe-cross-boundary orb-config
```

```
[orb-config.sh] wrote .../demos/spiffe-cross-boundary/config.local.env
  CLUSTER_NODE_ADDR=192.168.139.94
  EDGE_ADDR=192.168.139.88
```

> **Do this every time you recreate the machines.** `config.local.env` is
> gitignored, so it outlives the boxes it describes — a file left from a previous
> run names machines that no longer exist, step 3 copies it into the fresh guests,
> and `net/shim.sh` then fails with "cannot reach the cluster node". The command
> above is safe to re-run at any point.

Nothing else in the config needs changing. `APP_UID=1000` is safe here: the
OrbStack machine user inherits your macOS uid (usually 501), so uid 1000 belongs
to nothing else.

## 3. Copy the repo into both machines

The scripts source `lib/common.sh` from the repo root, so copy the **whole repo**,
not just the demo directory:

```bash
for m in linkerd-cluster linkerd-edge; do
  tar --no-xattrs --exclude=.git --exclude=site/node_modules --exclude=site/dist -C . -czf - . \
    | orb -m "$m" bash -lc 'rm -rf ~/linkerd-playground && mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
done
```

Run that from the **repo root**, not the demo directory.

> `--no-xattrs` keeps macOS from packing its extended attributes into the archive.
> Without it, GNU tar in the guest prints
> `Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.provenance'`
> once per file — harmless (it is a macOS Gatekeeper tag, meaningless on Linux, and
> file contents and permissions are unaffected), but alarming in bulk.

## 4. Wire up the `S` shorthand

Build it drives both boxes over ssh through a config file. OrbStack serves ssh on
`localhost:32222` with its own key, so write a config that points there — then the
README's commands work with no changes:

```bash
cat > ~/.ssh/linkerd-playground.conf <<'EOF'
Host linkerd-cluster linkerd-edge
    HostName 127.0.0.1
    Port 32222
    IdentityFile ~/.orbstack/ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
Host linkerd-cluster
    User linkerd-cluster
Host linkerd-edge
    User linkerd-edge
EOF
```

> The `User` is the **machine name**. That is OrbStack's convention: `ssh
> MACHINE@orb` means "the default user on MACHINE". Run `orbctl ssh` to see the
> settings this file encodes.

> If you have previously run the Linux/libvirt path, this overwrites the
> `~/.ssh/linkerd-playground.conf` that `cluster-up.sh` generated. Keep a copy if
> you still need it.

Now define the shorthand from Build it and check it:

```bash
S() { ssh -F "$HOME/.ssh/linkerd-playground.conf" "$@"; }
D='~/linkerd-playground/demos/spiffe-cross-boundary'

S linkerd-cluster "uname -m; ls $D/cluster/gen-certs.sh"
```

That should print `aarch64` and the script's path inside the machine. `S` is a
function rather than a string so it behaves the same in `zsh` (the macOS default)
and `bash` — see the note in Build it for why the string form breaks under `zsh`.

## 5. Follow Build it

Go to [`README.md`](README.md) → **Build it** and work through it from the top.
Every command applies as written, including the bundle-relay pipes. There is no
OrbStack-specific step.

One thing is worth knowing about, because OrbStack is the reason the script does
it. `net/shim.sh` (the first command in *Box B*) needs `*.cluster.local` to resolve
via CoreDNS. On stock Ubuntu that means a `systemd-resolved` drop-in — but OrbStack
owns guest DNS: the unit is masked and `/etc/resolv.conf` is a symlink to a
read-only file. The script detects that and writes `/etc/resolv.conf` itself,
keeping OrbStack's own resolver for names CoreDNS does not own. You should see:

```
[shim.sh] systemd-resolved is masked or absent here; writing /etc/resolv.conf directly
[shim.sh] route + cluster DNS shim applied (...); kubernetes.default.svc.cluster.local resolves
```

That second line is the script proving DNS works rather than assuming it — it
resolves a real cluster name before reporting success, and stops with a diagnosis
if it cannot. If it stops there, the usual cause is that the Box A steps have not
run yet, so there is no CoreDNS to answer.

To see what it configured:

```bash
S linkerd-edge 'cat /etc/resolv.conf'
```

## Teardown

```bash
orb delete linkerd-cluster linkerd-edge
```

`just demo spiffe-cross-boundary down` does **not** apply — it destroys libvirt or
Lima VMs, not OrbStack machines.

## Two things to know about OrbStack machines

- **They share one kernel.** `--cpus` and `--memory` are limits, not guest sizing:
  both machines report the host's full CPU and RAM. The two boxes are not
  resource-isolated from each other the way two real hosts, or two VMs, would be.
- **There is no `/dev/kvm` inside a machine.** Irrelevant here, since the machines
  *are* the two boxes — but it does mean you cannot run the repo's libvirt path
  (`host-setup.sh`) inside one.

Neither affects what the demo teaches. Both are recorded in
[`runlog-orbstack.md`](runlog-orbstack.md).
