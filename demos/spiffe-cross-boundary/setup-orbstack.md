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

`orb list` prints the address OrbStack assigned each machine:

```bash
orb list
```

```
linkerd-cluster  running  ubuntu  noble  arm64  ...  192.168.139.205
linkerd-edge     running  ubuntu  noble  arm64  ...  192.168.139.206
```

Put **your** two addresses in `config.local.env` at the demo root, next to
`config.example.env`:

```bash
cat > config.local.env <<'EOF'
CLUSTER_NODE_ADDR=192.168.139.205
EDGE_ADDR=192.168.139.206
EOF
```

Nothing else in the config needs changing. `APP_UID=1000` is safe here: the
OrbStack machine user inherits your macOS uid (usually 501), so uid 1000 belongs
to nothing else.

## 3. Copy the repo into both machines

The scripts source `lib/common.sh` from the repo root, so copy the **whole repo**,
not just the demo directory:

```bash
for m in linkerd-cluster linkerd-edge; do
  tar --exclude=.git --exclude=site/node_modules --exclude=site/dist -C . -czf - . \
    | orb -m "$m" bash -lc 'rm -rf ~/linkerd-playground && mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
done
```

Run that from the **repo root**, not the demo directory.

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

## 5. Follow Build it — with one deviation

Go to [`README.md`](README.md) → **Build it** and work through it from the top.
Everything applies as written, including the bundle-relay pipes.

**The one deviation** is `net/shim.sh`, the first command in *Box B*. It ends by
writing a `systemd-resolved` drop-in, and OrbStack machines have `systemd-resolved`
masked — OrbStack owns guest DNS, with `/etc/resolv.conf` symlinked to a read-only
file. The script fails on its last line:

```
Failed to restart systemd-resolved.service: Unit systemd-resolved.service is masked.
```

Everything before that line succeeded — the pod and service routes are installed
and CoreDNS is reachable. Only the resolver wiring is missing. Replace it by hand:

```bash
S linkerd-edge 'sudo rm -f /etc/resolv.conf'
S linkerd-edge 'printf "search cluster.local\nnameserver 10.43.0.10\nnameserver 0.250.250.200\n" | sudo tee /etc/resolv.conf'
```

`10.43.0.10` is CoreDNS (the `COREDNS_ADDR` default, confirmed by
`install-k3s.sh`); `0.250.250.200` is OrbStack's own resolver, kept as a fallback
for names CoreDNS does not own. Check both kinds of name resolve:

```bash
S linkerd-edge 'getent hosts kubernetes.default.svc.cluster.local; getent hosts github.com'
```

Then carry on with the next Build it command.

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
