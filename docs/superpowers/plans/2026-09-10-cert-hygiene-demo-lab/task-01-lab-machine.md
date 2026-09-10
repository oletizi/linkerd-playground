# Task 1: Lab machine and host wrappers

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** `just demo cert-hygiene lab-up` creates (or reuses) the OrbStack machine `cert-hygiene-lab`, installs the packages later tasks need, and proves the VM sees this working tree at the same path. Wrappers exist to run a repo script inside the VM, either in the foreground or detached with a log that ends in `[exit N]`.

**Files:**
- Create: `demos/cert-hygiene/config.example.env`
- Create: `demos/cert-hygiene/Justfile`
- Create: `demos/cert-hygiene/scripts/lab-up.sh`, `demos/cert-hygiene/scripts/lab-down.sh`, `demos/cert-hygiene/scripts/in-lab.sh`, `demos/cert-hygiene/scripts/wait-log.sh`
- Create: `demos/cert-hygiene/lab/detach.sh`, `demos/cert-hygiene/lab/shell.sh`
- Modify: `.gitignore` (add two lines)
- Modify: `README.md` (repo root; add a demo row)
- Modify: `docs/articles/cert-hygiene/README.md` (status table)

**Interfaces:**
- Consumes: `lib/common.sh` (`log`, `die`, `require_cmd`, `detect_arch`, `load_config`)
- Produces:
  - `bash scripts/in-lab.sh <demo-relative-script> [args...]`: runs the script in the VM with cwd `demos/cert-hygiene`, in the foreground, and propagates its exit status.
  - `bash scripts/in-lab.sh --detach <demo-relative-log> <demo-relative-script> [args...]`: starts the script detached in the VM and returns at once. The log's last line becomes `[exit N]`.
  - `bash scripts/wait-log.sh <demo-relative-log> [timeout-seconds]`: blocks until the log ends in `[exit N]`, prints its last 40 lines, and exits with N (or 124 on timeout).
  - Config variables: `LAB_VM`, `LAB_CPUS`, `LAB_MEM`, `LAB_DISK`, `LINKERD_EDGE_VERSION`, `GATEWAY_API_VERSION`, `LAB_NS`, `ANCHOR_LIFETIME`, `ISSUER_LIFETIME`, `LEAF_LIFETIME`, `CONTROL_ANCHOR_LIFETIME`, `CONTROL_ISSUER_LIFETIME`, `REPLACEMENT_ISSUER_LIFETIME`, `PROBE_INTERVAL_S`, `OBSERVE_INTERVAL_S`, `POST_EXPIRY_WINDOW_S`, `RECOVER_WINDOW_S`

- [ ] **Step 1: Write `demos/cert-hygiene/config.example.env`**

```bash
# Cert-hygiene lab settings. Copy to config.local.env (gitignored) to override.

# ---- Lab machine (OrbStack) ----
LAB_VM=cert-hygiene-lab
LAB_CPUS=4
LAB_MEM=6G
LAB_DISK=40G

# ---- Versions ----
LINKERD_EDGE_VERSION=edge-26.9.1     # CLI and control plane; recorded in every run
GATEWAY_API_VERSION=v1.5.1           # applied with kubectl apply --server-side

# ---- Lab namespace ----
LAB_NS=lab

# ---- Credential lifetimes (step / Linkerd duration syntax) ----
# Scenario #5: the issuer expires minutes into the run; the anchor cannot.
ANCHOR_LIFETIME=720h
ISSUER_LIFETIME=15m
# Workload leaf lifetime (linkerd install --identity-issuance-lifetime). Same in every scenario.
LEAF_LIFETIME=5m
# Negative control: nothing expires during the run.
CONTROL_ANCHOR_LIFETIME=87600h
CONTROL_ISSUER_LIFETIME=8760h
# The issuer #5 signs during recovery, from the same anchor.
REPLACEMENT_ISSUER_LIFETIME=8760h

# ---- Timing (seconds) ----
PROBE_INTERVAL_S=2
OBSERVE_INTERVAL_S=30
POST_EXPIRY_WINDOW_S=600
RECOVER_WINDOW_S=300
```

- [ ] **Step 2: Write `demos/cert-hygiene/scripts/lab-up.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Creates (or reuses) the OrbStack machine the cert-hygiene
# lab runs in, installs the packages the in-VM scripts need, and proves the machine
# sees this working tree at the same path -- the lab runs straight from it.
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb

orb status 2>/dev/null | grep -qx Running || { log "starting OrbStack"; orb start; }

if orb list 2>/dev/null | awk '{print $1}' | grep -qx "$LAB_VM"; then
  log "$LAB_VM exists; reusing it"
else
  # No -a: the machine gets the host's architecture. An amd64 guest on Apple Silicon
  # is emulated and unusably slow (see demos/spiffe-cross-boundary/README-ORBSTACK.md).
  log "creating $LAB_VM"
  orb create --cpus "$LAB_CPUS" --memory "$LAB_MEM" --disk "$LAB_DISK" ubuntu:24.04 "$LAB_VM"
fi

host_arch="$(detect_arch)"
case "$(orb -m "$LAB_VM" uname -m)" in
  aarch64|arm64) vm_arch=arm64 ;;
  x86_64|amd64)  vm_arch=amd64 ;;
  *) die "unrecognised architecture in $LAB_VM: $(orb -m "$LAB_VM" uname -m)" ;;
esac
[ "$vm_arch" = "$host_arch" ] || die "$LAB_VM is $vm_arch but this host is $host_arch.
  An emulated guest makes every timing in the lab meaningless. Delete it
  (just demo cert-hygiene lab-down) and run lab-up again."

log "installing packages in $LAB_VM"
orb -m "$LAB_VM" bash -lc 'sudo apt-get update -qq && sudo apt-get install -y -qq curl jq openssl gettext-base shellcheck'

# OrbStack shows Mac files at the same paths inside machines. Every in-VM script
# depends on that, so prove it instead of assuming it.
orb -m "$LAB_VM" test -f "$DEMO/config.example.env" || die "$LAB_VM cannot see $DEMO.
  The lab runs from the working tree through OrbStack's file sharing
  (https://docs.orbstack.dev/machines/file-sharing); without it nothing else works."

log "$LAB_VM ready ($vm_arch); it sees $DEMO"
```

- [ ] **Step 3: Write `demos/cert-hygiene/scripts/lab-down.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Deletes the lab machine and everything in it, including
# the lab's private keys under $HOME/cert-hygiene-certs (they never leave the VM).
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb

if orb list 2>/dev/null | awk '{print $1}' | grep -qx "$LAB_VM"; then
  log "deleting $LAB_VM"
  orb delete "$LAB_VM"
else
  log "$LAB_VM does not exist"
fi
```

- [ ] **Step 4: Write `demos/cert-hygiene/lab/detach.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. Starts a script detached from the calling session so it
# outlives the `orb` session that launched it. Usage: detach.sh <log> <script> [args...]
# The log's last line is "[exit N]" once the script has finished.
set -euo pipefail
log_file="${1:?usage: detach.sh <log> <script> [args...]}"
shift
[ $# -ge 1 ] || { echo "detach.sh: a script to run is required" >&2; exit 1; }
mkdir -p "$(dirname "$log_file")"
setsid nohup bash -c 'bash "$@"; echo "[exit $?]"' _ "$@" > "$log_file" 2>&1 < /dev/null &
echo "detached pid $! -> $log_file"
```

- [ ] **Step 5: Write `demos/cert-hygiene/lab/shell.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. A login shell in the demo directory; extra args go to bash
# (e.g. `-c 'kubectl get pods -A'`).
set -euo pipefail
exec bash -l "$@"
```

- [ ] **Step 6: Write `demos/cert-hygiene/scripts/in-lab.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Runs a script from demos/cert-hygiene inside the lab machine,
# with the demo directory as its working directory. Paths are the same on both sides.
#   in-lab.sh <script> [args...]                 foreground; exits with the script's status
#   in-lab.sh --detach <log> <script> [args...]  detached; the log ends with "[exit N]"
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb

detach_log=""
if [ "${1:-}" = "--detach" ]; then
  detach_log="${2:?--detach needs a log path}"
  shift 2
fi
[ $# -ge 1 ] || die "usage: in-lab.sh [--detach <log>] <script> [args...]"
[ -f "$DEMO/$1" ] || die "no such script: $DEMO/$1"

quoted=""
for a in "$@"; do quoted="$quoted $(printf '%q' "$a")"; done
if [ -n "$detach_log" ]; then
  quoted=" lab/detach.sh $(printf '%q' "$detach_log")$quoted"
fi
orb -m "$LAB_VM" bash -lc "cd $(printf '%q' "$DEMO") && bash$quoted"
```

- [ ] **Step 7: Write `demos/cert-hygiene/scripts/wait-log.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Waits for a detached lab log (see in-lab.sh --detach) to end
# with "[exit N]", prints its tail, and exits N. Exits 124 if the timeout passes first.
# Usage: wait-log.sh <demo-relative-log> [timeout-seconds, default 1800]
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

log_file="$DEMO/${1:?usage: wait-log.sh <demo-relative-log> [timeout-seconds]}"
timeout_s="${2:-1800}"
deadline=$(( $(date +%s) + timeout_s ))
while :; do
  if [ -f "$log_file" ] && tail -n 1 "$log_file" | grep -qE '^\[exit [0-9]+\]$'; then
    tail -n 40 "$log_file"
    rc="$(tail -n 1 "$log_file" | tr -dc '0-9')"
    exit "$rc"
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { err "timed out after ${timeout_s}s waiting for $log_file"; exit 124; }
  sleep 10
done
```

- [ ] **Step 8: Write `demos/cert-hygiene/Justfile`**

```just
set shell := ["bash", "-cu"]

# Create (or reuse) the OrbStack lab machine and install its packages
lab-up:
    bash scripts/lab-up.sh

# Delete the lab machine (and the lab keys inside it)
lab-down:
    bash scripts/lab-down.sh

# Shell inside the lab machine, in this directory
sh:
    bash scripts/in-lab.sh lab/shell.sh
```

- [ ] **Step 9: Update `.gitignore`**

Append this line to the repo-root `.gitignore`. The existing global `config.local.env` pattern already covers `demos/cert-hygiene/config.local.env`. The global `*.key`, `ca.crt`, and `issuer.crt` patterns don't collide with the evidence names used later (`trust-anchor.pem`, `issuer-*.pem`), so leave them as they are.

```
demos/cert-hygiene/.lab-logs/
```

- [ ] **Step 10: Syntax-check on the host**

Run: `for f in demos/cert-hygiene/scripts/*.sh demos/cert-hygiene/lab/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done`
Expected: no output.

- [ ] **Step 11: Bring the lab up**

Run: `just demo cert-hygiene lab-up`
Expected: the last line is `[lab-up.sh] cert-hygiene-lab ready (arm64); it sees /Users/.../demos/cert-hygiene` (the arch is the host's). A `die` on the file-sharing check is a hard stop. Report it; don't work around it.

- [ ] **Step 12: Prove both wrapper modes**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'pwd; uname -m; command -v envsubst shellcheck jq openssl'`
Expected: `pwd` prints the Mac path of `demos/cert-hygiene`, and four tool paths print.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh --detach .lab-logs/probe.log lab/shell.sh -c 'sleep 3; echo detached-ok' && bash scripts/wait-log.sh .lab-logs/probe.log 60`
Expected: the tail shows `detached-ok` then `[exit 0]`, and the command exits 0.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'exit 3'; echo "rc=$?"`
Expected: `rc=3`.

- [ ] **Step 13: Shellcheck inside the VM**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x scripts/*.sh lab/*.sh'`
Expected: no findings. Fix any finding before committing.

- [ ] **Step 14: Update the READMEs**

In the repo-root `README.md` demo table, add this row after `spiffe-cross-boundary`:

```markdown
| [cert-hygiene](demos/cert-hygiene/) | Reproducible Linkerd certificate-expiry failures (issuer, trust anchor, webhooks) in a disposable one-box k3s lab, recorded as raw evidence for the certificate-hygiene article. |
```

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` status row to `In progress: lab machine up (plan Task 1 of 9)`.

- [ ] **Step 15: Commit and push**

```bash
git add .gitignore README.md docs/articles/cert-hygiene/README.md demos/cert-hygiene
git commit -m "cert-hygiene add lab machine and host wrappers"
git push
```
