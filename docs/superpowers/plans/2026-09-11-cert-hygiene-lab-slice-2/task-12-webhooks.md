# Task 12: Scenario W

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 3, in two scenario files that share one library: `02-webhook-expiry-ignore` (profile `webhook-short`, Linkerd's default `failurePolicy: Ignore`) and `02-webhook-expiry-fail` (profile `webhook-short-fail`). Anchor and issuer are long-lived, and the traffic probes run throughout (W3).

**Timeline.** The three lab-supplied serving certificates expire 10 minutes apart: proxy-injector at T1 (= T_mark), policy-validator at T2 = T1 + 10 min, sp-validator at T3 = T1 + 20 min. Admission probes (Task 11) run:
- at baseline, phase `baseline` (the proof: the run dies, invalid, if it fails);
- on every tick before T1, phase `pre-expiry`;
- at T_mark + 60 s (`scenario_post_actions`) and on every later tick, phase `post-NNNN`, where NNNN is the seconds since T1, zero-padded;
- after recovery, phase `recovered`.

The first tick after each certificate's `notAfter` marks that webhook's expiry phase (`webhook-expired <component> …`). Every tick already records the webhook configurations, `failurePolicy`, caBundle hashes, serving-certificate identities (`webhooks/<tick>.txt`) and the `linkerd check` transcripts, so each phase has them. Recovery starts at T1 + `POST_EXPIRY_WINDOW_S` (1800 s), which is T3 + 10 minutes with these profiles; `scenario_mark_epoch` refuses a window that leaves under 5 minutes after T3.

**Recovery, observed as it branches** (design § 3):
1. Delete the three `…-k8s-tls` Secrets.
2. Render a plain `linkerd upgrade` into the VM-only cert set, record a **redacted** copy of the complete manifest in evidence (private keys replaced by hash markers; Global Constraints), and apply it.
3. Wait for control-plane rollouts and for webhook serving to propagate, then record the facts: each Secret certificate's fingerprint, serial and `notAfter`; each caBundle's hash and whether it verifies its Secret's certificate; Deployment generations and pod UIDs; `linkerd check`; and a post-propagation admission probe set.
4. Classify the branch mechanically, by a rule declared here in advance:
   - **ii** if every Secret certificate is the supplied one;
   - **i** if none is, and every one is currently valid, verifies against its webhook's caBundle, and the post-propagation probe set proves all three webhooks;
   - **iii** otherwise.
5. For ii and iii, generate fresh lab-supplied credentials, pass them with `--set-file` through the same render/redact/apply path, and record the same facts again.

No branch is predicted (W6 is an observation), and no exit status counts as recovery by itself. The state between steps 2 and 5 is recorded in non-tick artifacts, so the credential plan sees exactly one webhook change (`A/I1/W1 → A/I1/W2`, Task 3).

**Files:**
- Create: `demos/cert-hygiene/lab/scenario-webhook.sh`, `demos/cert-hygiene/scenarios/02-webhook-expiry-ignore.sh`, `demos/cert-hygiene/scenarios/02-webhook-expiry-fail.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` (add `redact_manifest`, `w_branch_classify`), `demos/cert-hygiene/lab/tests/test-scenarios.sh`
- Modify: `demos/cert-hygiene/config.example.env` (`W_PROPAGATION_TIMEOUT_S`, `W_FRESH_WEBHOOK_LIFETIME`)

**Interfaces:**
- Consumes: Task 9 hooks, Task 11 (`admission_probes`, `admission_render`, `admission_proof_check`), Task 1 (`make_webhook_certs`, `webhook_install_args`, `webhook_secret`, `WEBHOOK_COMPONENTS`), Task 5 (`WEBHOOK_CONFIGS`, `snap_webhooks`, `snap_controlplane`), `cert_facts`, `cert_not_after_epoch`.
- Produces:
  - `redact_manifest FILE` (pure) → FILE on stdout with every base64 value that decodes to a private key replaced by `<redacted sha256=<hash of the value>>`, and every literal PEM private-key block replaced by one `<redacted private key block>` line. Everything else is byte-identical.
  - `w_branch_classify FACTS_FILE` (pure) → `branch=i|ii|iii` by the rule above. Facts contract: exactly three lines `component=<c> secret_sha256=<hex|-> supplied_sha256=<hex> equals_supplied=<yes|no> not_after_epoch=<epoch|-> valid_now=<yes|no> cabundle_verifies=<yes|no>` and one `admission=<healthy|unhealthy>` line. Dies on any other count.
  - Evidence: `admission-baseline.txt`; `admission/{baseline,pre-expiry,post-NNNN,recovered}/`; timeline markers `webhook-expired`, `admission-probes`, `recover-delete`, `recover-plain`, `propagated`, `recover-branch`, `recover-supplied`; `recover/delete-secrets.txt`; per label (`plain`, and `supplied` for ii/iii): `recover/<label>-render.txt`, `recover/<label>-manifest.yaml` (redacted), `recover/<label>-apply.txt`, `recover/<label>-rollout.txt`, `recover/<label>-propagation.txt`, `recover/<label>-check.txt`, `recover/<label>-facts.txt`, `controlplane/recover-<label>.txt`, `webhooks/recover-<label>.txt`, `admission/recovered/*-recover-<label>.*`; `recover/branch.txt` (first line `branch=…`); `certs/webhook-fresh-*.{pem,txt}` for ii/iii.
  - Config: `W_PROPAGATION_TIMEOUT_S=180`, `W_FRESH_WEBHOOK_LIFETIME=8760h`.

- [ ] **Step 1: Failing tests (append to `demos/cert-hygiene/lab/tests/test-scenarios.sh`, before `finish test-scenarios`)**

```bash
# ---- redact_manifest ----
key_b64="$(printf -- '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIFakeKeyMaterialForUnitTests\n-----END EC PRIVATE KEY-----\n' | base64 -w0)"
crt_b64="$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBFakeCertificateForUnitTests\n-----END CERTIFICATE-----\n' | base64 -w0)"
{
  printf 'apiVersion: v1\nkind: Secret\ndata:\n'
  printf '  tls.crt: %s\n  tls.key: %s\n' "$crt_b64" "$key_b64"
  printf -- '---\nkind: ConfigMap\ndata:\n  values: |\n    keyPEM: |\n'
  printf '      -----BEGIN EC PRIVATE KEY-----\n      AAAAFakeBlock\n      -----END EC PRIVATE KEY-----\n'
  printf '    other: kept\n'
} > "$T/m.yaml"
red="$(redact_manifest "$T/m.yaml")"
assert_eq "$(grep -c 'PRIVATE KEY' <<< "$red")" 0 "no private key text survives"
assert_eq "$(grep -cF "$key_b64" <<< "$red")" 0 "no base64 key survives"
assert_contains "$red" "tls.crt: $crt_b64" "certificates are kept"
assert_contains "$red" "tls.key: <redacted sha256=$(printf '%s' "$key_b64" | sha256sum | cut -d' ' -f1)>" "a base64 key becomes a hash marker"
assert_contains "$red" "      <redacted private key block>" "a PEM key block becomes one marker, indentation kept"
assert_contains "$red" "    other: kept" "lines after a block are kept"

# ---- w_branch_classify ----
facts() { # FILE EQ1 EQ2 EQ3 VALID VERIFIES ADMISSION
  local f="$1" c eq
  : > "$f"
  for c in proxyInjector:"$2" policyValidator:"$3" profileValidator:"$4"; do
    eq="${c#*:}"
    printf 'component=%s secret_sha256=aa supplied_sha256=bb equals_supplied=%s not_after_epoch=9 valid_now=%s cabundle_verifies=%s\n' \
      "${c%%:*}" "$eq" "$5" "$6" >> "$f"
  done
  printf 'admission=%s\n' "$7" >> "$f"
}
facts "$T/b2" yes yes yes no no unhealthy
assert_eq "$(w_branch_classify "$T/b2")" branch=ii "all three still the supplied certificates: ii"
facts "$T/b1" no no no yes yes healthy
assert_eq "$(w_branch_classify "$T/b1")" branch=i "fresh, valid, verifying, serving: i"
facts "$T/b3" no no no yes no healthy
assert_eq "$(w_branch_classify "$T/b3")" branch=iii "a caBundle mismatch: iii"
facts "$T/b4" no no no yes yes unhealthy
assert_eq "$(w_branch_classify "$T/b4")" branch=iii "fresh certificates but admission unhealthy: iii"
facts "$T/b5" yes no no yes yes healthy
assert_eq "$(w_branch_classify "$T/b5")" branch=iii "some supplied, some fresh: iii"
head -n 2 "$T/b1" > "$T/b6"; echo admission=healthy >> "$T/b6"
assert_fails "two component lines die" w_branch_classify "$T/b6"
grep -v '^admission=' "$T/b1" > "$T/b7"
assert_fails "no admission line dies" w_branch_classify "$T/b7"
```

Run: `just demo cert-hygiene test`
Expected: `test-scenarios` fails with `redact_manifest: command not found`.

- [ ] **Step 2: Implement both in `demos/cert-hygiene/lab/lib-evidence-scenarios.sh`**

```bash
# redact_manifest FILE: FILE with every private key replaced, for recording rendered
# manifests in evidence (private keys never enter the repo). A base64 value that decodes
# to a private key becomes "<redacted sha256=...>"; a literal PEM private-key block
# becomes one "<redacted private key block>" line. Every other line is kept as is.
redact_manifest() {
  local f="${1:?redact_manifest: FILE required}" line in_block=no dec
  [ -f "$f" ] || die "redact_manifest: no file $f"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" = yes ]; then
      if [[ "$line" == *"-----END"*"PRIVATE KEY-----"* ]]; then in_block=no; fi
      continue
    fi
    if [[ "$line" == *"-----BEGIN"*"PRIVATE KEY-----"* ]]; then
      printf '%s<redacted private key block>\n' "${line%%-----BEGIN*}"
      if [[ "$line" != *"-----END"*"PRIVATE KEY-----"* ]]; then in_block=yes; fi
      continue
    fi
    if [[ "$line" =~ ^([[:space:]]*[A-Za-z0-9._-]+:[[:space:]]+)([A-Za-z0-9+/=]{40,})$ ]]; then
      dec="$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d 2>/dev/null | tr -d '\0' || true)"
      if [[ "$dec" == *"PRIVATE KEY"* ]]; then
        printf '%s<redacted sha256=%s>\n' "${BASH_REMATCH[1]}" "$(printf '%s' "${BASH_REMATCH[2]}" | sha256sum | cut -d' ' -f1)"
        continue
      fi
    fi
    printf '%s\n' "$line"
  done < "$f"
}

# w_branch_classify FACTS_FILE: W's declared recovery-branch rule (design section 3).
#   ii  -- every Secret certificate is the supplied one;
#   i   -- none is, and each is valid now and verifies against its caBundle, and the
#          post-propagation admission probes proved all three webhooks;
#   iii -- anything else.
w_branch_classify() {
  local f="${1:?w_branch_classify: FACTS_FILE required}" n
  n="$(grep -c '^component=' "$f" || true)"
  [ "$n" -eq 3 ] || die "w_branch_classify: $f has $n component lines, want 3"
  grep -qE '^admission=(healthy|unhealthy)$' "$f" || die "w_branch_classify: $f has no admission line"
  if [ "$(grep -c '^component=.* equals_supplied=yes ' "$f" || true)" -eq 3 ]; then echo branch=ii; return 0; fi
  if [ "$(grep -cE '^component=.* equals_supplied=no .* valid_now=yes cabundle_verifies=yes$' "$f" || true)" -eq 3 ] \
      && grep -qx admission=healthy "$f"; then
    echo branch=i; return 0
  fi
  echo branch=iii
}
```

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines.

- [ ] **Step 3: Settings in `demos/cert-hygiene/config.example.env`**

Append to the W section (added in Task 11):

```bash
# How long W's recovery waits for all three webhooks to serve correctly after a change.
W_PROPAGATION_TIMEOUT_S=180
# Lifetime of the fresh lab-supplied webhook credentials W's branches ii and iii apply.
W_FRESH_WEBHOOK_LIFETIME=8760h
```

- [ ] **Step 4: Write `demos/cert-hygiene/lab/scenario-webhook.sh`**

```bash
#!/usr/bin/env bash
# Scenario W, shared by 02-webhook-expiry-ignore and 02-webhook-expiry-fail (design
# section 3). Lab-supplied webhook serving certificates expire 10 minutes apart:
# proxy-injector at T1 (= T_mark), policy-validator at T2, sp-validator at T3. Admission
# probes run at baseline and on every tick; each reaches exactly one webhook. Recovery
# starts at T1 + POST_EXPIRY_WINDOW_S and is observed as it branches. Source after
# lab/scenario-common.sh; do not execute.
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"

W_EXPIRED_MARKED=""

_w_not_after() { cert_not_after_epoch "$CERTS/webhooks/$1.crt"; } # COMPONENT

scenario_mark_epoch() { # T1: the proxy-injector certificate's notAfter
  local t1 t3
  t1="$(_w_not_after proxyInjector)"
  t3="$(_w_not_after profileValidator)"
  [ $(( t1 + POST_EXPIRY_WINDOW_S )) -ge $(( t3 + 300 )) ] \
    || die "POST_EXPIRY_WINDOW_S=$POST_EXPIRY_WINDOW_S leaves under 5 minutes after the last webhook expiry"
  echo "$t1"
}

_w_phase() { # TICK: the admission phase for a probe set taken now
  local now
  now="$(date -u +%s)"
  case "$1" in
    baseline) echo baseline ;;
    verify|recover-*) echo recovered ;;
    *) if [ "$now" -lt "$T_MARK" ]; then echo pre-expiry; else printf 'post-%04d\n' $(( now - T_MARK )); fi ;;
  esac
}

_w_mark_expiries() { # TICK: mark each webhook's expiry phase at the first tick after it
  local comp exp now
  now="$(date -u +%s)"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    exp="$(_w_not_after "$comp")"
    if [ "$now" -ge "$exp" ] && [[ " $W_EXPIRED_MARKED " != *" $comp "* ]]; then
      mark webhook-expired "$comp notAfter=$(date -u -d "@$exp" +%Y-%m-%dT%H:%M:%SZ); first tick after it: $1"
      W_EXPIRED_MARKED="$W_EXPIRED_MARKED $comp"
    fi
  done
}

scenario_tick_extra() { # NAME: admission probes on every tick, in the tick's phase
  _w_mark_expiries "$1"
  admission_probes "$(_w_phase "$1")" "$1"
  if [ "$1" = baseline ]; then
    _write_result admission-baseline.txt admission_proof_check "$RUN_DIR/admission/baseline" baseline \
      "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" \
      || die "the healthy baseline did not prove every admission probe; see admission-baseline.txt"
  fi
}

scenario_post_actions() { # T_mark + 60s: admission probes instead of new workloads
  admission_probes "$(_w_phase post-actions)" post-actions
  mark admission-probes post-actions
}

_w_render_apply() { # LABEL [linkerd upgrade args...]: render into the VM-only cert set,
  # record a redacted copy of the complete manifest, then apply it
  local label="$1" m="$CERTS/recover-$1.yaml"
  shift
  capture "recover/$label-render.txt" bash -o pipefail -c "linkerd upgrade $(printf '%q ' "$@") > $(printf '%q' "$m")"
  redact_manifest "$m" > "$RUN_DIR/recover/$label-manifest.yaml" || die "_w_render_apply: cannot redact $m"
  capture "recover/$label-apply.txt" kubectl apply -f "$m"
}

_w_serving_now() { # one line: whether each webhook serves correctly (server-side dry runs)
  local tmp inj=no pol=no sp=no
  tmp="$(mktemp -d)"
  admission_render inject-probe propagation-probe > "$tmp/pod.yaml"
  admission_render policy-invalid propagation-probe > "$tmp/pol.yaml"
  admission_render serviceprofile-invalid propagation-probe > "$tmp/sp.yaml"
  if kubectl create --dry-run=server -o yaml -f "$tmp/pod.yaml" 2>&1 | grep -qE 'name: linkerd-proxy$'; then inj=yes; fi
  if kubectl create --dry-run=server -f "$tmp/pol.yaml" 2>&1 | grep -qF "admission webhook \"$POLICY_VALIDATOR_WEBHOOK_NAME\" denied the request"; then pol=yes; fi
  if kubectl create --dry-run=server -f "$tmp/sp.yaml" 2>&1 | grep -qF "admission webhook \"$SP_VALIDATOR_WEBHOOK_NAME\" denied the request"; then sp=yes; fi
  rm -rf "$tmp"
  echo "injection=$inj policy_denied=$pol sp_denied=$sp"
}

_w_settle() { # LABEL: control-plane rollouts, webhook propagation, then the state
  local f="$RUN_DIR/recover/$1-propagation.txt" deadline s
  capture "recover/$1-rollout.txt" bash -c 'for d in $(kubectl -n linkerd get deploy -o name); do kubectl -n linkerd rollout status "$d" --timeout=300s || exit 1; done'
  deadline=$(( $(date -u +%s) + W_PROPAGATION_TIMEOUT_S ))
  while :; do
    s="$(_w_serving_now)"
    printf '%s %s\n' "$(_utc)" "$s" >> "$f"
    if [ "$s" = "injection=yes policy_denied=yes sp_denied=yes" ]; then mark propagated "$1: all three webhooks serving"; break; fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then mark propagated "$1: not all serving after ${W_PROPAGATION_TIMEOUT_S}s: $s"; break; fi
    sleep 10
  done
  capture "recover/$1-check.txt" linkerd check --wait 20s
  snap_controlplane "recover-$1"
  snap_webhooks "recover-$1"
}

_w_facts() { # LABEL SUPPLIED_DIR: recover/LABEL-facts.txt, the inputs of w_branch_classify
  local label="$1" sup="$2" f="$RUN_DIR/recover/$1-facts.txt" tmp i comp fp sfp exp valid ver now
  tmp="$(mktemp -d)"
  now="$(date -u +%s)"
  : > "$f"
  for i in "${!WEBHOOK_COMPONENTS[@]}"; do
    comp="${WEBHOOK_COMPONENTS[i]}"
    fp=-; exp=-; valid=no; ver=no
    sfp="$(cert_facts s < "$sup/$comp.crt" | awk -F= '$1 == "s_sha256" { print $2 }')"
    if kubectl -n linkerd get secret "$(webhook_secret "$comp")" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
        | base64 -d > "$tmp/$comp.crt" 2>/dev/null && [ -s "$tmp/$comp.crt" ]; then
      fp="$(cert_facts c < "$tmp/$comp.crt" | awk -F= '$1 == "c_sha256" { print $2 }')"
      exp="$(cert_not_after_epoch "$tmp/$comp.crt")"
      if [ "$exp" -gt "$now" ]; then valid=yes; fi
      if kubectl get "${WEBHOOK_CONFIGS[i]}" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null \
          | base64 -d > "$tmp/$comp-ca.pem" 2>/dev/null \
          && openssl verify -partial_chain -CAfile "$tmp/$comp-ca.pem" "$tmp/$comp.crt" > /dev/null 2>&1; then ver=yes; fi
    fi
    printf 'component=%s secret_sha256=%s supplied_sha256=%s equals_supplied=%s not_after_epoch=%s valid_now=%s cabundle_verifies=%s\n' \
      "$comp" "$fp" "$sfp" "$(_yn "$fp" "$sfp")" "$exp" "$valid" "$ver" >> "$f"
  done
  rm -rf "$tmp"
  admission_probes recovered "recover-$label"
  if admission_proof_check "$RUN_DIR/admission/recovered" "recover-$label" \
      "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" >> "$f"; then
    echo admission=healthy >> "$f"
  else
    echo admission=unhealthy >> "$f"
  fi
}

scenario_recover() {
  local branch comp args=()
  snap_controlplane recover-before
  snap_webhooks recover-before
  mark recover-delete "delete the three webhook Secrets (Linkerd's rotating-webhooks guide)"
  capture recover/delete-secrets.txt kubectl -n linkerd delete secret \
    "$(webhook_secret proxyInjector)" "$(webhook_secret policyValidator)" "$(webhook_secret profileValidator)"
  mark recover-plain "plain linkerd upgrade, rendered, redacted, applied"
  _w_render_apply plain
  _w_settle plain
  _w_facts plain "$CERTS/webhooks"
  branch="$(w_branch_classify "$RUN_DIR/recover/plain-facts.txt")"
  {
    echo "$branch"
    echo "rule: ii if every Secret certificate is the supplied one; i if none is and each is valid now, verifies against its caBundle, and the post-propagation admission probes proved all three webhooks; iii otherwise"
    cat "$RUN_DIR/recover/plain-facts.txt"
  } > "$RUN_DIR/recover/branch.txt"
  mark recover-branch "$branch"
  [ "$branch" != branch=i ] || return 0
  make_webhook_certs "$CERTS/webhooks-fresh" \
    "proxyInjector=$W_FRESH_WEBHOOK_LIFETIME policyValidator=$W_FRESH_WEBHOOK_LIFETIME profileValidator=$W_FRESH_WEBHOOK_LIFETIME"
  write_cert webhook-fresh-ca "$CERTS/webhooks-fresh/ca.crt"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do write_cert "webhook-fresh-$comp" "$CERTS/webhooks-fresh/$comp.crt"; done
  mapfile -t args < <(webhook_install_args "$CERTS/webhooks-fresh")
  mark recover-supplied "linkerd upgrade with freshly generated lab-supplied webhook credentials (--set-file)"
  _w_render_apply supplied "${args[@]}"
  _w_settle supplied
  _w_facts supplied "$CERTS/webhooks-fresh"
}
```

`_yn` comes from `gates.sh` (Task 7), which `scenario-common.sh` sources.

- [ ] **Step 5: Write the two scenario files**

`demos/cert-hygiene/scenarios/02-webhook-expiry-ignore.sh`:

```bash
#!/usr/bin/env bash
# Scenario W with Linkerd's default failurePolicy, Ignore (design section 3); the shared
# timeline is in lab/scenario-webhook.sh. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/scenario-webhook.sh"

run_scenario 02-webhook-expiry-ignore webhook-short "${1:?usage: 02-webhook-expiry-ignore.sh <run-dir>}"
```

`demos/cert-hygiene/scenarios/02-webhook-expiry-fail.sh`: the same file, with "Ignore" replaced by "Fail" in the comment, and the last line:

```bash
run_scenario 02-webhook-expiry-fail webhook-short-fail "${1:?usage: 02-webhook-expiry-fail.sh <run-dir>}"
```

- [ ] **Step 6: Syntax, shellcheck, tests, line counts**

Run: `cd demos/cert-hygiene && for f in lab/*.sh scenarios/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/scenario-webhook.sh lab/lib-evidence-scenarios.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh lab/tests/*.sh scenarios/*.sh'`
Expected: no errors; both files under 300 lines; no findings.

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines.

- [ ] **Step 7: Check the redaction against a real render, without applying anything**

Run: `bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && linkerd upgrade > /tmp/w-render.yaml && redact_manifest /tmp/w-render.yaml > /tmp/w-redacted.yaml && grep -c "redacted" /tmp/w-redacted.yaml; grep -c "PRIVATE KEY" /tmp/w-redacted.yaml; rm -f /tmp/w-render.yaml /tmp/w-redacted.yaml'`
(against any lab left up by an earlier task). Expected: a first count of at least 1 (the issuer key, and the webhook keys) and a second count of `0`. `/tmp` in the VM is outside the repo.

- [ ] **Step 8: Commit**

W's evidence runs are Task 21.

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/scenarios demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add webhook-expiry scenarios with staggered expiry and declared recovery branches"
git push
```
