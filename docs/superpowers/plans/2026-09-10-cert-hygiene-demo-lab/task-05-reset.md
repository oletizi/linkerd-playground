# Task 5: Lab reset and image pinning

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** One command gives a fresh k3s cluster with Linkerd `edge-26.9.1`, rooted at freshly generated lab credentials. `short` mode gives the #5 lifetimes and `long` mode the control's. Every image is pulled *before* the certificates are generated, so network time never eats into a short issuer's lifetime. The probe images are pinned by digest in config.

**Files:**
- Create: `demos/cert-hygiene/lab/lib-lab.sh`
- Create: `demos/cert-hygiene/lab/reset.sh`
- Create: `demos/cert-hygiene/lab/resolve-images.sh`
- Modify: `demos/cert-hygiene/config.example.env` (add the image pins)
- Modify: `demos/cert-hygiene/Justfile` (add `reset`)

**Interfaces:**
- Consumes: `lib/certs.sh`, `lib/k3s.sh`, `lib/linkerd.sh` (Task 3); `lib/common.sh`; `lab/lib-evidence.sh` (Task 4); `scripts/in-lab.sh`, `scripts/wait-log.sh` (Task 1)
- Produces:
  - `lab/lib-lab.sh`, sourced by every in-VM script from here on. It sets `DEMO`, `ROOT`, and `CERTS_ROOT="$HOME/cert-hygiene-certs"`; loads config; sources `lib/{common,certs,k3s,linkerd}.sh` and `lab/lib-evidence.sh`; and puts `~/.linkerd2/bin` on PATH. It defines:
    - `require_pinned_images`: dies unless `IMAGE_CURL`, `IMAGE_SOCAT`, and `IMAGE_BUSYBOX` are all pinned `@sha256:`.
    - `prepull_linkerd_images`
    - `prepull_workload_images`
  - `lab/reset.sh <short|long> <cert-set-name>`: keys go to `$CERTS_ROOT/<cert-set-name>/{ca,issuer}.{crt,key}`. It refuses an existing set. Last line on success: `reset complete: mode=<mode> certs=<dir>`.
  - Config: `IMAGE_CURL`, `IMAGE_SOCAT`, `IMAGE_BUSYBOX` (digest-pinned references).

- [ ] **Step 1: Write `demos/cert-hygiene/lab/lib-lab.sh`**

```bash
#!/usr/bin/env bash
# In-VM environment for the cert-hygiene lab scripts. Source; do not execute.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$LAB_DIR/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
load_config "$DEMO"
# shellcheck source=/dev/null
. "$ROOT/lib/certs.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/k3s.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/linkerd.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/lib-evidence.sh"

# Lab keys live here, inside the VM, never under the repo (which is a Mac path).
CERTS_ROOT="$HOME/cert-hygiene-certs"
export PATH="$HOME/.linkerd2/bin:$PATH"

# require_pinned_images: the probe images must be pinned by digest (Task 5 Step 6).
require_pinned_images() {
  local v
  for v in IMAGE_CURL IMAGE_SOCAT IMAGE_BUSYBOX; do
    case "${!v:-}" in
      *@sha256:*) ;;
      *) die "$v is not pinned by digest in config.example.env; run lab/resolve-images.sh and paste its output" ;;
    esac
  done
}

# prepull_linkerd_images: pull every image the control plane uses. Renders the
# install manifest without lab certificates (the CLI then generates throwaway ones)
# purely to read its image list -- nothing is applied.
prepull_linkerd_images() {
  local img
  for img in $(linkerd install \
      | awk '{ for (i = 1; i < NF; i++) if ($i == "image:") print $(i + 1) }' \
      | tr -d '"' | sort -u); do
    log "pulling $img"
    sudo k3s crictl pull "$img" >/dev/null
  done
}

# prepull_workload_images: pull the pinned probe and workload images.
prepull_workload_images() {
  local img
  require_pinned_images
  for img in "$IMAGE_CURL" "$IMAGE_SOCAT" "$IMAGE_BUSYBOX"; do
    log "pulling $img"
    sudo k3s crictl pull "$img" >/dev/null
  done
}
```

- [ ] **Step 2: Write `demos/cert-hygiene/lab/reset.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. A fresh cluster with Linkerd rooted at freshly generated lab
# credentials. Usage: reset.sh <short|long> <cert-set-name>
#   short: ANCHOR_LIFETIME / ISSUER_LIFETIME (scenario #5: the issuer expires mid-run)
#   long:  CONTROL_ANCHOR_LIFETIME / CONTROL_ISSUER_LIFETIME (the negative control)
# Every image is pulled BEFORE the certificates are generated, so pulls never eat into
# a short issuer's lifetime.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"

mode="${1:?usage: reset.sh <short|long> <cert-set-name>}"
name="${2:?usage: reset.sh <short|long> <cert-set-name>}"
case "$mode" in
  short) anchor_life="$ANCHOR_LIFETIME"; issuer_life="$ISSUER_LIFETIME" ;;
  long)  anchor_life="$CONTROL_ANCHOR_LIFETIME"; issuer_life="$CONTROL_ISSUER_LIFETIME" ;;
  *) die "mode must be short or long, not '$mode'" ;;
esac
certs="$CERTS_ROOT/$name"
[ ! -e "$certs" ] || die "$certs already exists; every reset gets a new cert set"
require_pinned_images

reset_k3s
ensure_linkerd_cli "$LINKERD_EDGE_VERSION"
install_gateway_crds "$GATEWAY_API_VERSION"
linkerd install --crds | kubectl apply -f -
prepull_linkerd_images
prepull_workload_images

# The clock on a short issuer starts here.
ensure_step
make_trust_anchor "$certs" "$anchor_life"
make_issuer "$certs" "$issuer_life" "$certs"
linkerd_install "$certs/ca.crt" "$certs/issuer.crt" "$certs/issuer.key" \
  --identity-issuance-lifetime "$LEAF_LIFETIME"
log "reset complete: mode=$mode certs=$certs"
```

- [ ] **Step 3: Write `demos/cert-hygiene/lab/resolve-images.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM, with k3s running. Pulls each probe image by tag and prints
# the config line that pins it to the digest just pulled (the multi-arch index digest
# containerd records for a by-tag pull). Paste the output into config.example.env.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
command -v k3s >/dev/null 2>&1 || die "k3s is not installed; run reset_k3s first"

for pair in \
    IMAGE_CURL=docker.io/curlimages/curl:latest \
    IMAGE_SOCAT=docker.io/alpine/socat:latest \
    IMAGE_BUSYBOX=docker.io/library/busybox:latest; do
  var="${pair%%=*}"; ref="${pair#*=}"
  sudo k3s crictl pull "$ref" >/dev/null
  digest="$(sudo k3s crictl inspecti -o json "$ref" | jq -r '.status.repoDigests[0]')"
  [ -n "$digest" ] && [ "$digest" != null ] || die "no repo digest recorded for $ref"
  printf '%s=%s   # pinned from %s on %s\n' "$var" "$digest" "$ref" "$(date -u +%Y-%m-%d)"
done
```

- [ ] **Step 4: Add `reset` to `demos/cert-hygiene/Justfile`**

Append:

```just

# Fresh k3s + Linkerd with lab credentials, for manual poking (MODE: short | long)
reset MODE="short":
    bash scripts/in-lab.sh --detach .lab-logs/reset.log lab/reset.sh {{MODE}} manual-$(date -u +%Y%m%dT%H%M%SZ)
    bash scripts/wait-log.sh .lab-logs/reset.log 1500
```

- [ ] **Step 5: Syntax-check and shellcheck**

Run: `cd demos/cert-hygiene && for f in lab/lib-lab.sh lab/reset.sh lab/resolve-images.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/lib-lab.sh lab/reset.sh lab/resolve-images.sh'`
Expected: no output.

- [ ] **Step 6: Pin the probe images**

k3s must be running before images can be resolved. Bring up an empty cluster, then resolve:

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && reset_k3s'`
Expected: ends with a `kubectl get nodes -o wide` table showing one `Ready` node.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/resolve-images.sh`
Expected: three lines, e.g. `IMAGE_CURL=docker.io/curlimages/curl@sha256:<64 hex>   # pinned from docker.io/curlimages/curl:latest on 2026-09-10`.

Append them to `demos/cert-hygiene/config.example.env` under a new section, exactly as printed:

```bash

# ---- Workload images (pinned by digest; regenerate with lab/resolve-images.sh) ----
<the three lines printed above>
```

- [ ] **Step 7: Run a full short reset**

Run: `just demo cert-hygiene reset short`
Expected: exit 0. The tail shows `[reset.sh] reset complete: mode=short certs=/home/<user>/cert-hygiene-certs/manual-<stamp>` and then `[exit 0]`.

- [ ] **Step 8: Verify what the reset produced**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'linkerd check; echo "check_exit=$?"'`
Expected: `check_exit=0`. `‼` warnings appear for the trust anchor and issuer being "valid for at least 60 days" (expected for lab lifetimes). There are no `×` lines.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'kubectl -n linkerd get deploy linkerd-identity -o jsonpath="{.spec.template.spec.containers[?(@.name==\"identity\")].args}"; echo'`
Expected: the args include `-identity-issuance-lifetime=5m`.

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh; d=$(ls -dt "$CERTS_ROOT"/manual-* | head -1); echo "issuer expires in $(( $(cert_not_after_epoch "$d/issuer.crt") - $(date -u +%s) ))s"'`
Expected: a positive number of seconds. Record it in the commit message body: it is the pre-expiry window left after install, and it must exceed `LEAF_LIFETIME` + 60s (360s) for H1 to be observable. If it doesn't, stop and report rather than raising lifetimes silently.

Run: `grep -rl 'PRIVATE KEY' demos/cert-hygiene || echo none`
Expected: `none`. Keys stay in the VM.

- [ ] **Step 9: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` row to `In progress: lab reset with short-lived credentials works (plan Task 5 of 10)`.

```bash
git add demos/cert-hygiene/lab/lib-lab.sh demos/cert-hygiene/lab/reset.sh demos/cert-hygiene/lab/resolve-images.sh demos/cert-hygiene/config.example.env demos/cert-hygiene/Justfile docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene add lab reset with short-lived credentials and pinned images" -m "Pre-expiry window left after install: <seconds from Step 8>s"
git push
```
