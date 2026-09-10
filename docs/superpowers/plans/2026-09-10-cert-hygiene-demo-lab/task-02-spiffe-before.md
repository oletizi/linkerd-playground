# Task 2: SPIFFE pre-refactor snapshot

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** Record exactly what the SPIFFE demo's three cluster-side scripts do *before* Task 3 moves their logic into `lib/`, so Task 3 can prove it changed nothing (spec § 1.4). Then return the lab VM to a clean state.

**Files:**
- Create: `demos/cert-hygiene/lab/refactor-check.sh`
- Create: `demos/cert-hygiene/lab/refactor-cleanup.sh`
- Create (output, committed): `demos/cert-hygiene/runs/_refactor-check/before/`

**Interfaces:**
- Consumes (Task 1): `scripts/in-lab.sh [--detach LOG] SCRIPT [args]`, `scripts/wait-log.sh LOG [timeout]`, `lib/common.sh`
- Produces:
  - `lab/refactor-check.sh <out-dir>`: runs `gen-certs.sh`, `install-k3s.sh`, `install-linkerd.sh` from `demos/spiffe-cross-boundary/cluster/` and writes `<name>.log` (ending `[exit N]`), plus `linkerd-check.txt`, `linkerd-version.txt`, and `pods.txt`. Refuses an existing out-dir.
  - `lab/refactor-cleanup.sh`: uninstalls k3s, the Linkerd CLI, the `step` package, and `~/linkerd-certs`, so the next run starts from the same clean state. Task 3 reuses both scripts for the after-snapshot.

- [ ] **Step 1: Write `demos/cert-hygiene/lab/refactor-check.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. Runs the SPIFFE demo's three cluster-side scripts on a clean
# box and records what they print, so the lib/ refactor can be compared against the
# behaviour it replaced (design spec section 1.4). Usage: refactor-check.sh <out-dir>
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

out="${1:?usage: refactor-check.sh <out-dir>}"
[ ! -e "$out" ] || die "$out already exists; refusing to overwrite recorded output"
mkdir -p "$out"
spiffe="$ROOT/demos/spiffe-cross-boundary/cluster"

run_step() { # name script
  local name="$1" script="$2" rc=0
  log "running $name"
  bash "$script" > "$out/$name.log" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$out/$name.log"
  [ "$rc" -eq 0 ] || die "$name failed (exit $rc); see $out/$name.log"
}

run_step gen-certs "$spiffe/gen-certs.sh"
run_step install-k3s "$spiffe/install-k3s.sh"
run_step install-linkerd "$spiffe/install-linkerd.sh"

rc=0
linkerd check > "$out/linkerd-check.txt" 2>&1 || rc=$?
printf '[exit %s]\n' "$rc" >> "$out/linkerd-check.txt"
linkerd version > "$out/linkerd-version.txt" 2>&1
kubectl get pods -A > "$out/pods.txt"
log "recorded SPIFFE cluster-side behaviour in $out"
```

- [ ] **Step 2: Write `demos/cert-hygiene/lab/refactor-cleanup.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. Removes everything refactor-check.sh installed, so the next
# run (or the cert-hygiene lab itself) starts from the same clean machine: k3s, the
# Linkerd CLI, the step CLI package, and the SPIFFE demo's cert directory.
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  log "uninstalling k3s"
  sudo /usr/local/bin/k3s-uninstall.sh
fi
rm -rf "$HOME/linkerd-certs" "$HOME/.linkerd2" "$HOME/.kube"
sudo rm -f /usr/local/bin/linkerd
if dpkg -s step-cli >/dev/null 2>&1; then
  log "removing the step-cli package"
  sudo dpkg -r step-cli
fi

for leftover in /usr/local/bin/k3s /usr/local/bin/linkerd "$HOME/linkerd-certs"; do
  [ ! -e "$leftover" ] || die "cleanup left $leftover behind"
done
command -v step >/dev/null 2>&1 && die "cleanup left the step CLI installed"
log "lab VM is clean"
```

- [ ] **Step 3: Syntax-check and shellcheck**

Run: `cd demos/cert-hygiene && bash -n lab/refactor-check.sh && bash -n lab/refactor-cleanup.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/refactor-check.sh lab/refactor-cleanup.sh'`
Expected: no output.

- [ ] **Step 4: Confirm the VM is clean before recording**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/refactor-cleanup.sh`
Expected: ends with `[refactor-cleanup.sh] lab VM is clean`. On a VM fresh from Task 1 it removes nothing.

- [ ] **Step 5: Record the pre-refactor behaviour (detached; installs take minutes)**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh --detach .lab-logs/before.log lab/refactor-check.sh runs/_refactor-check/before`
Then run: `cd demos/cert-hygiene && bash scripts/wait-log.sh .lab-logs/before.log 1500`
Expected: exit 0, with a tail ending `[refactor-check.sh] recorded SPIFFE cluster-side behaviour in runs/_refactor-check/before` and `[exit 0]`. If `wait-log.sh` itself hits the Bash tool's own time limit, run it again; the detached job keeps going.

- [ ] **Step 6: Inspect the record**

Run: `ls demos/cert-hygiene/runs/_refactor-check/before && tail -n 3 demos/cert-hygiene/runs/_refactor-check/before/*.log demos/cert-hygiene/runs/_refactor-check/before/linkerd-check.txt`
Expected files: `gen-certs.log`, `install-k3s.log`, `install-linkerd.log`, `linkerd-check.txt`, `linkerd-version.txt`, `pods.txt`. Every `.log` ends `[exit 0]`. `linkerd-check.txt` ends with `Status check results are √` (possibly with a `‼` version warning, since `edge-26.7.2` is not the latest edge) and `[exit 0]`.

- [ ] **Step 7: Confirm no private key was recorded**

Run: `grep -rl 'PRIVATE KEY' demos/cert-hygiene/runs/_refactor-check/ || echo none`
Expected: `none`. The SPIFFE scripts keep their keys in `~/linkerd-certs` inside the VM, and that must stay true.

- [ ] **Step 8: Clean the VM**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/refactor-cleanup.sh`
Expected: ends with `[refactor-cleanup.sh] lab VM is clean`.

- [ ] **Step 9: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` row to `In progress: SPIFFE pre-refactor snapshot recorded (plan Task 2 of 9)`.

```bash
git add demos/cert-hygiene/lab/refactor-check.sh demos/cert-hygiene/lab/refactor-cleanup.sh demos/cert-hygiene/runs/_refactor-check/before docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene record SPIFFE cluster scripts before the lib refactor"
git push
```
