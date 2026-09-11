# Task 11: W admission probes and their discovery

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** The admission probes of design § 3. Each reaches exactly one webhook by the webhook configurations' rules (source notes § 6):
- **(a)** a Pod `inject-probe-<tick>` in the injected `lab` namespace reaches the proxy-injector;
- **(b)** an invalid `policy.linkerd.io` resource `policy-invalid-<tick>` reaches the policy validator;
- **(c)** an invalid ServiceProfile `serviceprofile-invalid-<tick>` reaches the sp-validator;
- **(d)** valid versions of (b) and (c), `policy-valid-<tick>` and `serviceprofile-valid-<tick>`.

Every attempt creates a fresh object with a unique name, so the API server calls admission each time. Each writes `admission/<phase>/<object>.request.yaml`, `<object>.response.txt` (the exact API response, with exit status) and `<object>.observed.yaml` (the resulting object, or the recorded NotFound), and every object that got created is deleted once observed.

A discovery run picks the invalid resources. A candidate qualifies only if the healthy validator rejects it **with its own message** (`admission webhook "<webhook name>" denied the request`). A CRD-schema rejection doesn't count, because the API server would reject it with or without the webhook. Each candidate has an inert valid twin: an authentication resource no policy references, or a ServiceProfile whose name matches no Service. So probe (d) never changes lab traffic.

`admission_proof_check` is the pure rule that proves a probe set exercised all three webhooks. It gives W's validity rule its `admission-baseline.txt` (design § 3: "If not, the run is invalid"), and Task 12 reuses it after recovery.

**Files:**
- Create: `demos/cert-hygiene/lab/admission/inject-probe.yaml`
- Create: `demos/cert-hygiene/lab/admission/candidates/policy-{1,2,3}-{invalid,valid}.yaml`, `demos/cert-hygiene/lab/admission/candidates/sp-{1,2,3}-{invalid,valid}.yaml`
- Create (chosen by discovery, Step 9): `demos/cert-hygiene/lab/admission/policy-invalid.yaml`, `policy-valid.yaml`, `serviceprofile-invalid.yaml`, `serviceprofile-valid.yaml`
- Create: `demos/cert-hygiene/lab/admission.sh`, `demos/cert-hygiene/lab/discover-admission.sh`
- Create: `demos/cert-hygiene/lab/lib-evidence-scenarios.sh`, `demos/cert-hygiene/lab/tests/test-scenarios.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence.sh` (source the new file), `demos/cert-hygiene/config.example.env` (webhook names), `demos/cert-hygiene/Justfile` (`discover-admission`)
- Create (discovery, committed): `demos/cert-hygiene/runs/_discovery/<stamp>-admission/` with `FINDINGS.md`

**Interfaces:**
- Consumes: `capture`, `mark` (collector), `LAB_NS`, `IMAGE_BUSYBOX`, Task 1's discovered webhook names (`runs/_discovery/<stamp>-webhooks/FINDINGS.md`).
- Produces:
  - Templates in `lab/admission/*.yaml` with exactly the placeholders `${NAME}`, `${LAB_NS}` and `${IMAGE_BUSYBOX}`.
  - `admission_render TEMPLATE NAME` (TEMPLATE is relative to `lab/admission/`, without `.yaml`) → the manifest on stdout.
  - `admission_attempt PHASE OBJECT TEMPLATE` → the three files above, plus `<object>.delete.txt` when the object existed.
  - `admission_probes PHASE SUFFIX` → five attempts, objects `inject-probe-SUFFIX`, `policy-invalid-SUFFIX`, `serviceprofile-invalid-SUFFIX`, `policy-valid-SUFFIX`, `serviceprofile-valid-SUFFIX`, in that order.
  - `admission_proof_check DIR SUFFIX POLICY_WEBHOOK SP_WEBHOOK` (pure) → `ok:`/`fail:` lines; returns 0 only if: the inject probe was created and its observed pod has a `linkerd-proxy` container; both invalid objects were rejected (non-zero exit) with `admission webhook "<their validator>" denied the request`; both valid objects were created (`[exit 0]`).
  - Config: `POLICY_VALIDATOR_WEBHOOK_NAME`, `SP_VALIDATOR_WEBHOOK_NAME`.

- [ ] **Step 1: Failing tests, `demos/cert-hygiene/lab/tests/test-scenarios.sh`**

```bash
#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-scenarios.sh (scenario-specific pure rules).
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/lib-evidence.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---- admission_proof_check ----
PW=linkerd-policy-validator.linkerd.io
SW=linkerd-sp-validator.linkerd.io
proof() { # DIR: a probe set (suffix s1) that proves all three webhooks
  local d="$1"
  mkdir -p "$d"
  printf '$ kubectl create -f x\npod/inject-probe-s1 created\n[exit 0]\n' > "$d/inject-probe-s1.response.txt"
  printf '$ kubectl get\napiVersion: v1\nkind: Pod\nspec:\n  initContainers:\n  - name: linkerd-init\n  - name: linkerd-proxy\n  containers:\n  - name: idle\n[exit 0]\n' > "$d/inject-probe-s1.observed.yaml"
  printf '$ kubectl create\nError from server: admission webhook "%s" denied the request: invalid cidr\n[exit 1]\n' "$PW" > "$d/policy-invalid-s1.response.txt"
  printf '$ kubectl create\nError from server: admission webhook "%s" denied the request: bad ttl\n[exit 1]\n' "$SW" > "$d/serviceprofile-invalid-s1.response.txt"
  printf '$ kubectl create\ncreated\n[exit 0]\n' > "$d/policy-valid-s1.response.txt"
  printf '$ kubectl create\ncreated\n[exit 0]\n' > "$d/serviceprofile-valid-s1.response.txt"
}
proof "$T/a0"
assert_succeeds "a healthy probe set proves all three webhooks" admission_proof_check "$T/a0" s1 "$PW" "$SW"
proof "$T/a1"; printf '$ kubectl get\nkind: Pod\nspec:\n  containers:\n  - name: idle\n[exit 0]\n' > "$T/a1/inject-probe-s1.observed.yaml"
assert_fails "a pod without linkerd-proxy does not prove the injector" admission_proof_check "$T/a1" s1 "$PW" "$SW"
proof "$T/a2"; printf '$ kubectl create\ncreated\n[exit 0]\n' > "$T/a2/policy-invalid-s1.response.txt"
assert_fails "an accepted invalid policy does not prove the validator" admission_proof_check "$T/a2" s1 "$PW" "$SW"
proof "$T/a3"; printf '$ kubectl create\nThe ServiceProfile "x" is invalid: spec.routes[0].condition: Required value\n[exit 1]\n' > "$T/a3/serviceprofile-invalid-s1.response.txt"
assert_fails "a CRD-schema rejection does not prove the sp-validator" admission_proof_check "$T/a3" s1 "$PW" "$SW"
proof "$T/a4"; printf '$ kubectl create\nError from server: admission webhook "%s" denied the request\n[exit 1]\n' "$SW" > "$T/a4/policy-invalid-s1.response.txt"
assert_fails "a rejection by the wrong webhook does not count" admission_proof_check "$T/a4" s1 "$PW" "$SW"
proof "$T/a5"; printf '$ kubectl create\nerror\n[exit 1]\n' > "$T/a5/serviceprofile-valid-s1.response.txt"
assert_fails "a rejected valid ServiceProfile fails the proof" admission_proof_check "$T/a5" s1 "$PW" "$SW"
proof "$T/a6"; rm "$T/a6/policy-valid-s1.response.txt"
assert_fails "a missing attempt fails the proof" admission_proof_check "$T/a6" s1 "$PW" "$SW"

finish test-scenarios
```

Run: `just demo cert-hygiene test`
Expected: `test-scenarios` fails with `admission_proof_check: command not found`.

- [ ] **Step 2: Write `demos/cert-hygiene/lab/lib-evidence-scenarios.sh`**

```bash
#!/usr/bin/env bash
# Scenario-specific pure rules: W's admission proof (and, from later tasks, W's recovery
# branch and manifest redaction, K's remaining validity, S-hard's stage-1 condition).
# No kubectl. Sourced by lab/lib-evidence.sh; do not execute.

_last_line() { tail -n 1 "$1" 2>/dev/null; } # FILE

# admission_proof_check DIR SUFFIX POLICY_WEBHOOK SP_WEBHOOK: did the probe set with this
# SUFFIX exercise all three webhooks (design section 3)? Rejections count only when the
# validator itself denied the request, never a CRD-schema rejection.
admission_proof_check() {
  local d="${1:?}" s="${2:?}" pw="${3:?}" sw="${4:?}" bad=0 f o
  f="$d/inject-probe-$s.response.txt"
  if [ "$(_last_line "$f")" = "[exit 0]" ] && grep -qE 'name: linkerd-proxy$' "$d/inject-probe-$s.observed.yaml" 2>/dev/null; then
    echo "ok: inject-probe-$s was created with a linkerd-proxy container"
  else
    echo "fail: inject-probe-$s was not created with a linkerd-proxy container"; bad=1
  fi
  for o in "policy-invalid-$s:$pw" "serviceprofile-invalid-$s:$sw"; do
    f="$d/${o%%:*}.response.txt"
    if [ -f "$f" ] && [ "$(_last_line "$f")" != "[exit 0]" ] && grep -qF "admission webhook \"${o#*:}\" denied the request" "$f"; then
      echo "ok: ${o%%:*} was denied by ${o#*:}"
    else
      echo "fail: ${o%%:*} was not denied by ${o#*:}"; bad=1
    fi
  done
  for o in "policy-valid-$s" "serviceprofile-valid-$s"; do
    if [ "$(_last_line "$d/$o.response.txt")" = "[exit 0]" ]; then echo "ok: $o was created"
    else echo "fail: $o was not created"; bad=1; fi
  done
  return "$bad"
}
```

Append to the sourcing block at the end of `demos/cert-hygiene/lab/lib-evidence.sh`:

```bash
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-scenarios.sh"
```

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines (`test-control`, `test-evidence`, `test-plan`, `test-rules`, `test-scenarios`).

- [ ] **Step 3: Write `demos/cert-hygiene/lab/admission/inject-probe.yaml`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
  labels:
    app: inject-probe
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
    - name: idle
      image: ${IMAGE_BUSYBOX}
      command: ["sh", "-c", "sleep 3600"]
```

- [ ] **Step 4: Write the candidates in `demos/cert-hygiene/lab/admission/candidates/`**

Every file starts with the same metadata block; only `kind`, `apiVersion` and `spec` differ. Write each file in full.

`policy-1-invalid.yaml` (a CIDR the policy controller cannot parse; the CRD types it only as a string):

```yaml
apiVersion: policy.linkerd.io/v1alpha1
kind: NetworkAuthentication
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
spec:
  networks:
    - cidr: not-a-cidr
```

`policy-1-valid.yaml`: the same file with `- cidr: 10.255.0.0/16`.

`policy-2-invalid.yaml` (an identity reference to a kind the validator does not accept):

```yaml
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
spec:
  identityRefs:
    - kind: Pod
      name: server
```

`policy-2-valid.yaml`: the same file with `kind: ServiceAccount` and `name: no-such-serviceaccount`.

`policy-3-invalid.yaml` (a target kind the validator does not accept):

```yaml
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
spec:
  targetRef:
    group: ""
    kind: Pod
    name: server
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: NetworkAuthentication
      name: no-such-networkauthentication
```

`policy-3-valid.yaml`: the same file with `targetRef` set to `group: policy.linkerd.io`, `kind: Server`, `name: no-such-server`.

`sp-1-invalid.yaml` (a retry-budget TTL the validator cannot parse as a duration):

```yaml
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
spec:
  retryBudget:
    retryRatio: 0.2
    minRetriesPerSecond: 10
    ttl: not-a-duration
```

`sp-1-valid.yaml`: the same file with `ttl: 10s`.

`sp-2-invalid.yaml` (a route without a condition):

```yaml
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
spec:
  routes:
    - name: no-condition
```

`sp-2-valid.yaml`: the same file with the route given `condition: {method: GET, pathRegex: /inert}`.

`sp-3-invalid.yaml` (a response class without a condition):

```yaml
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: ${NAME}
  namespace: ${LAB_NS}
spec:
  routes:
    - name: inert
      condition:
        method: GET
        pathRegex: /inert
      responseClasses:
        - isFailure: true
```

`sp-3-valid.yaml`: the same file with the response class given `condition: {status: {min: 500}}`.

- [ ] **Step 5: Write `demos/cert-hygiene/lab/admission.sh`**

```bash
#!/usr/bin/env bash
# W's admission probes (design section 3). Each attempt creates a fresh, uniquely named
# object and records the request, the exact API response and the resulting object; any
# object that was created is deleted once observed. Source after lab/collect.sh with
# RUN_DIR set; do not execute.

admission_render() { # TEMPLATE NAME: lab/admission/TEMPLATE.yaml with NAME substituted
  local tpl="$LAB_DIR/admission/${1:?admission_render: TEMPLATE required}.yaml"
  [ -f "$tpl" ] || die "admission_render: no template $tpl (run Task 11's discovery first)"
  # shellcheck disable=SC2016
  NAME="${2:?admission_render: NAME required}" envsubst '${NAME} ${LAB_NS} ${IMAGE_BUSYBOX}' < "$tpl"
}

admission_attempt() { # PHASE OBJECT TEMPLATE
  local phase="$1" obj="$2" tpl="$3" dir="$RUN_DIR/admission/$1"
  mkdir -p "$dir"
  [ ! -e "$dir/$obj.request.yaml" ] || die "admission_attempt: $dir/$obj.request.yaml exists; evidence is written once"
  admission_render "$tpl" "$obj" > "$dir/$obj.request.yaml"
  capture "admission/$phase/$obj.response.txt" kubectl create -f "$dir/$obj.request.yaml"
  capture "admission/$phase/$obj.observed.yaml" kubectl get -f "$dir/$obj.request.yaml" -o yaml
  if [ "$(tail -n 1 "$dir/$obj.observed.yaml")" = "[exit 0]" ]; then
    capture "admission/$phase/$obj.delete.txt" kubectl delete -f "$dir/$obj.request.yaml" --wait=false
  fi
}

admission_probes() { # PHASE SUFFIX: probes (a)-(d), one fresh object each
  local phase="$1" s="$2"
  admission_attempt "$phase" "inject-probe-$s" inject-probe
  admission_attempt "$phase" "policy-invalid-$s" policy-invalid
  admission_attempt "$phase" "serviceprofile-invalid-$s" serviceprofile-invalid
  admission_attempt "$phase" "policy-valid-$s" policy-valid
  admission_attempt "$phase" "serviceprofile-valid-$s" serviceprofile-valid
}
```

- [ ] **Step 6: Record the webhook names in `demos/cert-hygiene/config.example.env`**

Open Task 1's `runs/_discovery/<stamp>-webhooks/FINDINGS.md` and take the `webhook_names=` values of the `policyValidator` and `profileValidator` components. Append a section with those exact values (the chart's names are shown; use the discovered ones if they differ):

```bash

# ---- W: webhook names in admission rejections (Task 1 discovery) ----
POLICY_VALIDATOR_WEBHOOK_NAME=linkerd-policy-validator.linkerd.io
SP_VALIDATOR_WEBHOOK_NAME=linkerd-sp-validator.linkerd.io
```

- [ ] **Step 7: Write `demos/cert-hygiene/lab/discover-admission.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a healthy lab (long profile) with baseline workloads.
# Tries each candidate invalid policy and ServiceProfile resource and its valid twin,
# and records which the healthy validators reject with their own message (design 10).
# Usage: discover-admission.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"
RUN_DIR="${1:?usage: discover-admission.sh <out-dir>}"
[ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists; refusing to overwrite"
mkdir -p "$RUN_DIR"

for cfg in validatingwebhookconfiguration/linkerd-policy-validator-webhook-config \
    validatingwebhookconfiguration/linkerd-sp-validator-webhook-config; do
  printf '%s webhooks=%s\n' "$cfg" "$(kubectl get "$cfg" -o jsonpath='{.webhooks[*].name}')"
done > "$RUN_DIR/webhook-names.txt"
admission_attempt inject inject-probe-discovery inject-probe
for c in policy-1 policy-2 policy-3 sp-1 sp-2 sp-3; do
  case "$c" in policy-*) wh="$POLICY_VALIDATOR_WEBHOOK_NAME" ;; sp-*) wh="$SP_VALIDATOR_WEBHOOK_NAME" ;; esac
  admission_attempt candidates "$c-invalid-discovery" "candidates/$c-invalid"
  admission_attempt candidates "$c-valid-discovery" "candidates/$c-valid"
  inv="$RUN_DIR/admission/candidates/$c-invalid-discovery.response.txt"
  val="$RUN_DIR/admission/candidates/$c-valid-discovery.response.txt"
  denied=no; accepted=no
  if [ "$(tail -n 1 "$inv")" != "[exit 0]" ] && grep -qF "admission webhook \"$wh\" denied the request" "$inv"; then denied=yes; fi
  if [ "$(tail -n 1 "$val")" = "[exit 0]" ]; then accepted=yes; fi
  printf 'candidate=%s invalid_denied_by_validator=%s valid_accepted=%s\n' "$c" "$denied" "$accepted"
done > "$RUN_DIR/summary.txt"
cat "$RUN_DIR/webhook-names.txt" "$RUN_DIR/summary.txt"
```

Append to `demos/cert-hygiene/Justfile`:

```just

# Discovery: which policy and ServiceProfile resources the healthy validators reject
discover-admission:
    bash scripts/in-lab.sh lab/discover-admission.sh runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)-admission
```

- [ ] **Step 8: Syntax and shellcheck**

Run: `cd demos/cert-hygiene && for f in lab/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh lab/tests/*.sh'`
Expected: no output.

- [ ] **Step 9: Discovery — which resources do the healthy validators reject?**

Run: `just demo cert-hygiene reset long` (repeat the wait if it times out), `just demo cert-hygiene deploy baseline`, then `just demo cert-hygiene discover-admission`.
Expected: `webhook-names.txt` lines naming the two validators, and six `candidate=` lines.

Let `D=demos/cert-hygiene/runs/_discovery/<stamp>-admission`. Check that `$D/admission/inject/inject-probe-discovery.observed.yaml` contains `name: linkerd-proxy`. Then:
- **Policy:** take the lowest-numbered `policy-N` with `invalid_denied_by_validator=yes valid_accepted=yes`. Copy `candidates/policy-N-invalid.yaml` to `demos/cert-hygiene/lab/admission/policy-invalid.yaml` and `candidates/policy-N-valid.yaml` to `policy-valid.yaml` (Read each, then Write it; contents unchanged).
- **ServiceProfile:** the same with `sp-N`, into `serviceprofile-invalid.yaml` and `serviceprofile-valid.yaml`.

Write `$D/FINDINGS.md` with the Write tool: headings "Which policy resource does the healthy policy validator reject?" and "Which ServiceProfile does the healthy sp-validator reject?", each quoting the `summary.txt` line and the chosen candidate's exact response (the `denied the request` line), and saying which files received them.

**STOP GATE:** if no policy candidate or no ServiceProfile candidate qualifies, commit `$D` and stop: report to the user with the recorded responses. W's baseline cannot prove its probes without one.

- [ ] **Step 10: Prove the chosen probe set once, by hand**

Run: `bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && . lab/collect.sh && . lab/admission.sh && RUN_DIR=runs/_discovery/<stamp>-admission && admission_probes proof check && admission_proof_check "$RUN_DIR/admission/proof" check "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME"'`
Expected: five `ok:` lines and exit 0. Add the output to `$D/FINDINGS.md` under "Proof of the chosen probe set".

- [ ] **Step 11: Commit**

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/config.example.env demos/cert-hygiene/Justfile demos/cert-hygiene/runs/_discovery
git commit -m "cert-hygiene add admission probes; choose validator-rejected resources by discovery"
git push
```
