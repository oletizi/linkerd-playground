# Task 12: Scenario W

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** Design § 3, in two scenario files that share one library: `02-webhook-expiry-ignore` (profile `webhook-short`, Linkerd's default `failurePolicy: Ignore`) and `02-webhook-expiry-fail` (profile `webhook-short-fail`). Anchor and issuer are long-lived, and the traffic probes run throughout (W3).

**Timeline.** The three lab-supplied serving certificates expire 10 minutes apart: proxy-injector at T1 (= T_mark), policy-validator at T2 = T1 + 10 min, sp-validator at T3 = T1 + 20 min. Admission probes (Task 11) run:
- at baseline, phase `baseline` (the proof: the run dies, invalid, if it fails);
- on every tick before T1, phase `pre-expiry`;
- at T_mark + 60 s (`scenario_post_actions`) and on every later tick, phase `post-NNNN`, where NNNN is the seconds since T1, zero-padded;
- after recovery, phase `recovered`.

The first tick that *starts* after each certificate's `notAfter` marks that webhook's expiry phase (`webhook-expired <component> …`, naming the tick and its start time). It compares against `TICK_START_EPOCH` (Task 9), so the phase's first `linkerd check` transcript was always taken after the expiry. Every tick already records the webhook configurations, `failurePolicy`, caBundle hashes, serving-certificate identities (`webhooks/<tick>.txt`) and the `linkerd check` transcripts, so each phase has them.

**Recovery starts after T3 plus W's own post-expiry window**, `W_POST_WINDOW_S=600` (design § 3; Task 9's config). W overrides `scenario_post_window_end` to return T3 + 600 s. Webhook effects are immediate on each admission call, so about 20 per-tick probe rounds after the last expiry are enough, and the run stays bounded.

The phase directories are named `post-NNNN` where the design writes `post-NNN`. This is deliberate and harmless: the seconds after T1 exceed 999 before recovery.

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

**The plain render must really run.** `_w_upgrade_cmd` builds the render command and adds arguments only when there are some. With none, a quoted empty argument would make `linkerd upgrade`, which accepts no arguments, fail and leave an empty manifest; the apply would then fail with the Secrets deleted, and the run would record a harness failure as branch iii. The `w-plain-render` validity rule (Task 3) makes such a run invalid. A run whose plain upgrade fails for Linkerd's own reasons is invalid too. It is still committed, and its write-up reports the failure as what it recorded.

**Private keys.** One recursive test, `_has_key_b64`, serves both redaction and the final guard. It decodes every base64 run of 40 or more characters, and any such run inside the decoded text, up to three layers deep. It then searches the decoded bytes for `PRIVATE KEY`.
- `redact_manifest` redacts every value that test flags, including values nested like `linkerd-config-overrides` (base64 YAML carrying a base64 PEM key).
- `assert_no_keys` runs `b64_key_hits`, the same test over every evidence file, so a key that escaped redaction cannot pass unnoticed.

The unit tests cover:
- a directly encoded key;
- a key whose PEM header doesn't start the encoded text;
- a nested key, in the `linkerd-config-overrides` shape.

**Files:**
- Create: `demos/cert-hygiene/lab/scenario-webhook.sh`, `demos/cert-hygiene/scenarios/02-webhook-expiry-ignore.sh`, `demos/cert-hygiene/scenarios/02-webhook-expiry-fail.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence-scenarios.sh` (add `redact_manifest`, `w_branch_classify`, `b64_key_hits`), `demos/cert-hygiene/lab/tests/test-scenarios.sh`
- Modify: `demos/cert-hygiene/lab/collect.sh` (`assert_no_keys` also runs `b64_key_hits`)
- Modify: `demos/cert-hygiene/config.example.env` (`W_PROPAGATION_TIMEOUT_S`, `W_FRESH_WEBHOOK_LIFETIME`)

**Interfaces:**
- Consumes: Task 9 hooks, Task 11 (`admission_probes`, `admission_render`, `admission_proof_check`), Task 1 (`make_webhook_certs`, `webhook_install_args`, `webhook_secret`, `WEBHOOK_COMPONENTS`), Task 5 (`WEBHOOK_CONFIGS`, `snap_webhooks`, `snap_controlplane`), `cert_facts`, `cert_not_after_epoch`.
- Produces:
  - `_has_key_b64 DEPTH TEXT` (pure) → 0 when TEXT contains `PRIVATE KEY`, directly or inside up to DEPTH layers of base64 runs of 40 or more characters (all-hex runs, which are digests, are skipped).
  - `redact_manifest FILE` (pure) → FILE on stdout. Every `key: value` whose base64 value hides a private key at any depth (`_has_key_b64 3`) becomes `<redacted sha256=<hash of the value>>`. Every literal PEM private-key block becomes one `<redacted private key block>` line. Everything else is byte-identical.
  - `w_branch_classify FACTS_FILE` (pure) → `branch=i|ii|iii` by the rule above. Facts contract: exactly three lines `component=<c> secret_sha256=<hex|-> supplied_sha256=<hex> equals_supplied=<yes|no> not_after_epoch=<epoch|-> valid_now=<yes|no> cabundle_verifies=<yes|no>` and one `admission=<healthy|unhealthy>` line. Dies on any other count.
  - Evidence: `admission-baseline.txt`; `admission/{baseline,pre-expiry,post-NNNN,recovered}/`; timeline markers `webhook-expired`, `admission-probes`, `recover-delete`, `recover-plain`, `propagated`, `recover-branch`, `recover-supplied`; `recover/delete-secrets.txt`; per label (`plain`, and `supplied` for ii/iii): `recover/<label>-render.txt`, `recover/<label>-manifest.yaml` (redacted), `recover/<label>-apply.txt`, `recover/<label>-rollout.txt`, `recover/<label>-propagation.txt`, `recover/<label>-check.txt`, `recover/<label>-facts.txt`, `controlplane/recover-<label>.txt`, `webhooks/recover-<label>.txt`, `admission/recovered/*-recover-<label>.*`; `recover/branch.txt` (first line `branch=…`); `certs/webhook-fresh-*.{pem,txt}` for ii/iii.
  - `b64_key_hits DIR` (pure) → one line per file under DIR for which `_has_key_b64 3` holds on the file's text: a base64 run of 40 or more characters that decodes, directly or through nested base64, to text containing `PRIVATE KEY`. Nothing otherwise.
  - `_w_upgrade_cmd OUT [ARGS...]` → the shell command rendering `linkerd upgrade ARGS` into OUT, with no argument text at all when ARGS is empty.
  - W's `scenario_post_window_end` → T3 + `W_POST_WINDOW_S`.
  - Config: `W_PROPAGATION_TIMEOUT_S=180`, `W_FRESH_WEBHOOK_LIFETIME=8760h` (and `W_POST_WINDOW_S=600` from Task 9).

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

# ---- b64_key_hits ----
mkdir -p "$T/ev/a" "$T/ev/b"
printf 'data:\n  tls.key: %s\n' "$key_b64" > "$T/ev/a/leak.yaml"
printf 'data:\n  tls.crt: %s\n' "$crt_b64" > "$T/ev/b/cert.yaml"
printf '%s\n' "$red" > "$T/ev/b/redacted.yaml"
assert_eq "$(b64_key_hits "$T/ev")" "$T/ev/a/leak.yaml" "only the file holding a base64 private key is reported"
assert_eq "$(b64_key_hits "$T/ev/b")" "" "certificates and redacted manifests pass"
# A key whose PEM header does not start the encoded text (so the encoding never begins
# with the encoding of "-----BEGIN"): found only by decoding every long run.
mkdir -p "$T/ev/c" "$T/ev/d"
shifted="$(printf 'prefix text; -----BEGIN EC PRIVATE KEY-----\nAAAAShiftedFake\n-----END EC PRIVATE KEY-----\n' | base64 -w0)"
printf 'data:\n  blob: %s\n' "$shifted" > "$T/ev/c/shifted.yaml"
assert_eq "$(b64_key_hits "$T/ev/c")" "$T/ev/c/shifted.yaml" "a key not at the start of the encoded text is reported"
# The linkerd-config-overrides shape: base64 YAML whose text carries a base64 PEM key.
outer="$(printf 'identity:\n  issuer:\n    tls:\n      keyPEM: %s\n' "$key_b64" | base64 -w0)"
printf 'data:\n  linkerd-config-overrides: %s\n' "$outer" > "$T/ev/d/overrides.yaml"
assert_eq "$(b64_key_hits "$T/ev/d")" "$T/ev/d/overrides.yaml" "a base64 PEM key nested inside a base64 value is reported"
red2="$(redact_manifest "$T/ev/d/overrides.yaml")"
assert_eq "$(grep -cF "$outer" <<< "$red2")" 0 "the nested key's outer value is redacted"
assert_contains "$red2" "linkerd-config-overrides: <redacted sha256=" "the redaction keeps the key name"

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
# _has_key_b64 DEPTH TEXT: does TEXT contain "PRIVATE KEY", directly or inside up to DEPTH
# layers of base64 (runs of 40+ characters)? All-hex runs are digests, never base64 text,
# and are skipped. Used by redact_manifest and b64_key_hits.
_has_key_b64() {
  local depth="$1" text="$2" run dec
  [[ "$text" != *"PRIVATE KEY"* ]] || return 0
  [ "$depth" -gt 0 ] || return 1
  while IFS= read -r run; do
    [[ ! "$run" =~ ^[0-9a-f]+$ ]] || continue
    dec="$(printf '%s' "$run" | base64 -d 2>/dev/null | tr -d '\0' || true)"
    [ -n "$dec" ] || continue
    if _has_key_b64 $(( depth - 1 )) "$dec"; then return 0; fi
  done < <(printf '%s\n' "$text" | grep -oE '[A-Za-z0-9+/]{40,}={0,2}' || true)
  return 1
}

# redact_manifest FILE: FILE with every private key replaced, for recording rendered
# manifests in evidence (private keys never enter the repo). A base64 value hiding a
# private key at any depth becomes "<redacted sha256=...>"; a literal PEM private-key
# block becomes one "<redacted private key block>" line. Every other line is kept as is.
redact_manifest() {
  local f="${1:?redact_manifest: FILE required}" line in_block=no
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
      local prefix="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
      if _has_key_b64 3 "$value"; then
        printf '%s<redacted sha256=%s>\n' "$prefix" "$(printf '%s' "$value" | sha256sum | cut -d' ' -f1)"
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

# b64_key_hits DIR: files under DIR holding a base64 run (40+ characters) that decodes,
# directly or through nested base64 up to three layers, to text containing "PRIVATE KEY".
# assert_no_keys runs it next to its literal "PRIVATE KEY" search.
b64_key_hits() {
  local d="${1:?b64_key_hits: DIR required}" f
  while IFS= read -r f; do
    if _has_key_b64 3 "$(cat "$f")"; then echo "$f"; fi
  done < <(grep -rlE '[A-Za-z0-9+/]{40,}' "$d" 2>/dev/null || true)
}
```

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines.

Then replace `assert_no_keys` in `demos/cert-hygiene/lab/collect.sh` with:

```bash
assert_no_keys() { # no private key in evidence, as PEM text or base64-encoded
  local hits
  hits="$(grep -rl 'PRIVATE KEY' "$RUN_DIR" 2>/dev/null || true)"
  [ -z "$hits" ] || die "private key material found in evidence: $hits"
  hits="$(b64_key_hits "$RUN_DIR")"
  [ -z "$hits" ] || die "base64-encoded private key material found in evidence: $hits"
}
```

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
# starts at T3 + W_POST_WINDOW_S (scenario_post_window_end) and is observed as it
# branches. Source after lab/scenario-common.sh; do not execute.
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"

W_EXPIRED_MARKED=""

_w_not_after() { cert_not_after_epoch "$CERTS/webhooks/$1.crt"; } # COMPONENT

scenario_mark_epoch() { # T1: the proxy-injector certificate's notAfter
  _w_not_after proxyInjector
}

scenario_post_window_end() { # T3 + W's own post-expiry window (design section 3)
  echo $(( $(_w_not_after profileValidator) + W_POST_WINDOW_S ))
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

_w_mark_expiries() { # TICK: mark each webhook's expiry phase at the first tick that STARTED
  # after it (TICK_START_EPOCH), so that tick's linkerd check ran after the expiry
  local comp exp
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    exp="$(_w_not_after "$comp")"
    if [ "$TICK_START_EPOCH" -ge "$exp" ] && [[ " $W_EXPIRED_MARKED " != *" $comp "* ]]; then
      mark webhook-expired "$comp notAfter=$(date -u -d "@$exp" +%Y-%m-%dT%H:%M:%SZ); first tick starting after it: $1, started $(date -u -d "@$TICK_START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
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

_w_upgrade_cmd() { # OUT [ARGS...]: the shell command rendering `linkerd upgrade ARGS` into
  # OUT. ARGS are quoted only when there are some: an empty quoted argument would make
  # linkerd upgrade (which accepts none) fail and leave an empty manifest.
  local out="$1" q=""
  shift
  [ $# -eq 0 ] || q="$(printf ' %q' "$@")"
  printf 'linkerd upgrade%s > %q\n' "$q" "$out"
}

_w_render_apply() { # LABEL [linkerd upgrade args...]: render into the VM-only cert set,
  # record a redacted copy of the complete manifest, then apply it
  local label="$1" m="$CERTS/recover-$1.yaml"
  shift
  capture "recover/$label-render.txt" bash -o pipefail -c "$(_w_upgrade_cmd "$m" "$@")"
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
  # shellcheck disable=SC2016
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

Run: `cd demos/cert-hygiene && for f in lab/*.sh scenarios/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/scenario-webhook.sh lab/lib-evidence-scenarios.sh lab/collect.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh lab/tests/*.sh scenarios/*.sh'`
Expected: no errors; both files, and `lab/collect.sh`, under 300 lines; no findings.

Run: `just demo cert-hygiene test`
Expected: five `PASS:` lines.

- [ ] **Step 7: Check the render command, the redaction and the decode scan against a real render, without applying anything**

With the Write tool, create `demos/cert-hygiene/.lab-logs/redaction-check.sh` (`.lab-logs/` is git-ignored and never evidence):

```bash
#!/usr/bin/env bash
# One-off check (plan Task 12 Step 7): the render command with and without arguments,
# the redaction, and the base64 key scan, against a real render. Nothing is applied, and
# the unredacted render never leaves the VM's /tmp; the trap removes it on any exit.
set -euo pipefail
# shellcheck source=/dev/null
. lab/scenario-common.sh
# shellcheck source=/dev/null
. lab/scenario-webhook.sh
trap 'rm -rf /tmp/w-render.yaml /tmp/w-red' EXIT
echo "no args:   $(_w_upgrade_cmd /tmp/w-render.yaml)"
echo "with args: $(_w_upgrade_cmd /tmp/w-render.yaml --set-file x=a)"
linkerd upgrade > /tmp/w-render.yaml
mkdir -p /tmp/w-red
redact_manifest /tmp/w-render.yaml > /tmp/w-red/m.yaml
echo "redactions=$(grep -c 'redacted' /tmp/w-red/m.yaml || true)"
echo "private_key_lines=$(grep -c 'PRIVATE KEY' /tmp/w-red/m.yaml || true)"
echo "b64_key_hits=$(b64_key_hits /tmp/w-red | wc -l | tr -d ' ')"
```

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh .lab-logs/redaction-check.sh`, against any lab left up by an earlier task (if none, `just demo cert-hygiene reset long` first).
Expected:
- `no args:   linkerd upgrade > /tmp/w-render.yaml`, with no `''` between `upgrade` and `>`;
- `with args: linkerd upgrade --set-file x=a > /tmp/w-render.yaml`;
- `redactions=` at least `4`: the issuer's `key.pem` and the three webhook `tls.key` values;
- `private_key_lines=0`;
- `b64_key_hits=0`.

If any line differs, fix `scenario-webhook.sh` or `lib-evidence-scenarios.sh` and repeat.

- [ ] **Step 8: Commit**

W's evidence runs are Task 22, after W's discovery runs (Task 19).

```bash
git add demos/cert-hygiene/lab demos/cert-hygiene/scenarios demos/cert-hygiene/config.example.env
git commit -m "cert-hygiene add webhook-expiry scenarios with staggered expiry and declared recovery branches"
git push
```
