# Linkerd + SPIFFE Cross-Boundary Demo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible, infrastructure-agnostic playground (demo #1 in a multi-demo repo) that proves SPIFFE gives a shared trust domain and workload identity to a non-Kubernetes workload across a real two-machine boundary, using Linkerd mesh expansion.

**Architecture:** Two Linux VMs (Lima, one per physical machine): a **cluster** VM (k3s + Linkerd + viz) and an **edge** VM (SPIRE server+agent + standalone `linkerd2-proxy` + demo app). Linkerd is installed with a trust anchor we generate; that anchor is copied to the edge, where a local SPIRE server uses it as `UpstreamAuthority` so the edge's SVID chains to the same root as in-cluster identities. The playground provisions **no network** — it assumes IP reachability already exists and adds only a generic route + DNS shim.

**Tech Stack:** Lima, k3s, Linkerd (edge channel) + `linkerd viz`, SPIRE (server + agent), `step` CLI (cert generation), bash + YAML, `just` (task dispatch).

## Testing model (read first)

This is infrastructure, not a unit-tested codebase. Each task's "test" is a **verification command with expected output** (the honest analog of TDD here). A task is done when its verification command produces the expected result. Where a task produces a shell script or manifest, run `shellcheck` / `kubectl apply --dry-run=server` as the mechanical check before the behavioral verification.

## Global Constraints

Every task implicitly includes these (verbatim from the spec):

- **Two physical machines, never single-host.** Cluster VM and edge VM run on two separate boxes.
- **Disposable VMs everywhere**, one per box; one uniform Linux bootstrap path.
- **Arch-aware:** detect `uname -m`; pull `arm64`/`amd64` artifacts accordingly. `linkerd2-proxy` version MUST equal the installed Linkerd edge version (`LINKERD_EDGE_VERSION`).
- **No network provisioning.** The playground assumes IP reachability between the two machines already exists (bring-your-own). Config's only network inputs are `CLUSTER_NODE_ADDR` and `EDGE_ADDR`. It adds only a generic static route (to pod+service CIDRs) + `cluster.local`→CoreDNS. This is Linkerd's data-plane need, not SPIFFE's.
- **Trust domain:** `root.linkerd.cluster.local` (Linkerd default). Edge SPIFFE ID: `spiffe://root.linkerd.cluster.local/<name>`.
- **Attestation:** SPIRE `join_token` node attestor + `unix` workload attestor. SPIRE server + agent both run on the edge VM; Linkerd's root CA (`ca.crt` + `ca.key`) is copied there as SPIRE's `UpstreamAuthority`. (Caveat to document: the root key leaves the cluster — acceptable for a playground, flagged for stack-control.)
- **Repo shape:** top level is demo-neutral; everything SPIFFE-specific lives under `demos/spiffe-cross-boundary/`. No speculative shared framework — promote to `lib/` only on real reuse.
- **Layer is bash + YAML, not TypeScript.** Scripts idempotent + resumable + arch-detecting.
- **House rules:** no `#` inside heredocs/multi-line quoted args (write files instead); no `sed` write/execute; **no AI/Claude attribution in commit messages**; source files 300–500 lines max.
- **Pod/service CIDRs:** k3s defaults `10.42.0.0/16` (pods) / `10.43.0.0/16` (services), config-overridable.
- **Demo namespace:** `mixed-env`.

## One value to verify empirically during execution

`MeshTLSAuthentication.spec.identities` is documented with the dotted Linkerd identity form; the docs do not explicitly show a `spiffe://` URI there. This plan uses the edge's raw SPIFFE URI (`spiffe://root.linkerd.cluster.local/edge-echo`) as the most likely correct value. **Task 17 includes the exact command to read the client identity the server actually sees (`linkerd viz tap`) and use that string verbatim** if the URI form isn't matched. This is a pinned value + a verification method, not a placeholder.

---

## Phase 0 — Repo scaffold (demo-neutral)

### Task 1: Top-level demo-neutral scaffold

**Files:**
- Create: `README.md`
- Create: `Justfile`
- Create: `lib/common.sh`
- Create: `.gitignore`

**Interfaces:**
- Produces: `lib/common.sh` exposing `load_config`, `detect_arch` (echoes `amd64`|`arm64`), `log`, `require_cmd`. Sourced by every demo script.

- [ ] **Step 1: Write `.gitignore`**

```
config.local.env
*.key
issuer.crt
ca.crt
.lima/
```

- [ ] **Step 2: Write `lib/common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for all demos. Source this; do not execute.
set -euo pipefail

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(basename "${0}")" "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

# load_config <demo-dir>: sources config.example.env then config.local.env (override).
load_config() {
  local dir="$1"
  [ -f "$dir/config.example.env" ] || die "no config.example.env in $dir"
  # shellcheck disable=SC1091
  set -a; . "$dir/config.example.env"; [ -f "$dir/config.local.env" ] && . "$dir/config.local.env"; set +a
}
```

- [ ] **Step 3: Write top-level `Justfile` (dispatcher)**

```just
# Top-level dispatcher. This repo houses many demos; each lives under demos/<name>/.
set shell := ["bash", "-cu"]

# List available demos
demos:
    @ls -1 demos

# Run a demo target, e.g. `just demo spiffe-cross-boundary status`
demo NAME *ARGS:
    @just --justfile demos/{{NAME}}/Justfile --working-directory demos/{{NAME}} {{ARGS}}
```

- [ ] **Step 4: Write demo-neutral `README.md`**

```markdown
# linkerd-playground

A collection of hands-on demos exploring Linkerd, service-mesh identity, and
cross-infrastructure trust.

## Demos

| Demo | What it shows |
|------|---------------|
| [spiffe-cross-boundary](demos/spiffe-cross-boundary/) | SPIFFE giving a shared trust domain + workload identity to a non-Kubernetes workload across a real two-machine boundary, via Linkerd mesh expansion. |

## Running a demo

```bash
just demos                              # list demos
just demo spiffe-cross-boundary status  # run a demo target
```

Each demo is self-contained under `demos/<name>/` with its own README.
```

- [ ] **Step 5: Verify**

Run: `bash -n lib/common.sh && shellcheck lib/common.sh && just demos`
Expected: no shellcheck errors; `just demos` prints `spiffe-cross-boundary` once Task 2 lands (before that, prints nothing / creates dir). If `shellcheck`/`just` absent, `bash -n` must still pass.

- [ ] **Step 6: Commit**

```bash
git add README.md Justfile lib/common.sh .gitignore
git commit -m "scaffold: demo-neutral repo top level + shared lib"
```

### Task 2: Demo skeleton + config + dispatcher targets

**Files:**
- Create: `demos/spiffe-cross-boundary/config.example.env`
- Create: `demos/spiffe-cross-boundary/Justfile`
- Create: `demos/spiffe-cross-boundary/README.md` (stub; filled in Task 19)
- Create: `demos/spiffe-cross-boundary/scripts/status.sh`

**Interfaces:**
- Produces: config variables consumed by all later scripts — `CLUSTER_VM`, `EDGE_VM`, `CLUSTER_CPUS`, `CLUSTER_MEM`, `EDGE_CPUS`, `EDGE_MEM`, `CLUSTER_NODE_ADDR`, `EDGE_ADDR`, `POD_CIDR`, `SVC_CIDR`, `COREDNS_ADDR`, `LINKERD_EDGE_VERSION`, `DEMO_NS`, `EDGE_SPIFFE_ID`, `EDGE_SERVER_NAME`, `EDGE_WORKLOAD_NAME`.

- [ ] **Step 1: Write `config.example.env`**

```bash
# ---- Compute (Lima VM names + sizing) ----
CLUSTER_VM=linkerd-cluster
EDGE_VM=linkerd-edge
CLUSTER_CPUS=4
CLUSTER_MEM=8GiB
EDGE_CPUS=2
EDGE_MEM=4GiB

# ---- Reachability (bring-your-own; the playground does NOT set these up) ----
# How the edge reaches the cluster node (any address that already works: LAN, tailnet, VPN...).
CLUSTER_NODE_ADDR=CHANGE_ME          # e.g. 192.168.1.50 or 100.96.71.14
# How the cluster reaches the edge workload (the ExternalWorkload IP).
EDGE_ADDR=CHANGE_ME                  # e.g. 192.168.1.51 or 100.65.31.54

# ---- Cluster networking (k3s defaults) ----
POD_CIDR=10.42.0.0/16
SVC_CIDR=10.43.0.0/16
COREDNS_ADDR=10.43.0.10              # kube-dns ClusterIP (k3s default)

# ---- Versions / identity ----
LINKERD_EDGE_VERSION=edge-26.7.2     # pin CLI + proxy to the SAME value
DEMO_NS=mixed-env
EDGE_WORKLOAD_NAME=edge-echo
EDGE_SPIFFE_ID=spiffe://root.linkerd.cluster.local/edge-echo
EDGE_SERVER_NAME=edge-echo.cluster.local
```

- [ ] **Step 2: Write `scripts/status.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"
load_config "$HERE"
log "demo: spiffe-cross-boundary"
log "cluster VM: ${CLUSTER_VM} (${CLUSTER_CPUS}cpu/${CLUSTER_MEM}) @ ${CLUSTER_NODE_ADDR}"
log "edge VM:    ${EDGE_VM} (${EDGE_CPUS}cpu/${EDGE_MEM}) @ ${EDGE_ADDR}"
log "linkerd:    ${LINKERD_EDGE_VERSION}   ns: ${DEMO_NS}"
command -v limactl >/dev/null 2>&1 && limactl list || log "limactl not installed here (run on a box that provisions a VM)"
```

- [ ] **Step 3: Write demo `Justfile`**

```just
set shell := ["bash", "-cu"]

# Show demo configuration + local VM state
status:
    bash scripts/status.sh

# --- provisioning (Task 4) ---
cluster-up:
    bash scripts/cluster-up.sh
edge-up:
    bash scripts/edge-up.sh
down:
    bash scripts/down.sh

# --- beats (Phase 5) ---
beat1:
    bash scripts/beat1-verify.sh
beat2:
    bash scripts/beat2-authz.sh
beat3:
    bash scripts/beat3-to-edge.sh
```

- [ ] **Step 4: Write `README.md` stub**

```markdown
# spiffe-cross-boundary

SPIFFE + Linkerd mesh expansion across two physical machines. Full walkthrough
lands in Task 19. See the design spec: `docs/superpowers/specs/2026-07-29-linkerd-spiffe-playground-design.md`.
```

- [ ] **Step 5: Verify**

Run: `shellcheck demos/spiffe-cross-boundary/scripts/status.sh && just demo spiffe-cross-boundary status`
Expected: prints the config summary (with `CHANGE_ME` addresses until a `config.local.env` overrides them).

- [ ] **Step 6: Commit**

```bash
git add demos/spiffe-cross-boundary
git commit -m "spiffe-cross-boundary: demo skeleton, config, status target"
```

---

## Phase 1 — Provisioning (Lima VMs)

### Task 3: Lima VM definitions + base provisioning

**Files:**
- Create: `demos/spiffe-cross-boundary/provisioners/lima/cluster.yaml`
- Create: `demos/spiffe-cross-boundary/provisioners/lima/edge.yaml`

**Notes:** Lima auto-selects the host architecture image, so these work on arm64 and amd64 hosts unchanged. Base provisioning installs the packages both roles need. `mountType`/networking left at Lima defaults; the VM reaches the LAN/tailnet via the host.

- [ ] **Step 1: Write `provisioners/lima/cluster.yaml`**

```yaml
# Cluster VM: k3s + Linkerd + viz. Sizing overridden at start time via limactl --set.
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
cpus: 4
memory: "8GiB"
disk: "40GiB"
provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eux
      apt-get update
      apt-get install -y curl iptables jq
```

- [ ] **Step 2: Write `provisioners/lima/edge.yaml`**

```yaml
# Edge VM: SPIRE + standalone linkerd2-proxy + demo app.
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
cpus: 2
memory: "4GiB"
disk: "20GiB"
provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eux
      apt-get update
      apt-get install -y curl iptables jq docker.io
```

- [ ] **Step 3: Verify (mechanical)**

Run: `limactl validate demos/spiffe-cross-boundary/provisioners/lima/cluster.yaml demos/spiffe-cross-boundary/provisioners/lima/edge.yaml`
Expected: `OK` for both (validates schema without starting VMs).

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/provisioners
git commit -m "spiffe-cross-boundary: Lima VM definitions (cluster + edge)"
```

### Task 4: Role-scoped up/down/status VM scripts

**Files:**
- Create: `demos/spiffe-cross-boundary/scripts/lib-vm.sh`
- Create: `demos/spiffe-cross-boundary/scripts/cluster-up.sh`
- Create: `demos/spiffe-cross-boundary/scripts/edge-up.sh`
- Create: `demos/spiffe-cross-boundary/scripts/down.sh`

**Interfaces:**
- Consumes: `CLUSTER_VM`, `EDGE_VM`, sizing vars, Lima YAMLs from Task 3.
- Produces: `vm_start <name> <yaml> <cpus> <mem>` and `vm_shell <name> -- <cmd>` helpers (used by later phases to run commands inside a VM idempotently).

Run `cluster-up.sh` on the machine that hosts the cluster VM; `edge-up.sh` on the machine that hosts the edge VM. (Each is a separate physical box per the Global Constraints.)

- [ ] **Step 1: Write `scripts/lib-vm.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"
load_config "$HERE"
require_cmd limactl

vm_running() { limactl list --format '{{.Name}}:{{.Status}}' 2>/dev/null | grep -q "^$1:Running$"; }

vm_start() { # name yaml cpus mem
  local name="$1" yaml="$2" cpus="$3" mem="$4"
  if vm_running "$name"; then log "$name already running"; return 0; fi
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$name"; then
    log "starting existing $name"; limactl start "$name"
  else
    log "creating $name"; limactl start --name="$name" --cpus="$cpus" --memory="${mem%GiB}" --tty=false "$yaml"
  fi
}

vm_shell() { local name="$1"; shift; limactl shell "$name" -- "$@"; }
```

- [ ] **Step 2: Write `scripts/cluster-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib-vm.sh"
vm_start "$CLUSTER_VM" "$HERE/../provisioners/lima/cluster.yaml" "$CLUSTER_CPUS" "$CLUSTER_MEM"
vm_shell "$CLUSTER_VM" -- bash -lc 'uname -m && echo cluster-vm-ready'
```

- [ ] **Step 3: Write `scripts/edge-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib-vm.sh"
vm_start "$EDGE_VM" "$HERE/../provisioners/lima/edge.yaml" "$EDGE_CPUS" "$EDGE_MEM"
vm_shell "$EDGE_VM" -- bash -lc 'uname -m && echo edge-vm-ready'
```

- [ ] **Step 4: Write `scripts/down.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib-vm.sh"
for vm in "$CLUSTER_VM" "$EDGE_VM"; do
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
    log "stopping+deleting $vm"; limactl stop -f "$vm" 2>/dev/null || true; limactl delete "$vm" 2>/dev/null || true
  fi
done
```

- [ ] **Step 5: Verify (behavioral — requires a box with Lima)**

Run (on the cluster box): `just demo spiffe-cross-boundary cluster-up`
Expected: ends with the VM arch and `cluster-vm-ready`. Re-run → `already running` (idempotent).

- [ ] **Step 6: Commit**

```bash
git add demos/spiffe-cross-boundary/scripts
git commit -m "spiffe-cross-boundary: role-scoped VM up/down scripts (idempotent)"
```

---

## Phase 2 — Cluster: trust anchor, Linkerd, viz, demo service

### Task 5: Generate the Linkerd trust anchor + issuer

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/gen-certs.sh`

**Interfaces:**
- Produces: `ca.crt`, `ca.key` (root/trust anchor), `issuer.crt`, `issuer.key` inside the cluster VM at `~/linkerd-certs/`. `ca.crt`+`ca.key` are later copied to the edge for SPIRE. (Gitignored — never committed.)

- [ ] **Step 1: Write `cluster/gen-certs.sh` (runs inside the cluster VM)**

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="${HOME}/linkerd-certs"
mkdir -p "$DIR"; cd "$DIR"
if [ ! -f ca.crt ]; then
  command -v step >/dev/null 2>&1 || { curl -sSL https://dl.smallstep.com/cli/docs-cli-install/latest/step-cli_amd64.deb -o /tmp/step.deb 2>/dev/null || true; }
  command -v step >/dev/null 2>&1 || { arch="$(dpkg --print-architecture)"; curl -sSLf "https://dl.smallstep.com/gh-release/cli/gh-release-header/latest/step-cli_$(curl -sSf https://api.github.com/repos/smallstep/cli/releases/latest | jq -r .tag_name | tr -d v)_${arch}.deb" -o /tmp/step.deb; sudo dpkg -i /tmp/step.deb; }
  step certificate create root.linkerd.cluster.local ca.crt ca.key \
    --profile root-ca --no-password --insecure --not-after=87600h
  step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
    --profile intermediate-ca --not-after 8760h --no-password --insecure \
    --ca ca.crt --ca-key ca.key
fi
step certificate inspect ca.crt --short
```

> If the `step` install URL drifts, the fallback is `sudo apt-get install -y step-cli` after adding smallstep's apt repo, or download the matching `.deb` from https://github.com/smallstep/cli/releases. The three `step` commands themselves are exact and stable.

- [ ] **Step 2: Verify**

Run (in cluster VM): `bash cluster/gen-certs.sh`
Expected: prints the root cert summary; `ls ~/linkerd-certs` shows `ca.crt ca.key issuer.crt issuer.key`. Re-run → no regeneration (idempotent), prints summary.

- [ ] **Step 3: Commit** (script only — certs are gitignored)

```bash
git add demos/spiffe-cross-boundary/cluster/gen-certs.sh
git commit -m "spiffe-cross-boundary: trust anchor + issuer generation (step)"
```

### Task 6: Install k3s on the cluster VM

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/install-k3s.sh`

- [ ] **Step 1: Write `cluster/install-k3s.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Trim k3s to save RAM: no Traefik, no servicelb. World-readable kubeconfig.
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
fi
mkdir -p "${HOME}/.kube"
sudo cat /etc/rancher/k3s/k3s.yaml > "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
kubectl get nodes -o wide
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
```

- [ ] **Step 2: Verify**

Run (in cluster VM): `bash cluster/install-k3s.sh`
Expected: one node `Ready`; the printed `kube-dns` ClusterIP equals `COREDNS_ADDR` (`10.43.0.10`). If it differs, update `COREDNS_ADDR` in `config.local.env`.

- [ ] **Step 3: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/install-k3s.sh
git commit -m "spiffe-cross-boundary: k3s install (traefik/servicelb disabled)"
```

### Task 7: Install Linkerd (custom anchor) + viz

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/install-linkerd.sh`

**Interfaces:**
- Consumes: `~/linkerd-certs/{ca.crt,issuer.crt,issuer.key}` from Task 5; `LINKERD_EDGE_VERSION`.
- Produces: a running Linkerd control plane rooted at our trust anchor; `linkerd viz` for identity inspection.

- [ ] **Step 1: Write `cluster/install-linkerd.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
CERTS="${HOME}/linkerd-certs"

if ! command -v linkerd >/dev/null 2>&1; then
  curl -sL https://run.linkerd.io/install-edge | LINKERD2_VERSION="${LINKERD_EDGE_VERSION}" sh
fi
export PATH="${HOME}/.linkerd2/bin:${PATH}"

linkerd install --crds | kubectl apply -f -
linkerd install \
  --identity-trust-anchors-file "${CERTS}/ca.crt" \
  --identity-issuer-certificate-file "${CERTS}/issuer.crt" \
  --identity-issuer-key-file "${CERTS}/issuer.key" \
  | kubectl apply -f -
linkerd check
linkerd viz install | kubectl apply -f -
linkerd check
```

- [ ] **Step 2: Verify**

Run (in cluster VM): `bash cluster/install-linkerd.sh`
Expected: both `linkerd check` runs end with all `√` (no `×`). `linkerd version --proxy` shows control-plane version == `LINKERD_EDGE_VERSION`.

- [ ] **Step 3: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/install-linkerd.sh
git commit -m "spiffe-cross-boundary: Linkerd install with custom trust anchor + viz"
```

### Task 8: Deploy the in-cluster echo service (meshed)

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/echo.yaml`
- Create: `demos/spiffe-cross-boundary/cluster/apply-echo.sh`

**Interfaces:**
- Produces: `Deployment/echo` + `Service/echo` in namespace `mixed-env`, meshed; a meshed `client` pod for calling. Used by Beats 1–2.

- [ ] **Step 1: Write `cluster/echo.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mixed-env
  annotations:
    linkerd.io/inject: enabled
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: mixed-env
  labels: { app: echo }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo } }
  template:
    metadata:
      labels: { app: echo }
    spec:
      containers:
        - name: echo
          image: ealen/echo-server:latest
          ports: [{ containerPort: 80, name: http }]
          env: [{ name: PORT, value: "80" }]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: mixed-env
spec:
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 80, name: http }]
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: mixed-env
  labels: { app: client }
spec:
  containers:
    - name: client
      image: curlimages/curl:latest
      command: ["sleep", "infinity"]
```

- [ ] **Step 2: Write `cluster/apply-echo.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
kubectl apply -f "$HERE/echo.yaml"
kubectl -n mixed-env rollout status deploy/echo --timeout=120s
kubectl -n mixed-env wait --for=condition=Ready pod/client --timeout=120s
```

- [ ] **Step 3: Verify**

Run (in cluster VM): `bash cluster/apply-echo.sh` then
`kubectl -n mixed-env exec client -c client -- curl -s http://echo.mixed-env.svc.cluster.local/ | jq -r .host.hostname`
Expected: prints the echo pod's hostname (in-cluster meshed call works). `linkerd -n mixed-env viz stat deploy` shows `echo` meshed (MESHED 1/1).

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/echo.yaml demos/spiffe-cross-boundary/cluster/apply-echo.sh
git commit -m "spiffe-cross-boundary: in-cluster meshed echo service + client"
```

---

## Phase 3 — Network shim (generic, provider-neutral)

### Task 9: Edge → cluster route + DNS shim

**Files:**
- Create: `demos/spiffe-cross-boundary/net/shim.sh`

**Interfaces:**
- Consumes: `CLUSTER_NODE_ADDR`, `POD_CIDR`, `SVC_CIDR`, `COREDNS_ADDR`.
- Produces: on the edge VM, a route to the cluster pod+service CIDRs via `CLUSTER_NODE_ADDR`, and `cluster.local` resolution via CoreDNS. This is the ONLY networking the playground performs; it assumes `CLUSTER_NODE_ADDR` is already reachable.

- [ ] **Step 1: Write `net/shim.sh` (runs inside the edge VM)**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
[ "$CLUSTER_NODE_ADDR" != "CHANGE_ME" ] || die "set CLUSTER_NODE_ADDR in config.local.env"

ping -c1 -W2 "$CLUSTER_NODE_ADDR" >/dev/null || die "cluster node $CLUSTER_NODE_ADDR not reachable — fix your base network first"

for cidr in "$POD_CIDR" "$SVC_CIDR"; do
  ip route replace "$cidr" via "$CLUSTER_NODE_ADDR"
done

# cluster.local -> CoreDNS via a systemd-resolved drop-in (Ubuntu 24.04 uses resolved)
sudo mkdir -p /etc/systemd/resolved.conf.d
printf 'DNS=%s\nDomains=~cluster.local\n' "$COREDNS_ADDR" | sudo tee /etc/systemd/resolved.conf.d/cluster.conf >/dev/null
# resolved needs [Resolve] header; write the full file deterministically:
{ echo '[Resolve]'; echo "DNS=${COREDNS_ADDR}"; echo 'Domains=~cluster.local'; } | sudo tee /etc/systemd/resolved.conf.d/cluster.conf >/dev/null
sudo systemctl restart systemd-resolved
```

- [ ] **Step 2: Verify**

Run (in edge VM): `bash net/shim.sh` then
`getent hosts echo.mixed-env.svc.cluster.local && curl -s http://$SVC_CIDR-derived-echo-clusterip/` — concretely:
`ECHO_IP=$(getent hosts echo.mixed-env.svc.cluster.local | awk '{print $1}'); echo "$ECHO_IP"; curl -s "http://echo.mixed-env.svc.cluster.local/" -m 5 | head -c1`
Expected: DNS resolves to a `10.43.x` ClusterIP; the raw `curl` may hang/refuse (traffic isn't meshed yet from the edge) — that is fine. **The pass condition is: DNS resolves AND `ping -c1 <that ClusterIP>`/route exists.** Confirm route: `ip route get 10.42.0.1` shows `via $CLUSTER_NODE_ADDR`.

- [ ] **Step 3: Commit**

```bash
git add demos/spiffe-cross-boundary/net/shim.sh
git commit -m "spiffe-cross-boundary: generic edge route + cluster DNS shim"
```

---

## Phase 4 — Edge: SPIRE + proxy + ExternalWorkload

### Task 10: Copy trust anchor to edge; install + start SPIRE (server + agent)

**Files:**
- Create: `demos/spiffe-cross-boundary/edge/spire/server.cfg`
- Create: `demos/spiffe-cross-boundary/edge/spire/agent.cfg`
- Create: `demos/spiffe-cross-boundary/edge/install-spire.sh`

**Interfaces:**
- Consumes: `ca.crt`+`ca.key` from the cluster (copied to `/opt/spire/certs/`).
- Produces: a running SPIRE server (`127.0.0.1:8081`) rooted at Linkerd's anchor, and a running SPIRE agent exposing the Workload API at `/tmp/spire-agent/public/api.sock`.

> **Manual copy step (documented in Task 19):** from the cluster VM, copy `~/linkerd-certs/ca.crt` and `~/linkerd-certs/ca.key` to the edge VM at `/opt/spire/certs/`. The playground does not automate cross-box file copy (bring-your-own connectivity); the walkthrough shows `limactl copy` / `scp` over whatever reachability exists.

- [ ] **Step 1: Write `edge/spire/server.cfg`** (verbatim from the Linkerd runbook, paths under `/opt/spire`)

```hcl
server {
    bind_address = "127.0.0.1"
    bind_port = "8081"
    trust_domain = "root.linkerd.cluster.local"
    data_dir = "/opt/spire/data/server"
    log_level = "DEBUG"
    ca_ttl = "168h"
    default_x509_svid_ttl = "48h"
}
plugins {
    DataStore "sql" {
        plugin_data { database_type = "sqlite3"
            connection_string = "/opt/spire/data/server/datastore.sqlite3" }
    }
    KeyManager "disk" { plugin_data { keys_path = "/opt/spire/data/server/keys.json" } }
    NodeAttestor "join_token" { plugin_data {} }
    UpstreamAuthority "disk" {
        plugin_data {
            cert_file_path = "/opt/spire/certs/ca.crt"
            key_file_path = "/opt/spire/certs/ca.key"
        }
    }
}
```

- [ ] **Step 2: Write `edge/spire/agent.cfg`**

```hcl
agent {
    data_dir = "/opt/spire/data/agent"
    log_level = "DEBUG"
    trust_domain = "root.linkerd.cluster.local"
    server_address = "localhost"
    server_port = 8081
    insecure_bootstrap = true
}
plugins {
    KeyManager "disk" { plugin_data { directory = "/opt/spire/data/agent" } }
    NodeAttestor "join_token" { plugin_data {} }
    WorkloadAttestor "unix" { plugin_data {} }
}
```

- [ ] **Step 3: Write `edge/install-spire.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../../.." && pwd)/lib/common.sh"
ARCH="$(detect_arch)"
[ -f /opt/spire/certs/ca.crt ] || die "copy ca.crt+ca.key to /opt/spire/certs first (see README)"

if [ ! -x /opt/spire/bin/spire-server ]; then
  VER="$(curl -sSf https://api.github.com/repos/spiffe/spire/releases/latest | jq -r .tag_name | tr -d v)"
  curl -sSLf "https://github.com/spiffe/spire/releases/download/v${VER}/spire-${VER}-linux-${ARCH}-musl.tar.gz" -o /tmp/spire.tgz
  sudo mkdir -p /opt/spire/bin /opt/spire/data/server /opt/spire/data/agent
  tar -xzf /tmp/spire.tgz -C /tmp
  sudo cp "/tmp/spire-${VER}"/bin/spire-server "/tmp/spire-${VER}"/bin/spire-agent /opt/spire/bin/
fi
sudo cp "$HERE/spire/server.cfg" "$HERE/spire/agent.cfg" /opt/spire/

sudo pkill -f 'spire-server run' 2>/dev/null || true
sudo /opt/spire/bin/spire-server run -config /opt/spire/server.cfg >/tmp/spire-server.log 2>&1 &
sleep 3
TOKEN="$(sudo /opt/spire/bin/spire-server token generate -spiffeID spiffe://root.linkerd.cluster.local/agent | awk '{print $2}')"
sudo pkill -f 'spire-agent run' 2>/dev/null || true
sudo /opt/spire/bin/spire-agent run -config /opt/spire/agent.cfg -joinToken "$TOKEN" >/tmp/spire-agent.log 2>&1 &
sleep 3
sudo /opt/spire/bin/spire-server healthcheck
sudo /opt/spire/bin/spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
```

- [ ] **Step 4: Verify**

Run (in edge VM, after copying certs): `bash edge/install-spire.sh`
Expected: both `healthcheck` lines report `Server is healthy` / `Agent is healthy`.

- [ ] **Step 5: Commit**

```bash
git add demos/spiffe-cross-boundary/edge/spire demos/spiffe-cross-boundary/edge/install-spire.sh
git commit -m "spiffe-cross-boundary: SPIRE server+agent on edge, rooted at Linkerd anchor"
```

### Task 11: Register the edge workload with SPIRE

**Files:**
- Create: `demos/spiffe-cross-boundary/edge/register-workload.sh`

**Interfaces:**
- Consumes: `EDGE_SPIFFE_ID`; the uid the proxy will run as (root).
- Produces: a SPIRE registration entry so the `unix` attestor issues `EDGE_SPIFFE_ID` to the proxy process.

- [ ] **Step 1: Write `edge/register-workload.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
UID_PROXY="$(id -u root)"
if ! sudo /opt/spire/bin/spire-server entry show -spiffeID "$EDGE_SPIFFE_ID" | grep -q "$EDGE_SPIFFE_ID"; then
  sudo /opt/spire/bin/spire-server entry create \
    -parentID spiffe://root.linkerd.cluster.local/agent \
    -spiffeID "$EDGE_SPIFFE_ID" \
    -selector "unix:uid:${UID_PROXY}"
fi
sudo /opt/spire/bin/spire-server entry show -spiffeID "$EDGE_SPIFFE_ID"
```

- [ ] **Step 2: Verify**

Run (in edge VM): `bash edge/register-workload.sh`
Expected: output includes `SPIFFE ID : spiffe://root.linkerd.cluster.local/edge-echo` and `Selector : unix:uid:0`. Re-run → no duplicate (idempotent).

- [ ] **Step 3: Commit**

```bash
git add demos/spiffe-cross-boundary/edge/register-workload.sh
git commit -m "spiffe-cross-boundary: SPIRE registration entry for edge workload"
```

### Task 12: Extract the proxy binary + iptables redirection

**Files:**
- Create: `demos/spiffe-cross-boundary/edge/extract-proxy.sh`
- Create: `demos/spiffe-cross-boundary/edge/iptables.sh`

**Interfaces:**
- Consumes: `LINKERD_EDGE_VERSION` (MUST match the control plane from Task 7).
- Produces: `/opt/linkerd-proxy/linkerd-proxy` binary; nat rules redirecting inbound→4143 / outbound→4140.

- [ ] **Step 1: Write `edge/extract-proxy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
if [ ! -x /opt/linkerd-proxy/linkerd-proxy ]; then
  sudo mkdir -p /opt/linkerd-proxy
  id=$(sudo docker create "cr.l5d.io/linkerd/proxy:${LINKERD_EDGE_VERSION}")
  sudo docker cp "$id:/usr/lib/linkerd/linkerd2-proxy" /opt/linkerd-proxy/linkerd-proxy
  sudo docker rm -v "$id"
fi
/opt/linkerd-proxy/linkerd-proxy --version || true
```

- [ ] **Step 2: Write `edge/iptables.sh`** (verbatim from the Linkerd runbook)

```bash
#!/usr/bin/env bash
set -euo pipefail
PROXY_INBOUND_PORT=4143
PROXY_OUTBOUND_PORT=4140
PROXY_USER_UID=$(id -u root)
INBOUND_PORTS_TO_IGNORE="4190,4191,4567,4568"
OUTBOUND_PORTS_TO_IGNORE="4567,4568"

if sudo iptables -t nat -n -L PROXY_INIT_REDIRECT >/dev/null 2>&1; then echo "iptables already configured"; exit 0; fi

sudo iptables -t nat -N PROXY_INIT_REDIRECT
sudo iptables -t nat -A PROXY_INIT_REDIRECT -p tcp --match multiport --dports $INBOUND_PORTS_TO_IGNORE -j RETURN
sudo iptables -t nat -A PROXY_INIT_REDIRECT -p tcp -j REDIRECT --to-port $PROXY_INBOUND_PORT
sudo iptables -t nat -A PREROUTING -j PROXY_INIT_REDIRECT

sudo iptables -t nat -N PROXY_INIT_OUTPUT
sudo iptables -t nat -A PROXY_INIT_OUTPUT -m owner --uid-owner $PROXY_USER_UID -j RETURN
sudo iptables -t nat -A PROXY_INIT_OUTPUT -o lo -j RETURN
sudo iptables -t nat -A PROXY_INIT_OUTPUT -p tcp --match multiport --dports $OUTBOUND_PORTS_TO_IGNORE -j RETURN
sudo iptables -t nat -A PROXY_INIT_OUTPUT -p tcp -j REDIRECT --to-port $PROXY_OUTBOUND_PORT
sudo iptables -t nat -A OUTPUT -j PROXY_INIT_OUTPUT
sudo iptables-save -t nat
```

- [ ] **Step 3: Verify**

Run (in edge VM): `bash edge/extract-proxy.sh && bash edge/iptables.sh`
Expected: proxy `--version` prints `LINKERD_EDGE_VERSION`; `sudo iptables -t nat -L PROXY_INIT_REDIRECT` lists the REDIRECT rules. Re-run iptables → `already configured`.

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/edge/extract-proxy.sh demos/spiffe-cross-boundary/edge/iptables.sh
git commit -m "spiffe-cross-boundary: extract linkerd2-proxy + iptables redirection"
```

### Task 13: Launch the proxy (identity from SPIRE) + edge app

**Files:**
- Create: `demos/spiffe-cross-boundary/edge/run-proxy.sh`
- Create: `demos/spiffe-cross-boundary/edge/run-app.sh`

**Interfaces:**
- Consumes: SPIRE Workload API socket, `ca.crt`, `EDGE_SPIFFE_ID`, `EDGE_SERVER_NAME`, `EDGE_WORKLOAD_NAME`, `DEMO_NS`.
- Produces: a running `linkerd-proxy` that has obtained its SVID; a local echo app on port 80 (the edge-hosted workload).

- [ ] **Step 1: Write `edge/run-app.sh`** (the edge-hosted echo, so in-cluster clients have something to call)

```bash
#!/usr/bin/env bash
set -euo pipefail
sudo docker rm -f edge-echo 2>/dev/null || true
sudo docker run -d --name edge-echo --network host -e PORT=80 ealen/echo-server:latest
```

- [ ] **Step 2: Write `edge/run-proxy.sh`** (env vars verbatim from the runbook, parameterized by config)

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"

export LINKERD2_PROXY_IDENTITY_SERVER_ID="${EDGE_SPIFFE_ID}"
export LINKERD2_PROXY_IDENTITY_SERVER_NAME="${EDGE_SERVER_NAME}"
export LINKERD2_PROXY_POLICY_WORKLOAD="{\"ns\":\"${DEMO_NS}\", \"external_workload\":\"${EDGE_WORKLOAD_NAME}\"}"
export LINKERD2_PROXY_DESTINATION_CONTEXT="{\"ns\":\"${DEMO_NS}\", \"nodeName\":\"${EDGE_VM}\", \"external_workload\":\"${EDGE_WORKLOAD_NAME}\"}"
export LINKERD2_PROXY_DESTINATION_SVC_ADDR="linkerd-dst-headless.linkerd.svc.cluster.local.:8086"
export LINKERD2_PROXY_DESTINATION_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
export LINKERD2_PROXY_POLICY_SVC_NAME="linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local"
export LINKERD2_PROXY_POLICY_SVC_ADDR="linkerd-policy.linkerd.svc.cluster.local.:8090"
export LINKERD2_PROXY_IDENTITY_SPIRE_SOCKET="unix:///tmp/spire-agent/public/api.sock"
LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS="$(cat /opt/spire/certs/ca.crt)"; export LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS

sudo pkill -f '/opt/linkerd-proxy/linkerd-proxy' 2>/dev/null || true
sudo -E /opt/linkerd-proxy/linkerd-proxy >/tmp/linkerd-proxy.log 2>&1 &
sleep 5
grep -Eq 'obtained.*identity|SVID|certified' /tmp/linkerd-proxy.log && echo "proxy has identity" || { tail -n 40 /tmp/linkerd-proxy.log; exit 1; }
```

- [ ] **Step 3: Verify**

Run (in edge VM): `bash edge/run-app.sh && bash edge/run-proxy.sh`
Expected: `proxy has identity`. `/tmp/linkerd-proxy.log` shows the proxy fetched its SVID from the SPIRE socket for `EDGE_SPIFFE_ID`. (If the grep pattern misses, inspect the log for the identity line and adjust the pattern — the pass condition is the log showing an issued SVID for `spiffe://root.linkerd.cluster.local/edge-echo`.)

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/edge/run-proxy.sh demos/spiffe-cross-boundary/edge/run-app.sh
git commit -m "spiffe-cross-boundary: launch edge proxy (SPIRE identity) + edge echo app"
```

### Task 14: Register the ExternalWorkload + fronting Service

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/externalworkload.yaml`
- Create: `demos/spiffe-cross-boundary/cluster/apply-externalworkload.sh`

**Interfaces:**
- Consumes: `EDGE_ADDR`, `EDGE_SPIFFE_ID`, `EDGE_SERVER_NAME`, `EDGE_WORKLOAD_NAME`.
- Produces: an `ExternalWorkload` the cluster treats as a mesh endpoint, plus a `Service` selecting it so in-cluster clients can call the edge (Beat 1 foundation).

- [ ] **Step 1: Write `cluster/externalworkload.yaml`** (fields verbatim from the runbook; `$EDGE_ADDR` substituted by the apply script via envsubst)

```yaml
apiVersion: workload.linkerd.io/v1beta1
kind: ExternalWorkload
metadata:
  name: edge-echo
  namespace: mixed-env
  labels:
    location: vm
    app: edge-echo
    workload_name: edge-echo
spec:
  meshTLS:
    identity: "spiffe://root.linkerd.cluster.local/edge-echo"
    serverName: "edge-echo.cluster.local"
  workloadIPs:
  - ip: "__EDGE_ADDR__"
  ports:
  - port: 80
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: edge-echo
  namespace: mixed-env
spec:
  ports:
  - port: 80
    targetPort: 80
    name: http
  selector:
    app: edge-echo
```

- [ ] **Step 2: Write `cluster/apply-externalworkload.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$(cd "$DEMO/../.." && pwd)/lib/common.sh"; load_config "$DEMO"
[ "$EDGE_ADDR" != "CHANGE_ME" ] || die "set EDGE_ADDR in config.local.env"
sed_free_render() { while IFS= read -r line; do echo "${line/__EDGE_ADDR__/$EDGE_ADDR}"; done < "$HERE/externalworkload.yaml"; }
sed_free_render | kubectl apply -f -
kubectl -n mixed-env get externalworkload edge-echo -o wide
kubectl -n mixed-env get endpointslices -l kubernetes.io/service-name=edge-echo -o wide
```

> Substitution uses bash parameter expansion (no `sed`, per house rules).

- [ ] **Step 3: Verify**

Run (in cluster VM): `bash cluster/apply-externalworkload.sh`
Expected: the `ExternalWorkload` exists; an EndpointSlice for `edge-echo` lists `EDGE_ADDR:80`.

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/externalworkload.yaml demos/spiffe-cross-boundary/cluster/apply-externalworkload.sh
git commit -m "spiffe-cross-boundary: ExternalWorkload + fronting Service for edge"
```

---

## Phase 5 — The beats (the actual demonstration)

### Task 15: Beat 1 foundation — in-cluster → edge over mTLS (documented direction)

**Files:**
- Create: `demos/spiffe-cross-boundary/scripts/beat1-verify.sh`

**Interfaces:**
- Consumes: everything from Phases 2–4.
- Produces: proof the shared trust domain reaches the edge (cross-boundary mTLS, edge identity visible). This is the de-risking milestone; it uses the exact direction the Linkerd docs verify.

- [ ] **Step 1: Write `scripts/beat1-verify.sh`** (run on the cluster VM)

```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="${HOME}/.linkerd2/bin:${PATH}"
echo "== in-cluster client -> edge-echo (hosted on the VM) =="
kubectl -n mixed-env exec client -c client -- curl -s -m 5 http://edge-echo.mixed-env.svc.cluster.local/ | jq -r '.host.hostname'
echo "== tap: expect tls=true and server_id/dst = the edge SPIFFE identity =="
timeout 20 linkerd -n mixed-env viz tap deploy/client 2>/dev/null | grep -m1 -E 'tls=true' || true
linkerd -n mixed-env viz edges deployment 2>/dev/null || true
```

- [ ] **Step 2: Verify**

Run (in cluster VM, with edge proxy+app running): `just demo spiffe-cross-boundary beat1`
Expected: the curl returns the **edge VM's** hostname (traffic crossed to the VM); `tap` shows `tls=true`; `viz edges` shows the client↔edge-echo edge as secured. **This confirms the shared trust domain reaches the non-K8s workload.**

- [ ] **Step 3: Commit**

```bash
git add demos/spiffe-cross-boundary/scripts/beat1-verify.sh
git commit -m "spiffe-cross-boundary: Beat 1 — cross-boundary mTLS to the edge workload"
```

### Task 16: Beat 1 (spec direction) — edge → in-cluster echo, edge identity as client

**Files:**
- Create: `demos/spiffe-cross-boundary/scripts/beat1b-edge-client.sh`

**Interfaces:**
- Produces: proof the edge, as a *client*, presents `EDGE_SPIFFE_ID` to an in-cluster server (the exact identity string Beat 2 will gate on).

- [ ] **Step 1: Write `scripts/beat1b-edge-client.sh`** (drives a call from the edge VM, then reads identity on the cluster)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Run this ON THE EDGE VM. It calls the in-cluster echo through the edge proxy (outbound iptables redirect).
curl -s -m 8 http://echo.mixed-env.svc.cluster.local/ | jq -r '.host.hostname' \
  && echo "edge -> in-cluster echo OK (mTLS via proxy outbound)" \
  || { echo "outbound path failed — see FALLBACK in Task 17"; exit 1; }
```

- [ ] **Step 2: Verify**

Run (on the edge VM): `bash scripts/beat1b-edge-client.sh`; then on the cluster VM:
`linkerd -n mixed-env viz tap deploy/echo | grep -m1 client_id`
Expected: the edge call returns the in-cluster echo hostname; `tap` on `echo` shows `client_id=spiffe://root.linkerd.cluster.local/edge-echo` (or the exact identity — record it for Task 17). **If the outbound call fails,** note it and proceed to Task 17's fallback (gate the other direction); do not block.

- [ ] **Step 3: Commit**

```bash
git add demos/spiffe-cross-boundary/scripts/beat1b-edge-client.sh
git commit -m "spiffe-cross-boundary: Beat 1b — edge as client, SPIFFE identity to in-cluster server"
```

### Task 17: Beat 2 (money shot) — identity-based authz, 200 → 403

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/authz.yaml`
- Create: `demos/spiffe-cross-boundary/cluster/authz-deny.yaml`
- Create: `demos/spiffe-cross-boundary/scripts/beat2-authz.sh`

**Interfaces:**
- Consumes: the edge identity string confirmed in Task 16.
- Produces: an `AuthorizationPolicy` on the in-cluster `echo` `Server` that permits **only** the edge SPIFFE identity; flipping the allowed identity flips the edge's result 200 → 403.

> **Primary (edge as client → in-cluster echo).** Uses the identity confirmed in Task 16. **Fallback (if Task 16 outbound failed):** target the edge-hosted `Server` instead and gate on the in-cluster `client` ServiceAccount identity — same 200→403 proof, gating the other party. Both manifests below; the script picks based on a flag.

- [ ] **Step 1: Write `cluster/authz.yaml`** (allow only the edge identity to reach in-cluster echo)

```yaml
apiVersion: policy.linkerd.io/v1beta1
kind: Server
metadata:
  namespace: mixed-env
  name: echo-http
spec:
  podSelector:
    matchLabels: { app: echo }
  port: http
  proxyProtocol: HTTP/1
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  namespace: mixed-env
  name: allow-edge
spec:
  identities:
    - "spiffe://root.linkerd.cluster.local/edge-echo"
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  namespace: mixed-env
  name: echo-allow-edge
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: echo-http
  requiredAuthenticationRefs:
    - name: allow-edge
      kind: MeshTLSAuthentication
      group: policy.linkerd.io
```

- [ ] **Step 2: Write `cluster/authz-deny.yaml`** (same, but allow a DIFFERENT identity → edge now denied)

```yaml
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  namespace: mixed-env
  name: allow-edge
spec:
  identities:
    - "spiffe://root.linkerd.cluster.local/some-other-workload"
```

- [ ] **Step 3: Write `scripts/beat2-authz.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
edge_call() { # returns HTTP code from an edge->in-cluster echo call, run via the edge VM
  # Expects: run on cluster, uses a helper on the edge. For the reference env, invoke over your reachability.
  echo "Run on the EDGE VM: curl -s -o /dev/null -w '%{http_code}' -m 8 http://echo.mixed-env.svc.cluster.local/"
}
echo "== applying default-deny Server + allow-edge policy =="
kubectl apply -f "$HERE/cluster/authz.yaml"
sleep 3
echo ">> From the EDGE VM, expect 200:"; edge_call
echo "== flipping allowed identity to a different SPIFFE ID =="
kubectl apply -f "$HERE/cluster/authz-deny.yaml"
sleep 3
echo ">> From the EDGE VM, expect 403 (same network, only identity changed):"; edge_call
echo "== restoring =="; kubectl apply -f "$HERE/cluster/authz.yaml"
```

> **Empirical check for the `identities` value:** before trusting the URI form, on the cluster run `linkerd -n mixed-env viz tap deploy/echo | grep -m1 client_id` while the edge calls, and set `identities:` to that exact string if `spiffe://root.linkerd.cluster.local/edge-echo` is not what the server reports.

- [ ] **Step 4: Verify**

Apply + drive calls from the edge VM per the script's echoed commands.
Expected: with `authz.yaml` → **200**; after `authz-deny.yaml` → **403**; nothing about IP/route/firewall changed between the two. **This is the SPIFFE thesis demonstrated.**

- [ ] **Step 5: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/authz.yaml demos/spiffe-cross-boundary/cluster/authz-deny.yaml demos/spiffe-cross-boundary/scripts/beat2-authz.sh
git commit -m "spiffe-cross-boundary: Beat 2 — identity-based authz flips 200 to 403"
```

### Task 18 (stretch): Beat 3 — encrypt + authorize traffic TO the edge

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/authz-edge-server.yaml`
- Create: `demos/spiffe-cross-boundary/scripts/beat3-to-edge.sh`

**Interfaces:**
- Produces: authz on the edge-hosted service gating the in-cluster caller's identity (the reverse direction). Built only if Beats 1–2 pass with time to spare.

- [ ] **Step 1: Write `cluster/authz-edge-server.yaml`**

```yaml
# Gate the edge-hosted service on the in-cluster client's ServiceAccount identity.
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  namespace: mixed-env
  name: edge-allow-client
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: edge-echo-http
  requiredAuthenticationRefs:
    - name: allow-client-sa
      kind: MeshTLSAuthentication
      group: policy.linkerd.io
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  namespace: mixed-env
  name: allow-client-sa
spec:
  identities:
    - "default.mixed-env.serviceaccount.identity.linkerd.cluster.local"
```

> **To confirm during execution:** the `Server` targeting an `ExternalWorkload` uses an external-workload selector rather than `podSelector`. Read the current `Server` reference (`kubectl explain server.spec`) and set the correct selector field for `edge-echo-http` before applying. This is the one field this stretch task must verify live.

- [ ] **Step 2: Write `scripts/beat3-to-edge.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
kubectl apply -f "$HERE/cluster/authz-edge-server.yaml"
sleep 3
echo ">> in-cluster client -> edge-echo, expect 200 (allowed SA):"
kubectl -n mixed-env exec client -c client -- curl -s -o /dev/null -w '%{http_code}\n' -m 8 http://edge-echo.mixed-env.svc.cluster.local/
```

- [ ] **Step 3: Verify**

Run (in cluster VM): `just demo spiffe-cross-boundary beat3`
Expected: `200`; `linkerd viz tap` confirms `tls=true` into the edge. (Demonstrates encrypted, authorized traffic to a non-K8s workload.)

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/authz-edge-server.yaml demos/spiffe-cross-boundary/scripts/beat3-to-edge.sh
git commit -m "spiffe-cross-boundary: Beat 3 (stretch) — authorized mTLS to the edge"
```

---

## Phase 6 — Documentation (the blog-post backbone)

### Task 19: Demo walkthrough README + top-level index

**Files:**
- Modify: `demos/spiffe-cross-boundary/README.md` (replace the Task 2 stub)
- Modify: `README.md` (confirm the demo index row)

**Interfaces:**
- Produces: a runnable, ordered walkthrough a stranger can follow on their own two machines and network, plus the honest caveats.

- [ ] **Step 1: Write the full walkthrough** covering, in order: prerequisites (two machines with IP reachability, Lima on each, `config.local.env` with `CLUSTER_NODE_ADDR`/`EDGE_ADDR`); Box A steps (`cluster-up`, `gen-certs`, `install-k3s`, `install-linkerd`, `apply-echo`); the manual `ca.crt`/`ca.key` copy to the edge (`limactl copy`/`scp` over your own reachability); Box B steps (`edge-up`, `net/shim`, `install-spire`, `register-workload`, `extract-proxy`, `iptables`, `run-app`, `run-proxy`, `apply-externalworkload`); then the three beats; and teardown (`down`). Include the **caveats** section: root CA key lives on the edge (playground-only); `MeshTLSAuthentication.identities` value confirmed via `tap`; `join_token` attestation chosen for portability; only the Lima/Apple-Silicon path is verified. Cross-link the design spec.

- [ ] **Step 2: Verify**

Run: `shellcheck demos/spiffe-cross-boundary/scripts/*.sh demos/spiffe-cross-boundary/**/*.sh` (all clean) and read the README end-to-end confirming every referenced script/target exists and every command matches the committed files.
Expected: no dangling references; commands match files verbatim.

- [ ] **Step 3: Commit**

```bash
git add README.md demos/spiffe-cross-boundary/README.md
git commit -m "spiffe-cross-boundary: full walkthrough + caveats; repo demo index"
```

---

## Self-review (performed against the spec)

**Spec coverage:**
- Infrastructure-agnostic + two physical machines → Tasks 3–4 (Lima per box), Global Constraints. ✅
- Network as precondition, generic shim only → Task 9; no connectivity provider anywhere. ✅
- Shared trust domain via Linkerd anchor as SPIRE upstream → Tasks 5, 10. ✅
- `join_token` + `unix` attestation → Tasks 10–11. ✅
- ExternalWorkload + mesh expansion → Tasks 12–15. ✅
- Beat 1 (cross-boundary mTLS + SPIFFE identity) → Tasks 15–16. ✅
- Beat 2 (identity authz 200→403) → Task 17. ✅
- Beat 3 (stretch, to-edge) → Task 18. ✅
- Multi-demo repo shape, demo-neutral top level → Tasks 1–2, 19. ✅
- Arch-aware, idempotent, no-`#`-heredoc/no-`sed`, no-AI-attribution → Global Constraints + honored in every script (bash param-expansion instead of `sed` in Task 14). ✅

**Deviations from spec (grounded in the docs, called out to the user):**
- SPIRE server runs on the **edge**, not in-cluster (matches the official runbook; simpler). Trust-anchor-key-on-edge caveat documented.
- Build order leads with the **documented in-cluster→edge direction** (Task 15) to de-risk, then the spec's edge-as-client money shot (Tasks 16–17), with a fallback.

**Placeholder scan:** No TBDs. The two "confirm live" items (`MeshTLSAuthentication.identities` string; the `Server` external-workload selector for the Beat 3 stretch) are pinned to their most-likely values **with an exact command to confirm/correct** — a value plus a method, not a blank.

**Type/name consistency:** config var names, SPIFFE ID (`spiffe://root.linkerd.cluster.local/edge-echo`), namespace (`mixed-env`), VM names, and file paths are consistent across all tasks.
