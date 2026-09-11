# Task 1: Credential profiles and supplied webhook certificates

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Replace `reset.sh <short|long>` with `reset.sh <profile> <name>` (design § 1.1). Each profile is a file of lifetimes, webhook-certificate lifetimes and extra install flags. When a profile sets `WEBHOOK_CERT_LIFETIMES`, `reset.sh` creates a lab webhook CA, signs one serving certificate per webhook with the Service's DNS name as SAN, and passes them to `linkerd install --set-file`. Slice-1 scenarios keep working: `short` becomes `issuer-short`, `long` stays `long`. A discovery run settles whether `linkerd install` accepts the supplied certificates (design § 10).

**This task has a stop gate** (Step 11).

**Files:**
- Create: `demos/cert-hygiene/lab/profiles/long.env`, `issuer-short.env`, `webhook-short.env`, `webhook-short-fail.env`, `anchor-short.env`, `check-threshold.env`
- Create: `demos/cert-hygiene/lab/lib-webhook.sh`, `demos/cert-hygiene/lab/discover-webhooks.sh`
- Modify: `demos/cert-hygiene/lab/lib-lab.sh` (source `lib-webhook.sh`; add `load_profile`)
- Modify (full rewrite): `demos/cert-hygiene/lab/reset.sh`
- Modify: `demos/cert-hygiene/config.example.env`, `demos/cert-hygiene/lab/collect.sh` (`write_versions` config prefixes), `demos/cert-hygiene/lab/scenario-common.sh` (`run_scenario SCENARIO PROFILE RUN_DIR`), `demos/cert-hygiene/scenarios/00-baseline-control.sh`, `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`, `demos/cert-hygiene/Justfile`
- Create (discovery, committed): `demos/cert-hygiene/runs/_discovery/<stamp>-webhooks/` with `FINDINGS.md`

**Interfaces:**
- Consumes: `lib/certs.sh` (`make_trust_anchor`, `make_issuer`, `ensure_step`), `lib/linkerd.sh` (`linkerd_install`), `lab/lib-lab.sh` (`CERTS_ROOT`, `LAB_DIR`, prepull helpers).
- Produces:
  - Profile file format: shell assignments of exactly `ANCHOR_LIFETIME`, `ISSUER_LIFETIME`, `LEAF_LIFETIME` (non-empty), `WEBHOOK_CERT_LIFETIMES`, `EXTRA_INSTALL_FLAGS` (may be empty, must be present).
  - `load_profile PROFILE`: sources and exports the profile, sets and exports `PROFILE`; dies on an unknown profile or a missing key.
  - `WEBHOOK_COMPONENTS=(proxyInjector policyValidator profileValidator)` (fixed order, used by every later task); `webhook_service COMPONENT` → `linkerd-proxy-injector` / `linkerd-policy-validator` / `linkerd-sp-validator`; `webhook_secret COMPONENT` → `<service>-k8s-tls`; `make_webhook_certs DIR SPEC`; `make_webhook_ca DIR`; `make_webhook_cert DIR COMPONENT LIFETIME`; `webhook_install_args DIR` (prints `--set-file` and `<c>.crtPEM=…,<c>.keyPEM=…,<c>.caBundle=…` on alternate lines).
  - Cert-set layout in the VM: `$CERTS_ROOT/<name>/{ca,issuer}.{crt,key}` as before, plus `webhooks/{ca,proxyInjector,policyValidator,profileValidator}.{crt,key}` when the profile supplies webhook certs.
  - `run_scenario SCENARIO PROFILE RUN_DIR` (the second argument is now a profile name; the `reset` timeline line says `profile=<p>`).
  - Config: `CONTROL_T_MARK_AFTER=15m` (the control's T_mark offset, R's issuer lifetime). `ANCHOR_LIFETIME`, `ISSUER_LIFETIME`, `LEAF_LIFETIME`, `CONTROL_ANCHOR_LIFETIME`, `CONTROL_ISSUER_LIFETIME` leave `config.example.env`.

- [ ] **Step 1: Write the six profiles**

`demos/cert-hygiene/lab/profiles/long.env`:

```bash
# Long-lived credentials: nothing expires during a run. Control, O, S.
ANCHOR_LIFETIME=87600h
ISSUER_LIFETIME=8760h
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES=
EXTRA_INSTALL_FLAGS=
```

`demos/cert-hygiene/lab/profiles/issuer-short.env`:

```bash
# R: the issuer expires minutes into the run; the anchor cannot.
ANCHOR_LIFETIME=720h
ISSUER_LIFETIME=15m
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES=
EXTRA_INSTALL_FLAGS=
```

`demos/cert-hygiene/lab/profiles/webhook-short.env`:

```bash
# W (Ignore): lab-supplied webhook serving certificates expiring 10 minutes apart.
ANCHOR_LIFETIME=87600h
ISSUER_LIFETIME=8760h
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES="proxyInjector=15m policyValidator=25m profileValidator=35m"
EXTRA_INSTALL_FLAGS=
```

`demos/cert-hygiene/lab/profiles/webhook-short-fail.env`:

```bash
# W (Fail): as webhook-short, with every Linkerd webhook set to failurePolicy Fail.
ANCHOR_LIFETIME=87600h
ISSUER_LIFETIME=8760h
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES="proxyInjector=15m policyValidator=25m profileValidator=35m"
EXTRA_INSTALL_FLAGS="--set webhookFailurePolicy=Fail"
```

`demos/cert-hygiene/lab/profiles/anchor-short.env`:

```bash
# A: a 20-minute trust anchor, and an issuer that outlives it (step signs it).
ANCHOR_LIFETIME=20m
ISSUER_LIFETIME=120m
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES=
EXTRA_INSTALL_FLAGS=
```

`demos/cert-hygiene/lab/profiles/check-threshold.env`:

```bash
# K: an issuer 10 minutes short of 60 days (1440h - 10m). K signs the +10m one itself.
ANCHOR_LIFETIME=87600h
ISSUER_LIFETIME=1439h50m
LEAF_LIFETIME=5m
WEBHOOK_CERT_LIFETIMES=
EXTRA_INSTALL_FLAGS=
```

- [ ] **Step 2: Write `demos/cert-hygiene/lab/lib-webhook.sh`**

```bash
#!/usr/bin/env bash
# Lab-supplied webhook serving credentials (design section 1.1): one lab webhook CA and
# one serving certificate per Linkerd webhook, each with its own lifetime and the
# webhook Service's DNS name as its SAN. RSA 2048, the key type Linkerd's own
# generated webhook certificates use. Source after lib/common.sh; do not execute.
# Keys stay in the VM under $CERTS_ROOT; only certificates ever reach evidence.

# Helm value prefixes of Linkerd's three webhooks, in the fixed order every file uses.
WEBHOOK_COMPONENTS=(proxyInjector policyValidator profileValidator)

webhook_service() { # COMPONENT: the webhook's Service name in the linkerd namespace
  case "${1:?webhook_service: COMPONENT required}" in
    proxyInjector) echo linkerd-proxy-injector ;;
    policyValidator) echo linkerd-policy-validator ;;
    profileValidator) echo linkerd-sp-validator ;;
    *) die "webhook_service: unknown component '$1'" ;;
  esac
}

webhook_secret() { # COMPONENT: the Secret holding the webhook's serving certificate
  echo "$(webhook_service "$1")-k8s-tls"
}

webhook_lifetime() { # SPEC COMPONENT: COMPONENT's lifetime in SPEC ("proxyInjector=15m ...")
  local spec="$1" comp="$2" pair
  for pair in $spec; do
    if [ "${pair%%=*}" = "$comp" ]; then echo "${pair#*=}"; return 0; fi
  done
  die "webhook_lifetime: no lifetime for $comp in WEBHOOK_CERT_LIFETIMES='$spec'"
}

make_webhook_ca() { # DIR: DIR/ca.crt + DIR/ca.key. Never overwrites.
  local dir="${1:?make_webhook_ca: DIR required}"
  [ ! -e "$dir/ca.crt" ] || die "make_webhook_ca: $dir/ca.crt exists; refusing to overwrite"
  mkdir -p "$dir"
  step certificate create lab-webhook-ca "$dir/ca.crt" "$dir/ca.key" --profile root-ca \
    --kty RSA --size 2048 --not-after 87600h --no-password --insecure
}

make_webhook_cert() { # DIR COMPONENT LIFETIME: DIR/COMPONENT.{crt,key}, signed by DIR/ca.*
  local dir="${1:?}" comp="${2:?}" life="${3:?}" host
  host="$(webhook_service "$comp").linkerd.svc"
  if [ ! -f "$dir/ca.crt" ] || [ ! -f "$dir/ca.key" ]; then die "make_webhook_cert: no webhook CA in $dir"; fi
  [ ! -e "$dir/$comp.crt" ] || die "make_webhook_cert: $dir/$comp.crt exists; refusing to overwrite"
  step certificate create "$host" "$dir/$comp.crt" "$dir/$comp.key" --profile leaf \
    --ca "$dir/ca.crt" --ca-key "$dir/ca.key" --san "$host" --kty RSA --size 2048 \
    --not-after "$life" --no-password --insecure
}

make_webhook_certs() { # DIR SPEC: the lab webhook CA plus one serving certificate per component
  local dir="${1:?}" spec="${2:?make_webhook_certs: SPEC required}" comp life
  make_webhook_ca "$dir"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    life="$(webhook_lifetime "$spec" "$comp")" || die "make_webhook_certs: no lifetime for $comp"
    make_webhook_cert "$dir" "$comp" "$life"
  done
}

webhook_install_args() { # DIR: linkerd install/upgrade arguments passing DIR's certs, one per line
  local dir="${1:?}" comp
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    printf -- '--set-file\n%s.crtPEM=%s,%s.keyPEM=%s,%s.caBundle=%s\n' \
      "$comp" "$dir/$comp.crt" "$comp" "$dir/$comp.key" "$comp" "$dir/ca.crt"
  done
}
```

`caBundle` must be set, or the chart pairs the certificate with an unrelated generated CA (source notes § 5).

- [ ] **Step 3: Extend `demos/cert-hygiene/lab/lib-lab.sh`**

After the line `. "$LAB_DIR/lib-evidence.sh"`, add:

```bash
# shellcheck source=/dev/null
. "$LAB_DIR/lib-webhook.sh"

# load_profile PROFILE: export the credential profile lab/profiles/PROFILE.env
# (design section 1.1) and PROFILE itself. Dies on an unknown profile or a missing key.
load_profile() {
  local p="${1:?load_profile: PROFILE required}" f v
  f="$LAB_DIR/profiles/$p.env"
  [ -f "$f" ] || die "no credential profile '$p' (expected $f)"
  set -a
  # shellcheck source=/dev/null
  . "$f"
  set +a
  for v in ANCHOR_LIFETIME ISSUER_LIFETIME LEAF_LIFETIME; do
    [ -n "${!v:-}" ] || die "$f does not set $v"
  done
  for v in WEBHOOK_CERT_LIFETIMES EXTRA_INSTALL_FLAGS; do
    grep -q "^$v=" "$f" || die "$f does not define $v (define it empty when unused)"
  done
  PROFILE="$p"
  export PROFILE
}
```

- [ ] **Step 4: Rewrite `demos/cert-hygiene/lab/reset.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. A fresh cluster with Linkerd rooted at freshly generated lab
# credentials shaped by a credential profile (lab/profiles/<profile>.env, design 1.1).
# Usage: reset.sh <profile> <cert-set-name>
# Every image is pulled BEFORE the certificates are generated, so pulls never eat into a
# short lifetime. When the profile sets WEBHOOK_CERT_LIFETIMES, the three webhook serving
# certificates are lab-supplied through --set-file instead of Linkerd-generated.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"

profile="${1:?usage: reset.sh <profile> <cert-set-name>}"
name="${2:?usage: reset.sh <profile> <cert-set-name>}"
load_profile "$profile"
certs="$CERTS_ROOT/$name"
[ ! -e "$certs" ] || die "$certs already exists; every reset gets a new cert set"
require_pinned_images

reset_k3s
ensure_linkerd_cli "$LINKERD_EDGE_VERSION"
install_gateway_crds "$GATEWAY_API_VERSION"
linkerd install --crds | kubectl apply -f -
prepull_linkerd_images
prepull_workload_images

# The clock on every short lifetime starts here.
ensure_step
make_trust_anchor "$certs" "$ANCHOR_LIFETIME"
make_issuer "$certs" "$ISSUER_LIFETIME" "$certs"
install_args=(--identity-issuance-lifetime "$LEAF_LIFETIME")
if [ -n "$WEBHOOK_CERT_LIFETIMES" ]; then
  make_webhook_certs "$certs/webhooks" "$WEBHOOK_CERT_LIFETIMES"
  mapfile -t webhook_args < <(webhook_install_args "$certs/webhooks")
  install_args+=("${webhook_args[@]}")
fi
read -r -a extra_args <<< "$EXTRA_INSTALL_FLAGS"
install_args+=("${extra_args[@]}")
linkerd_install "$certs/ca.crt" "$certs/issuer.crt" "$certs/issuer.key" "${install_args[@]}"
log "reset complete: profile=$profile certs=$certs"
```

- [ ] **Step 5: Move lifetimes out of `demos/cert-hygiene/config.example.env`**

Replace the whole `# ---- Credential lifetimes ...` section (from that heading line through `REPLACEMENT_ISSUER_LIFETIME=8760h`) with:

```bash
# ---- Credentials ----
# Anchor, issuer, leaf and webhook lifetimes live in lab/profiles/<profile>.env.
# The issuer R signs during recovery, from the same anchor.
REPLACEMENT_ISSUER_LIFETIME=8760h
# The control's T_mark sits this long after its issuer's notBefore: where R's
# issuer-short issuer would expire, so both runs snapshot the same moments.
CONTROL_T_MARK_AFTER=15m
```

- [ ] **Step 6: Record the new settings in `versions.txt`**

In `demos/cert-hygiene/lab/collect.sh`, `write_versions`, replace the `cfg=` line's pattern so the whole line reads:

```bash
  cfg="$(env | grep -E '^(LAB_|LINKERD_|GATEWAY_|ANCHOR_|ISSUER_|LEAF_|CONTROL_|REPLACEMENT_|PROBE_|OBSERVE_|POST_|RECOVER_|IMAGE_|PROFILE=|WEBHOOK_|EXTRA_|GATE_|OUTAGE_|FAULT_|S_HARD_|K_|POLICY_|SP_|NEW_|W_)' | sort)" \
```

The prefixes for later tasks' settings are added now so `collect.sh` is not touched again for this.

- [ ] **Step 7: Pass profiles in `run_scenario` and the two slice-1 scenarios**

In `demos/cert-hygiene/lab/scenario-common.sh`, `run_scenario`:
- Change the comment `run_scenario() { # SCENARIO MODE RUN_DIR` to `run_scenario() { # SCENARIO PROFILE RUN_DIR`.
- Change `local mode="$2" start sampled max` to `local profile="$2" start sampled max`.
- Immediately after `RUN_DIR="$3"`, add `load_profile "$profile"`.
- Change `mark reset "mode=$mode cert_set=$CERT_SET"` to `mark reset "profile=$profile cert_set=$CERT_SET"`.
- Change `bash "$LAB_DIR/reset.sh" "$mode" "$CERT_SET"` to `bash "$LAB_DIR/reset.sh" "$profile" "$CERT_SET"`.

In `demos/cert-hygiene/scenarios/00-baseline-control.sh`, replace the body of `scenario_mark_epoch` with:

```bash
  echo $(( $(cert_not_before_epoch "$CERTS/issuer.crt") + $(duration_to_seconds "$CONTROL_T_MARK_AFTER") ))
```

The last line stays `run_scenario 00-baseline-control long "${1:?usage: 00-baseline-control.sh <run-dir>}"`.

In `demos/cert-hygiene/scenarios/05-issuer-expiry.sh`, change the last line to:

```bash
run_scenario 05-issuer-expiry issuer-short "${1:?usage: 05-issuer-expiry.sh <run-dir>}"
```

- [ ] **Step 8: Write `demos/cert-hygiene/lab/discover-webhooks.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a lab just reset with a webhook-short profile and with
# baseline workloads deployed. Records whether Linkerd serves the lab-supplied webhook
# certificates: each Secret's certificate against the supplied one, each webhook
# configuration's caBundle against the supplied CA, linkerd check's webhook rows, and a
# server-side dry-run pod create (the proxy-injector must add linkerd-proxy).
# Usage: discover-webhooks.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
out="${1:?usage: discover-webhooks.sh <out-dir>}"
[ ! -e "$out" ] || die "$out exists; refusing to overwrite"
# shellcheck disable=SC2012
certs="$(ls -dt "$CERTS_ROOT"/*/ | head -n 1)"
[ -d "$certs/webhooks" ] || die "newest cert set $certs has no webhooks/; reset with webhook-short first"
mkdir -p "$out"

fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; } # PEM on stdin
yn() { if [ "$1" = "$2" ]; then echo yes; else echo no; fi; }    # A B: yes when equal
config_of() { # COMPONENT: the kind/name of its webhook configuration
  case "$1" in
    proxyInjector) echo mutatingwebhookconfiguration/linkerd-proxy-injector-webhook-config ;;
    policyValidator) echo validatingwebhookconfiguration/linkerd-policy-validator-webhook-config ;;
    profileValidator) echo validatingwebhookconfiguration/linkerd-sp-validator-webhook-config ;;
  esac
}

linkerd check > "$out/check.txt" 2>&1 || true
{
  printf 'cert_set=%s\n' "$certs"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    supplied="$(fp < "$certs/webhooks/$comp.crt")"
    served="$(kubectl -n linkerd get secret "$(webhook_secret "$comp")" -o jsonpath='{.data.tls\.crt}' | base64 -d | fp)"
    bundle="$(kubectl get "$(config_of "$comp")" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | sha256sum | cut -d' ' -f1)"
    ca="$(sha256sum < "$certs/webhooks/ca.crt" | cut -d' ' -f1)"
    names="$(kubectl get "$(config_of "$comp")" -o jsonpath='{.webhooks[*].name}')"
    policy="$(kubectl get "$(config_of "$comp")" -o jsonpath='{.webhooks[*].failurePolicy}')"
    printf 'component=%s secret_matches_supplied=%s cabundle_matches_supplied_ca=%s webhook_names=%s failure_policy=%s\n' \
      "$comp" "$(yn "$supplied" "$served")" "$(yn "$bundle" "$ca")" "$names" "$policy"
  done
} > "$out/summary.txt"
kubectl -n "$LAB_NS" run discover-inject-probe --image="$IMAGE_BUSYBOX" --restart=Never \
  --dry-run=server -o yaml -- sleep 60 > "$out/inject-dry-run.yaml" 2>&1 || true
if grep -q 'name: linkerd-proxy$' "$out/inject-dry-run.yaml"; then
  echo injection=injected >> "$out/summary.txt"
else
  echo injection=not-injected >> "$out/summary.txt"
fi
grep -E 'webhook has valid cert|cert is valid for at least 60 days' "$out/check.txt" >> "$out/summary.txt" || true
log "webhook discovery data in $out"
cat "$out/summary.txt"
```

- [ ] **Step 9: Update `demos/cert-hygiene/Justfile`**

Replace the `reset` recipe (its comment line and both command lines) with:

```just
# Fresh k3s + Linkerd with the credential profile PROFILE (lab/profiles/PROFILE.env)
reset PROFILE="issuer-short":
    bash scripts/in-lab.sh --detach .lab-logs/reset.log lab/reset.sh {{PROFILE}} manual-$(date -u +%Y%m%dT%H%M%SZ)
    bash scripts/wait-log.sh .lab-logs/reset.log 540
```

Append:

```just

# Discovery: does the current lab serve the lab-supplied webhook certificates?
discover-webhooks:
    bash scripts/in-lab.sh lab/discover-webhooks.sh runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)-webhooks
```

- [ ] **Step 10: Syntax-check, shellcheck, unit tests**

Run: `cd demos/cert-hygiene && for f in lab/*.sh scenarios/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh scenarios/*.sh scripts/*.sh'`
Expected: no output.

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence`.

- [ ] **Step 11: Discovery — does `linkerd install` accept the supplied webhook certificates? (stop gate)**

Run: `just demo cert-hygiene reset webhook-short`. If the wait prints `timed out`, run `bash demos/cert-hygiene/scripts/wait-log.sh .lab-logs/reset.log 540` again until it prints the log tail.
Expected: the tail ends `reset complete: profile=webhook-short …` and `[exit 0]`. If `linkerd install` rejected the values, the tail shows its error: record it.

Run: `just demo cert-hygiene deploy baseline`, then `just demo cert-hygiene discover-webhooks`.
Expected in the printed `summary.txt`: three `component=` lines, each with `secret_matches_supplied=yes cabundle_matches_supplied_ca=yes failure_policy=Ignore`; `injection=injected`; `√ proxy-injector webhook has valid cert`, `√ sp-validator webhook has valid cert`, `√ policy-validator webhook has valid cert`, and a `‼ … cert is valid for at least 60 days` line per webhook (short certificates always warn).

Write `demos/cert-hygiene/runs/_discovery/<stamp>-webhooks/FINDINGS.md` with the Write tool: one heading "Does linkerd install accept lab-supplied webhook certificates?", the `summary.txt` lines quoted, the webhook names quoted (Task 11 reads them from here: the policy validator's and the sp-validator's `webhook_names`), and a one-sentence answer.

**STOP GATE:** if any component shows `no`, if `injection=not-injected`, or if any "webhook has valid cert" row is not `√`, commit the discovery directory, then stop and report to the user with the FINDINGS. W cannot run as designed.

- [ ] **Step 12: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, add this bullet to the end of the "Status" list:

```markdown
- **Second round of lab experiments** (webhook certificates, identity outage, `linkerd check` threshold, trust-anchor expiry and rotation, and a repeat of the issuer experiment): the lab is being extended. Nothing from this round is evidence yet.
```

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/scenarios demos/cert-hygiene/config.example.env demos/cert-hygiene/Justfile demos/cert-hygiene/runs/_discovery docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene add credential profiles and lab-supplied webhook certificates"
git push
```
