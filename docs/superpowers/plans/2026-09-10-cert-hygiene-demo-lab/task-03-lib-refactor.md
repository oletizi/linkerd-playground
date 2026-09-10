# Task 3: Shared `lib/` refactor

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** Move the generic cert, k3s, and Linkerd install logic out of `demos/spiffe-cross-boundary/cluster/` into `lib/`. The three SPIFFE scripts stay at their paths as thin callers. Prove the SPIFFE behaviour is unchanged by recording an after-snapshot and comparing it with Task 2's before-snapshot.

**Files:**
- Create: `lib/certs.sh`, `lib/k3s.sh`, `lib/linkerd.sh`
- Modify (full rewrite, same path): `demos/spiffe-cross-boundary/cluster/gen-certs.sh`, `demos/spiffe-cross-boundary/cluster/install-k3s.sh`, `demos/spiffe-cross-boundary/cluster/install-linkerd.sh`
- Create: `demos/cert-hygiene/scripts/refactor-compare.sh`
- Create (output, committed): `demos/cert-hygiene/runs/_refactor-check/after/`, `demos/cert-hygiene/runs/_refactor-check/COMPARISON.md`

**Interfaces:**
- Consumes: `lib/common.sh` (`log`, `die`); Task 2's `lab/refactor-check.sh`, `lab/refactor-cleanup.sh`, `runs/_refactor-check/before/`
- Produces (all functions assume `lib/common.sh` is sourced first and run inside a Debian/Ubuntu VM):
  - `ensure_step`: installs the `step` CLI if absent.
  - `make_trust_anchor DIR LIFETIME`: writes `DIR/ca.crt` and `DIR/ca.key`. Dies if `DIR/ca.crt` exists.
  - `make_issuer DIR LIFETIME ANCHOR_DIR`: writes `DIR/issuer.crt` and `DIR/issuer.key`, signed by `ANCHOR_DIR/ca.{crt,key}`. Dies if `DIR/issuer.crt` exists.
  - `install_k3s`: installs k3s if absent, writes `~/.kube/config`, and waits for a Ready node and kube-dns. `reset_k3s` uninstalls, then runs `install_k3s`.
  - `ensure_linkerd_cli VERSION`: installs the CLI if no `linkerd` is on PATH. Exports PATH and symlinks `/usr/local/bin/linkerd`.
  - `install_gateway_crds VERSION`, `wait_rollouts NS`.
  - `linkerd_install ANCHOR ISSUER_CRT ISSUER_KEY [linkerd install flags...]`: installs the CRDs and control plane, then runs `wait_rollouts linkerd`. **Runs no `linkerd check`.**

**Behaviour note:** `ensure_linkerd_cli` keeps the SPIFFE semantics exactly: it installs only if no `linkerd` is found, and never compares versions. The cert-hygiene lab gets its pinned version for two reasons. First, `refactor-cleanup.sh` removes the SPIFFE CLI. Second, Task 7's validity check refuses a run whose CLI version differs from `LINKERD_EDGE_VERSION`.

- [ ] **Step 1: Write `lib/certs.sh`**

```bash
#!/usr/bin/env bash
# Certificate helpers for Linkerd's mesh identity hierarchy: trust anchor (root CA)
# signs the identity issuer (intermediate CA). Source after lib/common.sh; do not
# execute. Runs inside a Debian/Ubuntu VM (ensure_step installs a .deb).

# ensure_step: install the smallstep CLI from its latest release if it is absent.
ensure_step() {
  command -v step >/dev/null 2>&1 && return 0
  local arch url
  arch="$(dpkg --print-architecture)"   # amd64 | arm64
  # Resolve the .deb URL from the release assets (names carry a Debian revision, e.g. _0.30.6-1_arm64.deb).
  url="$(curl -sSf https://api.github.com/repos/smallstep/cli/releases/latest \
    | jq -r --arg a "$arch" '.assets[] | select(.name | test("_" + $a + "\\.deb$")) | .browser_download_url' | head -1)"
  [ -n "$url" ] || die "could not resolve step-cli .deb for arch $arch"
  curl -sSLf "$url" -o /tmp/step.deb
  sudo dpkg -i /tmp/step.deb
}

# make_trust_anchor DIR LIFETIME: a self-signed root CA, DIR/ca.crt + DIR/ca.key.
# LIFETIME is step's --not-after syntax (e.g. 87600h, 720h). Never overwrites.
make_trust_anchor() {
  local dir="${1:?make_trust_anchor: DIR required}" lifetime="${2:?make_trust_anchor: LIFETIME required}"
  [ ! -e "$dir/ca.crt" ] || die "make_trust_anchor: $dir/ca.crt exists; refusing to overwrite a trust anchor"
  mkdir -p "$dir"
  step certificate create root.linkerd.cluster.local "$dir/ca.crt" "$dir/ca.key" \
    --profile root-ca --no-password --insecure --not-after="$lifetime"
}

# make_issuer DIR LIFETIME ANCHOR_DIR: an intermediate CA for Linkerd identity,
# DIR/issuer.crt + DIR/issuer.key, signed by ANCHOR_DIR/ca.crt + ca.key. Never overwrites.
make_issuer() {
  local dir="${1:?make_issuer: DIR required}" lifetime="${2:?make_issuer: LIFETIME required}"
  local anchor="${3:?make_issuer: ANCHOR_DIR required}"
  [ -f "$anchor/ca.crt" ] && [ -f "$anchor/ca.key" ] || die "make_issuer: no trust anchor in $anchor"
  [ ! -e "$dir/issuer.crt" ] || die "make_issuer: $dir/issuer.crt exists; refusing to overwrite an issuer"
  mkdir -p "$dir"
  step certificate create identity.linkerd.cluster.local "$dir/issuer.crt" "$dir/issuer.key" \
    --profile intermediate-ca --not-after "$lifetime" --no-password --insecure \
    --ca "$anchor/ca.crt" --ca-key "$anchor/ca.key"
}
```

- [ ] **Step 2: Write `lib/k3s.sh`**

```bash
#!/usr/bin/env bash
# k3s helpers. Source after lib/common.sh; do not execute. Runs inside the VM.

# install_k3s: install k3s if absent, trimmed to save RAM (no Traefik, no servicelb),
# with a world-readable kubeconfig copied to ~/.kube/config; then wait for the node
# and CoreDNS.
install_k3s() {
  if ! command -v k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
  fi
  mkdir -p "${HOME}/.kube"
  # k3s wrote the kubeconfig world-readable (mode 644), so no sudo needed to read it.
  cat /etc/rancher/k3s/k3s.yaml > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  # k3s returns before the node registers and before CoreDNS is created, so wait
  # rather than querying straight away -- otherwise a caller's next kubectl exits 1
  # on a good install and prints nothing.
  local _
  for _ in $(seq 1 60); do
    kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready ' && break
    sleep 5
  done
  for _ in $(seq 1 60); do
    kubectl -n kube-system get svc kube-dns >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl get nodes -o wide
}

# reset_k3s: a fresh, empty cluster -- uninstall k3s if present, then install_k3s.
reset_k3s() {
  if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    log "uninstalling k3s"
    sudo /usr/local/bin/k3s-uninstall.sh
  fi
  install_k3s
}
```

- [ ] **Step 3: Write `lib/linkerd.sh`**

```bash
#!/usr/bin/env bash
# Linkerd install helpers. Source after lib/common.sh; do not execute. Runs inside the VM.

# ensure_linkerd_cli VERSION: install the edge CLI at VERSION when no linkerd is on
# PATH, then make it reachable however the box is entered.
ensure_linkerd_cli() {
  local version="${1:?ensure_linkerd_cli: VERSION required}"
  if ! command -v linkerd >/dev/null 2>&1; then
    curl -sL https://run.linkerd.io/install-edge | LINKERD2_VERSION="${version}" sh
  fi
  export PATH="${HOME}/.linkerd2/bin:${PATH}"
  # The installer drops the CLI in ~/.linkerd2/bin, which no shell has on its PATH
  # -- not an interactive login, and not `ssh host '<command>'` either. Symlink it
  # next to k3s's kubectl so `linkerd ...` works as written, however you reach the box.
  sudo ln -sf "${HOME}/.linkerd2/bin/linkerd" /usr/local/bin/linkerd
}

# install_gateway_crds VERSION: Linkerd requires the Gateway API CRDs before install.
install_gateway_crds() {
  local version="${1:?install_gateway_crds: VERSION required}"
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${version}/standard-install.yaml"
}

# `linkerd check` polls in silence while images pull and pods become ready. On a
# first run that is minutes of a blank terminal, which reads as a hang -- the
# information exists (pods coming up, images pulling), it just never reaches the
# screen. `rollout status` prints a line per deployment as it progresses, so the
# wait is visible before `check` starts its quiet polling.
#
# Informational only: a rollout that does not finish in time does NOT stop the
# script. `linkerd check` runs next and is the authority on whether the install is
# good -- it diagnoses *what* is wrong, where a bare rollout timeout would only
# say that something took too long.
wait_rollouts() { # namespace
  local ns="$1" d
  log "waiting for $ns workloads to become ready (this is where the install spends its time)"
  for d in $(kubectl -n "$ns" get deploy -o name 2>/dev/null); do
    kubectl -n "$ns" rollout status "$d" --timeout="${ROLLOUT_TIMEOUT:-10m}" \
      || log "warning: $d is not ready yet; continuing to 'linkerd check' for the real diagnosis"
  done
}

# linkerd_install ANCHOR ISSUER_CRT ISSUER_KEY [linkerd install flags...]: install the
# CRDs and the control plane rooted at the given trust anchor and issuer, then wait
# for the rollouts. Runs no `linkerd check`: callers choose when to check and where
# its output goes.
linkerd_install() {
  local anchor="${1:?linkerd_install: ANCHOR required}" crt="${2:?linkerd_install: ISSUER_CRT required}"
  local key="${3:?linkerd_install: ISSUER_KEY required}"
  shift 3
  linkerd install --crds | kubectl apply -f -
  linkerd install \
    --identity-trust-anchors-file "$anchor" \
    --identity-issuer-certificate-file "$crt" \
    --identity-issuer-key-file "$key" \
    "$@" \
    | kubectl apply -f -
  wait_rollouts linkerd
}
```

- [ ] **Step 4: Rewrite `demos/spiffe-cross-boundary/cluster/gen-certs.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Generates the Linkerd trust anchor (root) + issuer.
# ca.crt/ca.key are later copied to the edge as SPIRE's UpstreamAuthority.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/certs.sh"
DIR="${HOME}/linkerd-certs"

if [ ! -f "$DIR/ca.crt" ]; then
  ensure_step
  make_trust_anchor "$DIR" 87600h
  make_issuer "$DIR" 8760h "$DIR"
fi
step certificate inspect "$DIR/ca.crt" --short
```

- [ ] **Step 5: Rewrite `demos/spiffe-cross-boundary/cluster/install-k3s.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the cluster VM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/k3s.sh"

install_k3s
echo -n 'kube-dns ClusterIP (must match COREDNS_ADDR): '
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
```

- [ ] **Step 6: Rewrite `demos/spiffe-cross-boundary/cluster/install-linkerd.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Installs Linkerd rooted at our trust anchor + viz.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$HERE"
# shellcheck source=/dev/null
. "$ROOT/lib/linkerd.sh"
CERTS="${HOME}/linkerd-certs"

ensure_linkerd_cli "${LINKERD_EDGE_VERSION}"
install_gateway_crds v1.2.1
linkerd_install "${CERTS}/ca.crt" "${CERTS}/issuer.crt" "${CERTS}/issuer.key"
linkerd check
linkerd viz install | kubectl apply -f -
wait_rollouts linkerd-viz
linkerd check
```

- [ ] **Step 7: Write `demos/cert-hygiene/scripts/refactor-compare.sh`**

```bash
#!/usr/bin/env bash
# Runs on the macOS HOST. Compares the before/after records of the SPIFFE cluster-side
# scripts (lab/refactor-check.sh). Fails on any difference that matters: an exit
# status, the final `linkerd check`, the versions, or the set of pods and their state.
# Prints the remaining per-log diffs for a human to classify.
# Usage: refactor-compare.sh <before-dir> <after-dir>
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
before="${1:?usage: refactor-compare.sh <before-dir> <after-dir>}"
after="${2:?usage: refactor-compare.sh <before-dir> <after-dir>}"
bad=0

for f in gen-certs.log install-k3s.log install-linkerd.log linkerd-check.txt; do
  b="$(tail -n 1 "$before/$f")"; a="$(tail -n 1 "$after/$f")"
  [ "$b" = "$a" ] || { err "$f: exit differs (before '$b', after '$a')"; bad=1; }
done
for f in linkerd-check.txt linkerd-version.txt; do
  diff -u "$before/$f" "$after/$f" || { err "$f differs"; bad=1; }
done
# Pod names carry random suffixes; compare namespace, READY and STATUS per pod count.
pod_shape() { awk 'NR>1 {print $1, $3, $4}' "$1/pods.txt" | sort | uniq -c; }
diff -u <(pod_shape "$before") <(pod_shape "$after") || { err "pod set differs"; bad=1; }

for f in gen-certs.log install-k3s.log install-linkerd.log; do
  log "diff of $f (classify every hunk in COMPARISON.md):"
  diff -u "$before/$f" "$after/$f" || true
done
[ "$bad" -eq 0 ] || die "the refactor changed SPIFFE behaviour"
log "exit statuses, linkerd check, versions and pod set all match"
```

- [ ] **Step 8: Syntax-check and shellcheck**

Run: `for f in lib/*.sh demos/spiffe-cross-boundary/cluster/*.sh demos/cert-hygiene/scripts/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done`
Expected: no output.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'cd ../.. && shellcheck -x lib/*.sh demos/spiffe-cross-boundary/cluster/*.sh demos/cert-hygiene/scripts/*.sh'`
Expected: no findings.

- [ ] **Step 9: Record the after-snapshot**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/refactor-cleanup.sh`
Expected: `lab VM is clean`.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh --detach .lab-logs/after.log lab/refactor-check.sh runs/_refactor-check/after && bash scripts/wait-log.sh .lab-logs/after.log 1500`
Expected: `[exit 0]`. If `wait-log.sh` hits the tool's time limit, run it again.

- [ ] **Step 10: Compare**

Run: `cd demos/cert-hygiene && bash scripts/refactor-compare.sh runs/_refactor-check/before runs/_refactor-check/after`
Expected: exits 0 and ends with `exit statuses, linkerd check, versions and pod set all match`.

The per-log diffs should contain only these classes of difference:
- certificate serials, fingerprints, and validity timestamps
- download and progress output
- apt/dpkg output
- timing
- pod hash suffixes

**If the compare exits non-zero, stop.** The refactor changed behaviour. Fix `lib/` and repeat Steps 9–10 with a fresh `after` directory (delete the failed one first; it was never committed).

- [ ] **Step 11: Write `demos/cert-hygiene/runs/_refactor-check/COMPARISON.md`**

Record, from the Step 10 output: the compare's final line, and one bullet per diff hunk class seen in each of the three logs, naming the class from the list above. Also record anything outside those classes and why it is harmless. Under a `Verdict` heading, state whether SPIFFE behaviour is unchanged.

- [ ] **Step 12: Clean the VM**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/refactor-cleanup.sh`
Expected: `lab VM is clean`.

- [ ] **Step 13: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` row to `In progress: shared lib/ refactor verified against SPIFFE (plan Task 3 of 9)`.

```bash
git add lib/certs.sh lib/k3s.sh lib/linkerd.sh demos/spiffe-cross-boundary/cluster demos/cert-hygiene/scripts/refactor-compare.sh demos/cert-hygiene/runs/_refactor-check docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene lift cert, k3s and Linkerd install helpers into lib"
git push
```
