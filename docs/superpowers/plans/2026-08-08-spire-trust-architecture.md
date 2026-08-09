# SPIRE Trust-Architecture Change — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the SPIRE server into the k3s cluster and run an agent-only edge, so the Linkerd root CA private key never lives on the store host — and harden workload attestation (non-root proxy, uid+path) and agent bootstrap (pinned bundle), per the approved design.

**Architecture:** SPIRE **server** runs as an in-cluster k3s StatefulSet (root cert+key mounted as a read-only Secret; NodePort `:30081` restricted to the tailnet by a host firewall rule). The **edge** runs the SPIRE **agent only**, dialing the cluster server with a pinned trust bundle; the `linkerd2-proxy` runs as a dedicated non-root user (uid 2102) and is attested by `unix:uid:2102` + `unix:path`; iptables redirects only the app's uid (1000). The workload SVID becomes `spiffe://root.linkerd.cluster.local/store/042/inventory-sync`.

**Tech Stack:** SPIRE (server + agent), Linkerd (edge channel) mesh expansion, k3s, Lima VMs, Tailscale, bash + HCL + YAML, `just`.

**Design record:** `docs/superpowers/specs/2026-08-08-spire-trust-architecture-design.md` (approved, two review rounds). Read it first — this plan implements it; it does not re-argue it.

## Testing model (read first)

This is infrastructure, not a unit-tested codebase. Each task's **test is a verification command with expected output**, run on the **live two-VM demo** after the change (the honest analog of TDD here). Where a task produces a shell script or manifest, the mechanical check (`bash -n` / `shellcheck` / `kubectl apply --dry-run=client`) runs before the behavioural verification.

**How to reach each VM (used verbatim in verification steps):**
- **Cluster VM** (on orion-m1): `ssh orion-m1.local 'export PATH="/opt/homebrew/bin:$PATH"; limactl shell linkerd-cluster -- bash -lc "<cmd>"'`
- **Edge VM** (on this Mac): `limactl shell linkerd-edge -- bash -lc "<cmd>"`
- **Dashboard** (from anywhere on the tailnet): `curl -s http://100.126.75.18:30080/api/data`
- The **`linkerd` CLI** inside the cluster VM needs `export PATH=$HOME/.linkerd2/bin:$PATH`.

**Edge SSH can flake under load** (2 CPU / 4 GiB). If `limactl shell linkerd-edge` returns `kex_exchange_identification: Connection reset`, retry; if it persists, `limactl stop linkerd-edge && limactl start linkerd-edge` (a reboot is safe — this plan rebuilds edge runtime state anyway).

## Global Constraints

Copied from the design; every task implicitly includes these:

- **Trust domain:** `root.linkerd.cluster.local` (unchanged — Linkerd-pinned).
- **Workload SVID:** `spiffe://root.linkerd.cluster.local/store/042/inventory-sync`.
- **Agent (node) SVID:** `spiffe://root.linkerd.cluster.local/store/042/agent`.
- **Proxy user:** dedicated non-root `linkerd-proxy`, **uid 2102**; app (`store-pos`) stays **uid 1000**.
- **Workload selectors:** `unix:uid:2102` **and** `unix:path:/opt/linkerd-proxy/linkerd-proxy` (both required).
- **Agent unix attestor MUST set** `discover_workload_path = true`, `workload_size_limit = -1` (else `unix:path` is never emitted).
- **Bootstrap:** agent pins `trust_bundle_path`; **no** `insecure_bootstrap`.
- **Root key:** lives only in the cluster (k8s Secret). **`/opt/spire/certs/ca.key` must NOT exist on the edge.**
- **SPIRE server NodePort `:30081`** reachable from the edge over Tailscale only (host firewall rule; the pinned bundle + join-token + server cert chain are the actual authentication).
- **k8s object names kept** (`store-pos`, `retail-cloud`, etc.); only the identity **string** changes.
- **CLUSTER_NODE_ADDR = 100.126.75.18** (cluster VM tailnet IP); edge = `100.77.68.7`.
- **VM repos are tar copies (no git).** Deploy code by copying files into the guests (see "Deploying code to a VM" below).
- **House rules:** no `#` inside heredocs / multi-line quoted args (write files with the Write tool, run via `bash file`); no `sed` writes (use param expansion / Write tool); no AI attribution in commits; source files 300–500 lines max.
- **Security honesty:** this is a teaching demo. Do NOT claim production-readiness. Single-replica sqlite SPIRE, join-token enrollment, and in-cluster Secret root-key storage remain documented simplifications; UID+path attestation is least-privilege isolation, **not** defense against host-root.

### Deploying code to a VM (no git in the guests)

From the host repo root, to copy the demo tree into a guest:

```bash
# edge (this Mac):
tar -C demos/spiffe-cross-boundary -czf - . | limactl shell linkerd-edge -- \
  bash -c 'mkdir -p ~/linkerd-playground/demos/spiffe-cross-boundary && tar -C ~/linkerd-playground/demos/spiffe-cross-boundary -xzf -'
# cluster (orion-m1): pipe through ssh
tar -C demos/spiffe-cross-boundary -czf - . | ssh orion-m1.local \
  'export PATH="/opt/homebrew/bin:$PATH"; limactl shell linkerd-cluster -- bash -c "mkdir -p ~/linkerd-playground/demos/spiffe-cross-boundary && tar -C ~/linkerd-playground/demos/spiffe-cross-boundary -xzf -"'
```

Also copy the repo-root `lib/common.sh` (scripts source `../../../lib/common.sh`):
```bash
tar -C . -czf - lib | limactl shell linkerd-edge -- bash -c 'tar -C ~/linkerd-playground -xzf -'
```
`<demo>` below abbreviates `~/linkerd-playground/demos/spiffe-cross-boundary` inside a guest.

## File structure

**New (cloud SPIRE, in `demos/spiffe-cross-boundary/cluster/spire/`):**
- `server.cfg` — SPIRE server HCL (mounted via ConfigMap).
- `spire-server.yaml` — Namespace, ServiceAccount (automount off), StatefulSet, Service (NodePort).
- `apply.sh` — create Secret (from `~/linkerd-certs`) + ConfigMap (from `server.cfg`), apply manifests, wait Ready, install the NodePort firewall rule, then register the entry + export the bundle + mint a join token.
- `firewall.sh` — host `mangle/PREROUTING` rule restricting TCP/30081 to `tailscale0`.

**Modified (edge):**
- `edge/spire/agent.cfg` — remote server, pinned bundle, `discover_workload_path`.
- `edge/spire/server.cfg` — **deleted** (no server on the edge).
- `edge/install-spire.sh` → **renamed** `edge/install-spire-agent.sh` — agent-only; consumes the bundle + token; removes `ca.key`.
- `edge/register-workload.sh` — **deleted** (registration now happens on the cluster server).
- `edge/run-proxy.sh` — launch the proxy as uid 2102 (via `setpriv`); new SVID env.
- `edge/iptables.sh` — app-scoped OUTPUT redirect (only uid 1000); no inbound chain; no root exemption.
- `store-pos/run-store-pos.sh` — unchanged (already `--user 1000:1000`); confirmed by Task 6.

**Modified (identity / policy / app):**
- `config.example.env` — new `EDGE_SPIFFE_ID`, `EDGE_SERVER_NAME`, and new `SPIRE_AGENT_SPIFFE_ID`, `PROXY_UID`, `APP_UID`, `SPIRE_SERVER_PORT`.
- `cluster/retail/store-pos.yaml` — `meshTLS.identity` + `serverName` → new values.
- `cluster/retail/authz.yaml` — `MeshTLSAuthentication.identities[0]` → new SVID.
- `retail-cloud/server.js` — `STORE_ID` → new SVID; `/api/data` returns an `enrollment` block.
- `retail-cloud/index.html` — enrollment-vs-workload panel.

**Modified (docs):**
- `MANUAL.md`, `README.md` — rewrite the SPIRE sections (Part 3, the cert-copy step, the proxy user, iptables).
- `PRODUCTION-NOTES.md` — mark root-key/attestation/bootstrap resolved; correct join-token framing; add the Security-boundaries limitations.
- `retail-cloud/tutorial.html` — the "SPIRE server + agent on the edge" wording + topology-diagram nodes.

---

## Phase 0 — Baseline to a known-clean slate

### Task 1: Reconcile the environment

**Files:** none (operational). **Interfaces:** Produces a clean baseline every later task assumes — cluster control plane healthy; **no** SPIRE server or data on the cluster VM host (the derisk prototype) or the edge; edge connectivity (route + DNS) up.

- [ ] **Step 1: Verify the cluster control plane is healthy**

Run (cluster VM):
```bash
export PATH=$HOME/.linkerd2/bin:$PATH
kubectl get nodes
kubectl -n mixed-env get pods
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
```
Expected: node `Ready`; `retail-cloud` / `echo` / `client` pods `Running`; kube-dns ClusterIP `10.43.0.10`.

- [ ] **Step 2: Remove the derisk-prototype SPIRE server from the cluster VM host**

The derisk left a `spire-server` process + `/opt/spire` on the cluster VM **host** (not in k8s). Remove it so the only SPIRE server is the k8s one built in Phase 1.

Run (cluster VM):
```bash
sudo pkill -f 'spire-server run' 2>/dev/null || true
sudo rm -rf /opt/spire /tmp/spire-server.log /tmp/spire-bundle.pem
pgrep -af spire-server || echo "no spire-server on cluster host — good"
```
Expected: `no spire-server on cluster host — good`.

- [ ] **Step 3: Bring up edge connectivity (route + cluster DNS)**

Run (edge VM):
```bash
cd <demo> && bash net/shim.sh
ip route get 10.43.0.10 | head -1
getent hosts retail-cloud.mixed-env.svc.cluster.local | awk '{print $1}'
```
Expected: the route to `10.43.0.10` goes `via 100.126.75.18`; DNS resolves `retail-cloud…` to a `10.43.x` ClusterIP.

- [ ] **Step 4: Tear down any old edge SPIRE + proxy, and remove the root key**

Run (edge VM):
```bash
sudo pkill -f 'spire-server run' 2>/dev/null || true
sudo pkill -f 'spire-agent run' 2>/dev/null || true
sudo pkill -f '/opt/linkerd-proxy/linkerd-proxy' 2>/dev/null || true
sudo docker rm -f store-pos edge-echo 2>/dev/null || true
sudo iptables -t nat -F 2>/dev/null || true; sudo iptables -t nat -X 2>/dev/null || true
sudo rm -f /opt/spire/certs/ca.key
sudo rm -rf /opt/spire/data/server /opt/spire/server.cfg
test -e /opt/spire/certs/ca.key && echo "STILL PRESENT" || echo "ca.key removed from edge — good"
```
Expected: `ca.key removed from edge — good`. (`ca.crt` stays — the proxy needs it as its trust anchor.)

- [ ] **Step 5: Commit** (no repo changes this task; record the baseline in the branch log)

```bash
git commit --allow-empty -m "spire-rearch: verified clean baseline (cluster healthy, edge cleaned, root key off edge)"
```

---

## Phase 1 — Cloud SPIRE server (in k3s)

### Task 2: Author the SPIRE server config + manifests

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/spire/server.cfg`
- Create: `demos/spiffe-cross-boundary/cluster/spire/spire-server.yaml`
- Create: `demos/spiffe-cross-boundary/cluster/spire/firewall.sh`

**Interfaces:**
- Produces: a SPIRE server that trusts `root.linkerd.cluster.local`, signs under the mounted root Secret, and is reachable at `<node>:30081`. Consumed by Task 3 (deploy) and Task 4 (register).

- [ ] **Step 1: Write `cluster/spire/server.cfg`**

```hcl
server {
    bind_address = "0.0.0.0"
    bind_port = "8081"
    trust_domain = "root.linkerd.cluster.local"
    data_dir = "/run/spire/data"
    log_level = "INFO"
    ca_ttl = "168h"
    default_x509_svid_ttl = "48h"
}
plugins {
    DataStore "sql" {
        plugin_data { database_type = "sqlite3"
            connection_string = "/run/spire/data/datastore.sqlite3" }
    }
    KeyManager "disk" { plugin_data { keys_path = "/run/spire/data/keys.json" } }
    NodeAttestor "join_token" { plugin_data {} }
    UpstreamAuthority "disk" {
        plugin_data {
            cert_file_path = "/run/spire/secret/ca.crt"
            key_file_path = "/run/spire/secret/ca.key"
        }
    }
}
```

- [ ] **Step 2: Write `cluster/spire/spire-server.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: spire
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: spire
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: spire
spec:
  replicas: 1
  serviceName: spire-server
  selector:
    matchLabels: { app: spire-server }
  template:
    metadata:
      labels: { app: spire-server }
    spec:
      serviceAccountName: spire-server
      automountServiceAccountToken: false
      containers:
        - name: spire-server
          image: ghcr.io/spiffe/spire-server:1.11.2
          args: ["-config", "/run/spire/conf/server.cfg"]
          ports:
            - containerPort: 8081
          volumeMounts:
            - name: conf
              mountPath: /run/spire/conf
              readOnly: true
            - name: upstream-ca
              mountPath: /run/spire/secret
              readOnly: true
            - name: data
              mountPath: /run/spire/data
      volumes:
        - name: conf
          configMap: { name: spire-server-config }
        - name: upstream-ca
          secret: { secretName: spire-upstream-ca }
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: spire
spec:
  type: NodePort
  selector: { app: spire-server }
  ports:
    - name: grpc
      port: 8081
      targetPort: 8081
      nodePort: 30081
```

- [ ] **Step 3: Write `cluster/spire/firewall.sh`** (restrict the NodePort to the tailnet)

```bash
#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Restricts the SPIRE NodePort (30081) to the Tailscale
# interface, so the identity-control-plane listener is not exposed on other node
# interfaces. This is defense in depth; the pinned bundle + join token + server cert
# chain are the actual authentication. mangle/PREROUTING runs before kube-proxy's
# nat DNAT, so the drop applies to the original :30081 dest before it is rewritten.
set -euo pipefail
IFACE="${TAILSCALE_IFACE:-tailscale0}"
ip link show "$IFACE" >/dev/null 2>&1 || { echo "no $IFACE interface on this host" >&2; exit 1; }
if sudo iptables -t mangle -C PREROUTING -p tcp --dport 30081 ! -i "$IFACE" -j DROP 2>/dev/null; then
  echo "spire nodeport firewall already present"
else
  sudo iptables -t mangle -A PREROUTING -p tcp --dport 30081 ! -i "$IFACE" -j DROP
  echo "spire nodeport restricted to $IFACE"
fi
sudo iptables -t mangle -L PREROUTING -n | grep 30081
```

- [ ] **Step 4: Mechanical verification**

Run (host):
```bash
cd demos/spiffe-cross-boundary
bash -n cluster/spire/firewall.sh && shellcheck cluster/spire/firewall.sh
# YAML validity (needs a cluster context; or use a local yaml linter):
python3 -c "import yaml,sys; list(yaml.safe_load_all(open('cluster/spire/spire-server.yaml')))" && echo "yaml ok"
```
Expected: no shellcheck errors; `yaml ok`.

- [ ] **Step 5: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/spire
git commit -m "spire-rearch: in-cluster SPIRE server config, manifests, nodeport firewall"
```

### Task 3: Write the deploy script and stand the server up

**Files:**
- Create: `demos/spiffe-cross-boundary/cluster/spire/apply.sh`

**Interfaces:**
- Consumes: `~/linkerd-certs/{ca.crt,ca.key}` (already on the cluster VM); `cluster/spire/{server.cfg,spire-server.yaml,firewall.sh}`.
- Produces: a running `spire-server-0` pod reachable at `100.126.75.18:30081`. Later steps (Task 4) exec into it.

- [ ] **Step 1: Write `cluster/spire/apply.sh`** (Secret + ConfigMap from files, apply, wait, firewall)

```bash
#!/usr/bin/env bash
# Runs INSIDE the cluster VM. Deploys the in-cluster SPIRE server: the Linkerd root
# (ca.crt+ca.key) as a read-only Secret, server.cfg as a ConfigMap, the StatefulSet +
# NodePort Service, and the tailnet firewall on the NodePort.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
CERTS="${HOME}/linkerd-certs"
[ -f "$CERTS/ca.key" ] || { echo "missing $CERTS/ca.key (run cluster/gen-certs.sh)" >&2; exit 1; }

kubectl apply -f "$HERE/spire-server.yaml"     # creates ns/spire, SA, StatefulSet, Service
kubectl -n spire create secret generic spire-upstream-ca \
  --from-file=ca.crt="$CERTS/ca.crt" --from-file=ca.key="$CERTS/ca.key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n spire create configmap spire-server-config \
  --from-file=server.cfg="$HERE/server.cfg" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n spire rollout status statefulset/spire-server --timeout=120s

bash "$HERE/firewall.sh"
echo "spire server ready; NodePort 30081 (tailnet only)"
```

- [ ] **Step 2: Deploy from the host**

Copy the repo into the cluster guest (see "Deploying code to a VM"), then run (cluster VM):
```bash
cd <demo> && bash cluster/spire/apply.sh
```
Expected: `statefulset "spire-server" successfully rolled out`; the firewall line prints the `30081 … DROP` rule; `spire server ready`.

- [ ] **Step 3: Verify the server is healthy and reachable from the edge**

Run (cluster VM):
```bash
kubectl -n spire get pods
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server healthcheck
```
Expected: `spire-server-0` `Running`; `Server is healthy.`

Run (edge VM) — TCP reachability of the NodePort over Tailscale:
```bash
timeout 4 bash -c 'cat < /dev/null > /dev/tcp/100.126.75.18/30081' && echo "edge can reach spire :30081" || echo "UNREACHABLE"
```
Expected: `edge can reach spire :30081`.

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/spire/apply.sh
git commit -m "spire-rearch: deploy in-cluster SPIRE server (Secret, ConfigMap, StatefulSet, firewall)"
```

---

## Phase 2 — Registration, bundle, and enrollment token

### Task 4: Register the workload + export bootstrap material

**Files:**
- Modify: `demos/spiffe-cross-boundary/cluster/spire/apply.sh` (append a registration section)

**Interfaces:**
- Produces: (a) a SPIRE registration entry for `…/store/042/inventory-sync` with selectors `unix:uid:2102` + `unix:path:/opt/linkerd-proxy/linkerd-proxy`, parented on `…/store/042/agent`; (b) the trust **bundle** at `/tmp/spire-bundle.pem` on the cluster VM; (c) a one-time **join token**. Consumed by Task 5 (the edge agent).

- [ ] **Step 1: Append the registration block to `cluster/spire/apply.sh`**

Add before the final `echo`:
```bash
SP="kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server"
AGENT="spiffe://root.linkerd.cluster.local/store/042/agent"
WL="spiffe://root.linkerd.cluster.local/store/042/inventory-sync"

if $SP entry show -spiffeID "$WL" 2>/dev/null | grep -q "$WL"; then
  echo "entry exists"
else
  $SP entry create -parentID "$AGENT" -spiffeID "$WL" \
    -selector unix:uid:2102 \
    -selector unix:path:/opt/linkerd-proxy/linkerd-proxy
fi

$SP bundle show > "$HOME/spire-bundle.pem"
echo "bundle -> $HOME/spire-bundle.pem ($(grep -c CERTIFICATE "$HOME/spire-bundle.pem") cert(s))"
echo "join token:"
$SP token generate -spiffeID "$AGENT"
```

- [ ] **Step 2: Run it and capture the token**

Run (cluster VM):
```bash
cd <demo> && bash cluster/spire/apply.sh
```
Expected: an entry with `SPIFFE ID … /store/042/inventory-sync` and **both** `Selector: unix:uid:2102` and `Selector: unix:path:/opt/linkerd-proxy/linkerd-proxy`; `bundle -> …/spire-bundle.pem (1 cert(s))`; a `Token: <uuid>` line. **Record the token** for Task 5.

- [ ] **Step 3: Verify the entry selectors explicitly**

Run (cluster VM):
```bash
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://root.linkerd.cluster.local/store/042/inventory-sync | grep -E 'Selector'
```
Expected: two lines — `unix:uid:2102` and `unix:path:/opt/linkerd-proxy/linkerd-proxy`.

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/cluster/spire/apply.sh
git commit -m "spire-rearch: register store/042/inventory-sync (uid+path), export bundle + join token"
```

---

## Phase 3 — Edge agent-only

### Task 5: Agent-only edge (remote server, pinned bootstrap, path discovery)

**Files:**
- Modify: `demos/spiffe-cross-boundary/edge/spire/agent.cfg`
- Delete: `demos/spiffe-cross-boundary/edge/spire/server.cfg`
- Rename+rewrite: `edge/install-spire.sh` → `edge/install-spire-agent.sh`
- Delete: `demos/spiffe-cross-boundary/edge/register-workload.sh`

**Interfaces:**
- Consumes: the bundle (`/tmp/spire-bundle.pem` from the cluster) + the join token from Task 4; `CLUSTER_NODE_ADDR`, `SPIRE_SERVER_PORT` from config.
- Produces: a running SPIRE **agent** attested as `…/store/042/agent`, serving the Workload API at `/tmp/spire-agent/public/api.sock`. No server, no `ca.key` on the edge.

- [ ] **Step 1: Rewrite `edge/spire/agent.cfg`** (remote server, pinned bundle, discover_workload_path)

```hcl
agent {
    data_dir = "/opt/spire/data/agent"
    log_level = "INFO"
    trust_domain = "root.linkerd.cluster.local"
    server_address = "__SERVER_ADDR__"
    server_port = __SERVER_PORT__
    trust_bundle_path = "/opt/spire/certs/bundle.pem"
}
plugins {
    KeyManager "disk" { plugin_data { directory = "/opt/spire/data/agent" } }
    NodeAttestor "join_token" { plugin_data {} }
    WorkloadAttestor "unix" {
        plugin_data {
            discover_workload_path = true
            workload_size_limit = -1
        }
    }
}
```
`__SERVER_ADDR__` / `__SERVER_PORT__` are substituted by the install script (bash param expansion; no `sed`).

- [ ] **Step 2: Delete the edge server config and the old registration script**

```bash
git rm demos/spiffe-cross-boundary/edge/spire/server.cfg
git rm demos/spiffe-cross-boundary/edge/register-workload.sh
```

- [ ] **Step 3: Write `edge/install-spire-agent.sh`** (agent-only)

```bash
#!/usr/bin/env bash
# Runs INSIDE the edge VM. Installs + starts the SPIRE AGENT only (no server, no root
# key). Requires the trust bundle at /opt/spire/certs/bundle.pem and a one-time join
# token (arg 1 or $SPIRE_JOIN_TOKEN), both produced by cluster/spire/apply.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../../.." && pwd)/lib/common.sh"; load_config "$(cd "$HERE/.." && pwd)"
ARCH="$(detect_arch)"
TOKEN="${1:-${SPIRE_JOIN_TOKEN:-}}"
[ -n "$TOKEN" ] || die "usage: install-spire-agent.sh <join-token>   (from cluster/spire/apply.sh)"
[ -f /opt/spire/certs/bundle.pem ] || die "copy the SPIRE bundle to /opt/spire/certs/bundle.pem first"
[ ! -e /opt/spire/certs/ca.key ] || die "refuse to run: ca.key must not be on the edge (remove it)"

if [ ! -x /opt/spire/bin/spire-agent ]; then
  VER="$(curl -sSf https://api.github.com/repos/spiffe/spire/releases/latest | jq -r .tag_name | tr -d v)"
  [ -n "$VER" ] && [ "$VER" != "null" ] || die "could not resolve SPIRE latest release"
  curl -sSLf "https://github.com/spiffe/spire/releases/download/v${VER}/spire-${VER}-linux-${ARCH}-musl.tar.gz" -o /tmp/spire.tgz
  sudo mkdir -p /opt/spire/bin /opt/spire/data/agent
  tar -xzf /tmp/spire.tgz -C /tmp
  sudo cp "/tmp/spire-${VER}/bin/spire-agent" /opt/spire/bin/
fi

# Render agent.cfg with the cluster server address/port (no sed; bash param expansion).
render() { while IFS= read -r line; do line="${line/__SERVER_ADDR__/$CLUSTER_NODE_ADDR}"; echo "${line/__SERVER_PORT__/$SPIRE_SERVER_PORT}"; done < "$HERE/spire/agent.cfg"; }
render | sudo tee /opt/spire/agent.cfg >/dev/null

sudo pkill -f 'spire-agent run' 2>/dev/null || true
# shellcheck disable=SC2024
sudo setsid /opt/spire/bin/spire-agent run -config /opt/spire/agent.cfg -joinToken "$TOKEN" \
  >/tmp/spire-agent.log 2>&1 </dev/null &
sleep 4
sudo /opt/spire/bin/spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
```

- [ ] **Step 4: Add config vars** — in `config.example.env` add:
```bash
SPIRE_SERVER_PORT=30081
SPIRE_AGENT_SPIFFE_ID=spiffe://root.linkerd.cluster.local/store/042/agent
PROXY_UID=2102
APP_UID=1000
```
And on the edge's `config.local.env` ensure `CLUSTER_NODE_ADDR=100.126.75.18` and add `SPIRE_SERVER_PORT=30081`.

- [ ] **Step 5: Deploy + run on the edge**

Copy the repo into the edge guest. Copy the bundle from the cluster to the edge:
```bash
# host: pull bundle from cluster, push to edge
ssh orion-m1.local 'export PATH="/opt/homebrew/bin:$PATH"; limactl shell linkerd-cluster -- cat ~/spire-bundle.pem' > /tmp/spire-bundle.pem
limactl shell linkerd-edge -- sudo mkdir -p /opt/spire/certs
cat /tmp/spire-bundle.pem | limactl shell linkerd-edge -- sudo tee /opt/spire/certs/bundle.pem >/dev/null
```
Then run (edge VM), passing the token from Task 4:
```bash
cd <demo> && bash edge/install-spire-agent.sh <JOIN_TOKEN>
```
Expected: `Agent is healthy.`

- [ ] **Step 6: Verify agent attested + no root key + no server**

Run (edge VM):
```bash
grep -aE 'node attestation|Node attestation|SVID updated|Renewing' /tmp/spire-agent.log | tail -2 | sed 's/[[:cntrl:]]//g'
test -e /opt/spire/certs/ca.key && echo "BAD: ca.key present" || echo "ok: no ca.key on edge"
pgrep -af 'spire-server run' || echo "ok: no spire-server on edge"
```
Expected: an attestation / SVID line in the log; `ok: no ca.key on edge`; `ok: no spire-server on edge`.

- [ ] **Step 7: Commit**

```bash
git add demos/spiffe-cross-boundary/edge demos/spiffe-cross-boundary/config.example.env
git commit -m "spire-rearch: agent-only edge (remote server, pinned bundle, path discovery); drop edge server + root key"
```

---

## Phase 4 — Non-root proxy + app-scoped iptables

### Task 6: Run the proxy as uid 2102; redirect only the app's uid

**Files:**
- Modify: `demos/spiffe-cross-boundary/edge/run-proxy.sh`
- Modify: `demos/spiffe-cross-boundary/edge/iptables.sh`

**Interfaces:**
- Consumes: the agent socket (Task 5); `EDGE_SPIFFE_ID`/`EDGE_SERVER_NAME` (Task 7 sets the new values, but the proxy env reads them from config — run this task's verification after Task 7 sets the identity, or temporarily export the new values; see Step 5).
- Produces: a `linkerd2-proxy` process running as **uid 2102**, certified for the store SVID; iptables that redirects only uid 1000.

- [ ] **Step 1: Rewrite `edge/iptables.sh`** (app-scoped OUTPUT redirect only)

```bash
#!/usr/bin/env bash
# Runs INSIDE the edge VM. App-scoped redirect: only the store-pos app's uid (1000)
# has its outbound TCP sent to the Linkerd proxy (outbound port 4140). Everything else
# on the host — the SPIRE agent, DNS, SSH, the proxy's own egress — is untouched.
# Invariant:  app uid 1000 -> proxy ;  all other host traffic -> normal networking.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
APP_UID="${APP_UID:-1000}"
PROXY_OUTBOUND_PORT=4140

if sudo iptables -t nat -n -L PROXY_APP_OUTPUT >/dev/null 2>&1; then echo "iptables already configured"; exit 0; fi
sudo iptables -t nat -N PROXY_APP_OUTPUT
sudo iptables -t nat -A PROXY_APP_OUTPUT -o lo -j RETURN
sudo iptables -t nat -A PROXY_APP_OUTPUT -m owner --uid-owner "$APP_UID" -p tcp -j REDIRECT --to-port "$PROXY_OUTBOUND_PORT"
sudo iptables -t nat -A OUTPUT -m owner --uid-owner "$APP_UID" -p tcp -j PROXY_APP_OUTPUT
sudo iptables-save -t nat | grep -E 'PROXY_APP_OUTPUT|--uid-owner'
```

- [ ] **Step 2: Rewrite the launch portion of `edge/run-proxy.sh`** (run as uid 2102)

Add near the top, after `load_config`, a user-creation guard, and replace the launch (lines 19–29) so the proxy runs as `linkerd-proxy` (uid 2102) via `setpriv` (which, unlike `sudo`, does not scrub the exported env; `sudo -E` already preserves this env on this host, and `setpriv` inherits it):

```bash
# ensure the dedicated non-root proxy user exists (idempotent)
id -u linkerd-proxy >/dev/null 2>&1 || sudo useradd -r -u "${PROXY_UID:-2102}" -s /usr/sbin/nologin linkerd-proxy

sudo pkill -f '/opt/linkerd-proxy/linkerd-proxy' 2>/dev/null || true
sudo rm -f /tmp/linkerd-proxy.log
# shellcheck disable=SC2024
sudo -E setsid setpriv --reuid="${PROXY_UID:-2102}" --regid="${PROXY_UID:-2102}" --clear-groups \
  /opt/linkerd-proxy/linkerd-proxy >/tmp/linkerd-proxy.log 2>&1 </dev/null &
sleep 5
if grep -Eqi 'certified identity|obtained.*identity|SVID' /tmp/linkerd-proxy.log; then
  echo "proxy has identity (uid $(id -u linkerd-proxy))"
else
  echo "proxy identity not confirmed — inspect /tmp/linkerd-proxy.log:" >&2
  tail -n 40 /tmp/linkerd-proxy.log >&2; exit 1
fi
```

- [ ] **Step 3: Mechanical check + deploy**

Run (host): `cd demos/spiffe-cross-boundary && shellcheck edge/iptables.sh edge/run-proxy.sh`. Expected: clean. Then copy the repo to the edge guest.

- [ ] **Step 4: Apply iptables and (re)start the proxy**

Run (edge VM):
```bash
cd <demo>
bash edge/iptables.sh
bash edge/extract-proxy.sh   # ensures /opt/linkerd-proxy/linkerd-proxy exists (unchanged script)
bash edge/run-proxy.sh
```
Expected: iptables shows the `PROXY_APP_OUTPUT` chain + `--uid-owner 1000`; `proxy has identity (uid 2102)`.

- [ ] **Step 5: Verify the proxy runs non-root and is certified for the new SVID**

(Run after Task 7 has set the new identity in config, or export `EDGE_SPIFFE_ID=spiffe://root.linkerd.cluster.local/store/042/inventory-sync` before `run-proxy.sh`.)

Run (edge VM):
```bash
ps -o uid,cmd -C linkerd-proxy | grep -v UID           # uid column must be 2102
grep -a 'Certified identity' /tmp/linkerd-proxy.log | tail -1 | sed 's/[[:cntrl:]]//g'
```
Expected: proxy uid `2102`; `Certified identity id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`.

- [ ] **Step 6: Verify least-privilege isolation (an unrelated uid-0 process gets no SVID)**

Run (edge VM) — ask the Workload API as root; it must not receive the store SVID:
```bash
sudo /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /tmp/spire-agent/public/api.sock 2>&1 | grep -Eic 'inventory-sync' \
  && echo "BAD: root got the SVID" || echo "ok: uid-0 caller does not match uid:2102+path -> no store SVID"
```
Expected: `ok: uid-0 caller does not match …`. (This is least-privilege isolation between ordinary processes — **not** a defense against host-root; a root attacker could run the permitted binary as uid 2102.)

- [ ] **Step 7: Verify no setup-ordering dependency (agent reconnects after iptables)**

Run (edge VM):
```bash
sudo pkill -f 'spire-agent run'; sleep 1
cd <demo> && bash edge/install-spire-agent.sh "$(cat /tmp/last-join-token 2>/dev/null || echo NEED_NEW_TOKEN)"
sudo /opt/spire/bin/spire-agent healthcheck -socketPath /tmp/spire-agent/public/api.sock
```
(If the join token is single-use and already consumed, mint a fresh one via `cluster/spire/apply.sh` first.) Expected: `Agent is healthy.` — the agent reconnects with iptables already installed, proving the app-scoped redirect never captured agent traffic.

- [ ] **Step 8: Commit**

```bash
git add demos/spiffe-cross-boundary/edge/run-proxy.sh demos/spiffe-cross-boundary/edge/iptables.sh
git commit -m "spire-rearch: proxy as non-root uid 2102; app-scoped iptables (only uid 1000)"
```

---

## Phase 5 — Identity, policy, and app updates

### Task 7: Switch the workload identity to the descriptive path end-to-end

**Files:**
- Modify: `demos/spiffe-cross-boundary/config.example.env`
- Modify: `demos/spiffe-cross-boundary/cluster/retail/store-pos.yaml`
- Modify: `demos/spiffe-cross-boundary/cluster/retail/authz.yaml`
- Modify: `demos/spiffe-cross-boundary/retail-cloud/server.js`

**Interfaces:**
- Consumes: the SPIRE entry from Task 4 (issues the new SVID). Produces: the cloud authorizes the new identity; the dashboard reports the store again.

- [ ] **Step 1: `config.example.env`** — change the two identity lines:
  - `EDGE_SPIFFE_ID=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`
  - `EDGE_SERVER_NAME=inventory-sync.cluster.local`
  (Keep `EDGE_WORKLOAD_NAME=store-pos` — that is the ExternalWorkload **object** name used in the proxy's `external_workload` ref, independent of the SVID.) Update the edge & cluster `config.local.env` to match.

- [ ] **Step 2: `cluster/retail/store-pos.yaml`** — set the identity + serverName:
  - `identity: "spiffe://root.linkerd.cluster.local/store/042/inventory-sync"`
  - `serverName: "inventory-sync.cluster.local"`

- [ ] **Step 3: `cluster/retail/authz.yaml`** — set the allowed identity:
  - under `MeshTLSAuthentication` → `identities: - "spiffe://root.linkerd.cluster.local/store/042/inventory-sync"`

- [ ] **Step 4: `retail-cloud/server.js`** — change the constant (line 14):
  - `const STORE_ID = 'spiffe://root.linkerd.cluster.local/store/042/inventory-sync';`

- [ ] **Step 5: Re-apply cluster + restart the proxy**

Copy the repo to both guests. Run (cluster VM): `cd <demo> && bash cluster/retail/apply.sh`. Run (edge VM): `cd <demo> && bash edge/run-proxy.sh` (picks up the new `EDGE_SPIFFE_ID`) and `bash store-pos/run-store-pos.sh`.

- [ ] **Step 6: Verify the end-to-end demo (functional)**

Run (dashboard, from host): poll for reporting:
```bash
for i in $(seq 1 10); do curl -s -m5 http://100.126.75.18:30080/api/data | grep -o '"reporting":[a-z]*'; sleep 3; done
```
Expected: flips to `"reporting":true`.

Run (cluster VM) — identity on the wire + the Void moment:
```bash
export PATH=$HOME/.linkerd2/bin:$PATH
timeout 15 linkerd -n mixed-env viz tap deploy/retail-cloud 2>/dev/null | grep -m1 client_id | sed 's/[[:cntrl:]]//g'
curl -s -m5 -X POST -H 'content-type: application/json' -d '{"allow":false}' http://100.126.75.18:30080/api/policy
sleep 3; curl -s -m5 http://100.126.75.18:30080/api/data | grep -o '"voided":[a-z]*'
curl -s -m5 -X POST -H 'content-type: application/json' -d '{"allow":true}' http://100.126.75.18:30080/api/policy
```
Expected: tap shows `client_id=spiffe://root.linkerd.cluster.local/store/042/inventory-sync`; after void, `"voided":true` (store pushes now 403); restore returns to normal.

- [ ] **Step 7: Commit**

```bash
git add demos/spiffe-cross-boundary/config.example.env demos/spiffe-cross-boundary/cluster/retail demos/spiffe-cross-boundary/retail-cloud/server.js
git commit -m "spire-rearch: workload identity -> store/042/inventory-sync (config, ExternalWorkload, authz, app)"
```

---

## Phase 6 — Dashboard enrollment panel

### Task 8: Show enrollment vs workload identity ("held by the local Linkerd proxy")

**Files:**
- Modify: `demos/spiffe-cross-boundary/retail-cloud/server.js` (`/api/data` payload)
- Modify: `demos/spiffe-cross-boundary/retail-cloud/index.html` (render the panel)

**Interfaces:**
- Consumes: `/api/data`. Produces: a per-store block separating node enrollment (one-time token; production = device identity) from the workload identity (held by the proxy) + mTLS + cloud service.

- [ ] **Step 1: `retail-cloud/server.js`** — in the `/api/data` response object (the `return json(res, {…})` near line 70), add an `enrollment` block:
```js
      enrollment: {
        method: 'one-time demo join token',
        production: 'device-bound identity (TPM or enterprise PKI)',
        heldBy: 'local Linkerd proxy',
      },
```

- [ ] **Step 2: `retail-cloud/index.html`** — add a panel in the custody/rail area that reads `d.enrollment` and `d.identities.store`, rendering:
```
Store 042
  Node enrollment    ✓ Enrolled with a one-time demo token
                       Production: device-bound identity (TPM or enterprise PKI)
  Workload identity  ✓ spiffe://…/store/042/inventory-sync
                       held by the local Linkerd proxy
  Connection         ✓ mTLS authenticated
  Cloud service      ✓ inventory ingest
```
Use the existing RetailCloud CSS classes (`.custody`, `.kicker`, `.id mono`, `.seal-pill`). Populate it in the existing `setState`/`refresh` flow from `d.enrollment` + `d.identities.store`. **All UI/UX work goes through the `/frontend-design` plugin** to keep the RetailCloud aesthetic — build this panel via that skill, not ad hoc.

- [ ] **Step 3: Deploy + verify**

Re-run `cluster/retail/apply.sh` (ships the app via ConfigMap). Verify:
```bash
curl -s -m5 http://100.126.75.18:30080/api/data | python3 -m json.tool | grep -A4 enrollment
```
Expected: the `enrollment` block is present with `heldBy: local Linkerd proxy`. Load the dashboard in a browser (or Playwright screenshot) and confirm the panel shows enrollment separately from the proxy-held workload identity.

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/retail-cloud/server.js demos/spiffe-cross-boundary/retail-cloud/index.html
git commit -m "spire-rearch: dashboard enrollment-vs-workload panel (identity held by the local proxy)"
```

---

## Phase 7 — Documentation

### Task 9: Rewrite the manual + README SPIRE sections

**Files:**
- Modify: `demos/spiffe-cross-boundary/MANUAL.md`
- Modify: `demos/spiffe-cross-boundary/README.md`

**Interfaces:** Produces docs that match the built system (server in cluster, agent on edge, no `ca.key` on edge, non-root proxy, app-scoped iptables, new SVID). The site regenerates these via `site/scripts/sync-docs.mjs`.

- [ ] **Step 1: `MANUAL.md` Part 1** — keep the root + issuer generation, but stop implying the root key goes to the edge. Update the bullet that currently reads "The root key (`ca.key`) never leaves this host" to state it stays in the cluster and is later mounted into the SPIRE server Secret.

- [ ] **Step 2: `MANUAL.md` Part 3** — replace "3a Give SPIRE a dedicated intermediate / 3b server on the edge / 3d start server+agent / 3e register" with the new topology: **3a Deploy the SPIRE server in the cluster** (Secret + ConfigMap + StatefulSet + NodePort + tailnet firewall; `cluster/spire/apply.sh`); **3b Enroll the edge agent** (copy the bundle; `install-spire-agent.sh <token>`; pinned bootstrap, `discover_workload_path`); **3c Register the workload** (on the cluster server: `entry create … -selector unix:uid:2102 -selector unix:path:…`). Show the exact `server.cfg`/`agent.cfg` from Tasks 2/5 and the `entry create` from Task 4.

- [ ] **Step 3: `MANUAL.md` Part 4** — the proxy runs as **uid 2102** (`setpriv`), attested by uid+path; iptables redirects **only** the app's uid (1000). Replace the "uid 0 exempt, app must be non-root" consequence note with the app-scoped invariant. Add the honest boundary: uid+path is least-privilege isolation, not defense against host-root.

- [ ] **Step 4: `README.md`** — "What runs where": SPIRE **server** moves to the cluster column, **agent** on the store column; the "Copy the … to the store" step copies only the **bundle** (`bundle.pem`) + the public `ca.crt`, never `ca.key`; update the build sequence (`cluster/spire/apply.sh`; `install-spire-agent.sh`).

- [ ] **Step 5: Verify docs build + no stale references**

```bash
cd demos/spiffe-cross-boundary
grep -rnE 'ca\.key.*edge|cp ca\.crt ca\.key|register-workload\.sh|unix:uid:0' MANUAL.md README.md && echo "STALE REFS ABOVE" || echo "no stale refs"
cd ../../site && npm run build 2>&1 | grep -E 'sync-docs|error|Complete'
```
Expected: `no stale refs`; site build `Complete!` (sync regenerates `manual.md`).

- [ ] **Step 6: Commit**

```bash
git add demos/spiffe-cross-boundary/MANUAL.md demos/spiffe-cross-boundary/README.md
git commit -m "spire-rearch: rewrite manual + README for server-in-cluster / agent-on-edge"
```

### Task 10: Update PRODUCTION-NOTES, tutorial, topology diagram

**Files:**
- Modify: `demos/spiffe-cross-boundary/PRODUCTION-NOTES.md`
- Modify: `demos/spiffe-cross-boundary/retail-cloud/tutorial.html`

**Interfaces:** Produces an honest, current disclaimer + a correct topology diagram.

- [ ] **Step 1: `PRODUCTION-NOTES.md`** — move to "resolved" (with the new topology): the root-key-on-edge finding; the `unix:uid:0` finding (now uid+path, re-scoped as least-privilege — add the **Edge host trust assumption** limitation verbatim from the design's Security-boundaries section); the TOFU-bootstrap finding (now pinned bundle). Correct the join-token entry to "a legitimate one-time enrollment mechanism; production binds enrollment to a device identity". Add the **Demo PKI simplification** limitation (root key now in a k8s Secret, not HSM/offline). Keep documented: single-replica sqlite, in-cluster Secret root-key storage, the Void-button RBAC.

- [ ] **Step 2: `retail-cloud/tutorial.html`** — update the Learn/Build wording and the Cytoscape topology: the store node shows **SPIRE agent** (not "SPIRE server + agent"); add a **SPIRE server** node in the cloud cluster box; the "trust" edge now runs cloud→edge (server→agent) rather than anchor→edge-SPIRE. Keep the RetailCloud aesthetic — **do UI changes via `/frontend-design`.**

- [ ] **Step 3: Verify**

```bash
cd demos/spiffe-cross-boundary
grep -nE 'SPIRE (server \+ agent|server\+agent) .*edge|root key.*edge' retail-cloud/tutorial.html && echo "STALE" || echo "topology text updated"
cd ../../site && npm run build 2>&1 | grep -E 'production-notes|Complete'
```
Expected: `topology text updated`; site build `Complete!` (production-notes page regenerates).

- [ ] **Step 4: Commit**

```bash
git add demos/spiffe-cross-boundary/PRODUCTION-NOTES.md demos/spiffe-cross-boundary/retail-cloud/tutorial.html
git commit -m "spire-rearch: PRODUCTION-NOTES resolved findings + limitations; tutorial topology"
```

---

## Phase 8 — Final verification + PR

### Task 11: Full end-to-end verification and PR

**Files:** none (verification + PR).

**Interfaces:** Consumes everything. Produces the merged-ready branch.

- [ ] **Step 1: Run the full verification matrix** (all on the live demo)

| Check | Command (VM) | Expected |
|---|---|---|
| No root key on edge | edge: `test -e /opt/spire/certs/ca.key && echo BAD || echo ok` | `ok` |
| No SPIRE server on edge | edge: `pgrep -af 'spire-server run' \|\| echo ok` | `ok` |
| Server in cluster healthy | cluster: `kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server healthcheck` | `Server is healthy.` |
| NodePort tailnet-restricted | cluster: `sudo iptables -t mangle -S PREROUTING \| grep 30081` | shows `! -i tailscale0 -j DROP` |
| Both selectors on the entry | cluster: `kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry show -spiffeID .../store/042/inventory-sync \| grep Selector` | `unix:uid:2102` + `unix:path:…` |
| Proxy runs non-root | edge: `ps -o uid,cmd -C linkerd-proxy` | uid `2102` |
| Proxy certified new SVID | edge: `grep 'Certified identity' /tmp/linkerd-proxy.log \| tail -1` | `…/store/042/inventory-sync` |
| uid-0 gets no SVID | edge: Task 6 Step 6 command | `ok: uid-0 caller does not match …` |
| Agent reconnects post-iptables | edge: Task 6 Step 7 | `Agent is healthy.` |
| Store reports 200 | host: `curl …/api/data \| grep reporting` | `"reporting":true` |
| Void → 403 | host: Task 7 Step 6 void/restore | `"voided":true` then normal |
| tap client_id | cluster: `linkerd -n mixed-env viz tap deploy/retail-cloud \| grep client_id` | `…/store/042/inventory-sync` |
| Dashboard panel | host: `curl …/api/data \| grep -A4 enrollment` | `heldBy: local Linkerd proxy` |
| Site builds | host: `cd site && npm run build` | `Complete!` |

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin <branch>
gh pr create --base main --title "SPIRE: server in cluster, agent-only edge (root key off the edge)" --body-file <(printf '%s\n' "Implements docs/superpowers/specs/2026-08-08-spire-trust-architecture-design.md (two review rounds). Root CA key no longer on the edge; workload attestation hardened to uid+path (least-privilege, not host-root defense); pinned agent bootstrap. Verified end-to-end on the live two-VM demo. Operational simplifications (single-replica sqlite SPIRE, join-token enrollment, in-cluster Secret root-key storage, Void-button RBAC) remain documented in PRODUCTION-NOTES — not production-ready.")
```

- [ ] **Step 3: Report the verification matrix results** in the PR (which checks passed, with the actual output), and link the design record.

---

## Self-review (run against the design)

- **Spec coverage:** server-in-cluster StatefulSet + Secret + ConfigMap + SA(automount off) + NodePort (Task 2/3); tailnet firewall (Task 2/3); registration/bundle/token via kubectl exec (Task 4); agent-only + pinned bootstrap + `discover_workload_path` (Task 5); non-root proxy uid 2102 + uid/path selectors (Task 4/6); app-scoped iptables (Task 6); descriptive SVID everywhere (Task 7); dashboard panel "held by the local proxy" (Task 8); docs incl. Security-boundaries limitations + corrected join-token framing (Task 9/10); every design verification item appears in Task 11's matrix. **Covered.**
- **Honesty:** simplifications kept + documented; UID+path stated as least-privilege, not host-root defense; no production-readiness claims. **Consistent with the design.**
- **Consistency:** SVID `…/store/042/inventory-sync`, agent `…/store/042/agent`, uid 2102, app uid 1000, NodePort 30081, bundle `/opt/spire/certs/bundle.pem`, selectors `unix:uid:2102` + `unix:path:/opt/linkerd-proxy/linkerd-proxy` used identically across tasks.
