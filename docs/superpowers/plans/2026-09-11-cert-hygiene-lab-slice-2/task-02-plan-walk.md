# Task 2: Credential facts and the plan walk (TDD)

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** The pure half of design § 1.3. Extract a certificate's identity (DER SHA-256 fingerprint, serial, `notAfter`, SANs), reduce a tick's credential-state file to a comparable key, and decide whether a run's sequence of credential states walks a declared plan. Test-first, in the VM. Nothing here touches a cluster. `lib-evidence.sh` is at 234 lines, so the new functions go in a new file that it sources.

**The walk rule.** A plan names each state with one label per component, joined by `/`: with components `trust issuer`, `A+B/I2` means trust label `A+B`, issuer label `I2`. Observed states are the per-tick keys with consecutive repeats collapsed. An observed sequence walks a plan alternative when:
1. it has exactly as many states as the alternative (none skipped, none undeclared), and
2. for every component, two positions carry the same label **if and only if** they carry the same observed value.

So `A/I1 → A/I2` accepts "issuer changed once, trust never changed" and rejects a trust change, a second issuer change, or a return to the first issuer. The slice-1 trust-anchor invariant is the special case "the trust label never changes". A plan may list several alternatives; the walk passes if any one matches and names it.

**Files:**
- Create: `demos/cert-hygiene/lab/lib-evidence-plan.sh`
- Create: `demos/cert-hygiene/lab/tests/test-plan.sh`
- Modify: `demos/cert-hygiene/lab/lib-evidence.sh` (source the new file at its end)

**Interfaces:**
- Consumes: `lib/common.sh` (`die`), `lib-evidence.sh` (`cert_not_after_epoch` for tests), `lab/tests/assert.sh`.
- Produces:
  - `cert_facts PREFIX` (PEM on stdin) → five lines: `PREFIX_sha256=<64 lowercase hex, DER SHA-256>`, `PREFIX_serial=<hex as openssl prints it>`, `PREFIX_not_after_epoch=<epoch>`, `PREFIX_not_after=<openssl date text>`, `PREFIX_sans=<DNS:a,DNS:b or ->`. Fails on non-PEM input.
  - Credential-state file contract (`credentials/<tick>.txt`, written by Task 4): `key=value` lines including `trust_roots_sha256=`, `issuer_sha256=`, `webhooks_sha256=`. Any line starting `[` is a recorded failed read.
  - `credential_state_key FILE COMPONENT...` → one line, `trust=<v> issuer=<v> webhooks=<v>` for the requested components (`trust` → `trust_roots_sha256`, `issuer` → `issuer_sha256`, `webhooks` → `webhooks_sha256`). Dies on a failed-read line, a missing or empty key, or an unknown component.
  - Plan file contract: one `components <c>...` line, then one or more `plan <label>...` lines.
  - `credential_plan_walk PLAN_FILE STATE_FILE...` → prints `observed N: <key>` per collapsed state, then `ok: … walk the declared plan: <labels>` or `fail: …`. Returns 0 only on a match. Dies on a malformed plan.

- [ ] **Step 1: Write the failing tests, `demos/cert-hygiene/lab/tests/test-plan.sh`**

```bash
#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-plan.sh. Runs INSIDE the lab VM (GNU date, openssl).
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

# ---- cert_facts ----
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/k.pem" -out "$T/san.pem" \
  -days 1 -subj /CN=svc.example -addext "subjectAltName=DNS:a.example,DNS:b.example" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/k2.pem" -out "$T/nosan.pem" \
  -days 1 -subj /CN=nosan.example >/dev/null 2>&1
facts="$(cert_facts w < "$T/san.pem")"
der="$(openssl x509 -outform DER -in "$T/san.pem" | sha256sum | cut -d' ' -f1)"
assert_contains "$facts" "w_sha256=$der" "fingerprint is the DER SHA-256, lowercase, no colons"
assert_contains "$facts" "w_serial=$(openssl x509 -noout -serial -in "$T/san.pem" | cut -d= -f2)" "serial"
assert_contains "$facts" "w_not_after_epoch=$(cert_not_after_epoch "$T/san.pem")" "notAfter as epoch"
assert_contains "$facts" "w_not_after=$(openssl x509 -noout -enddate -in "$T/san.pem" | cut -d= -f2)" "notAfter as text, the value openssl prints"
assert_contains "$facts" "w_sans=DNS:a.example,DNS:b.example" "SANs, comma-joined"
assert_contains "$(cert_facts n < "$T/nosan.pem")" "n_sans=-" "no SAN extension is recorded as -"
assert_fails "cert_facts rejects non-PEM input" bash -c ". '$ROOT/lib/common.sh'; . '$DEMO/lab/lib-evidence.sh'; echo nope | cert_facts x"

# ---- credential_state_key ----
st() { # FILE TRUST ISSUER [WEBHOOKS]: a credential-state file
  printf 'sampled_at_epoch=1\ntrust_roots_sha256=%s\nissuer_sha256=%s\nissuer_serial=01\n' "$2" "$3" > "$1"
  if [ -n "${4:-}" ]; then printf 'webhooks_sha256=%s\n' "$4" >> "$1"; fi
}
st "$T/s1.txt" t1 i1 w1
assert_eq "$(credential_state_key "$T/s1.txt" trust issuer)" "trust=t1 issuer=i1" "trust and issuer key"
assert_eq "$(credential_state_key "$T/s1.txt" trust issuer webhooks)" "trust=t1 issuer=i1 webhooks=w1" "with webhooks"
st "$T/s2.txt" t1 i1
assert_fails "missing webhooks key dies" credential_state_key "$T/s2.txt" trust issuer webhooks
printf '[issuer Secret crt.pem read failed: exit 1] refused\n' >> "$T/s2.txt"
assert_fails "a recorded failed read dies" credential_state_key "$T/s2.txt" trust issuer
assert_fails "unknown component dies" credential_state_key "$T/s1.txt" anchors

# ---- credential_plan_walk ----
plan() { # FILE COMPONENTS-LINE PLAN-LINE...
  local f="$1" c="$2"
  shift 2
  printf 'components %s\n' "$c" > "$f"
  printf 'plan %s\n' "$@" >> "$f"
}
seq_files() { # DIR SPEC...: one state file per SPEC "trust,issuer[,webhooks]"; prints paths
  local d="$1" n=0 s t i w
  shift
  mkdir -p "$d"
  for s in "$@"; do
    n=$((n + 1)); IFS=, read -r t i w <<< "$s"
    st "$d/$n.txt" "$t" "$i" "$w"
    echo "$d/$n.txt"
  done
}
plan "$T/r.plan" "trust issuer" "A/I1 A/I2"
mapfile -t f < <(seq_files "$T/r-ok" t1,i1 t1,i1 t1,i2 t1,i2)
assert_succeeds "R: one issuer change, repeats collapsed" credential_plan_walk "$T/r.plan" "${f[@]}"
out="$(credential_plan_walk "$T/r.plan" "${f[@]}")"
assert_contains "$out" "observed 2: trust=t1 issuer=i2" "prints the collapsed sequence"
assert_contains "$out" "ok: 2 observed states walk the declared plan: A/I1 A/I2" "names the matched plan"
mapfile -t f < <(seq_files "$T/r-skip" t1,i1 t1,i1)
assert_fails "R: a skipped state fails" credential_plan_walk "$T/r.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/r-extra" t1,i1 t1,i2 t1,i3)
assert_fails "R: an undeclared third issuer fails" credential_plan_walk "$T/r.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/r-anchor" t1,i1 t2,i2)
assert_fails "R: a trust change fails (slice-1 anchor invariant)" credential_plan_walk "$T/r.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/r-back" t1,i1 t1,i2 t1,i1)
assert_fails "R: returning to the first issuer fails" credential_plan_walk "$T/r.plan" "${f[@]}"

plan "$T/one.plan" "trust issuer" "A/I1"
mapfile -t f < <(seq_files "$T/one-ok" t1,i1 t1,i1 t1,i1)
assert_succeeds "single state held throughout" credential_plan_walk "$T/one.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/one-bad" t1,i1 t1,i9)
assert_fails "single-state plan rejects any change" credential_plan_walk "$T/one.plan" "${f[@]}"

plan "$T/s.plan" "trust issuer" "A/I1 A+B/I1 A+B/I2 B/I2"
mapfile -t f < <(seq_files "$T/s-ok" t1,i1 t2,i1 t2,i1 t2,i2 t3,i2)
assert_succeeds "S-staged: four states in order" credential_plan_walk "$T/s.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/s-bad" t1,i1 t2,i1 t2,i2 t1,i2)
assert_fails "S-staged: final trust equal to the first fails (B must differ from A)" credential_plan_walk "$T/s.plan" "${f[@]}"

plan "$T/w.plan" "trust issuer webhooks" "A/I1/W1 A/I1/W2" "A/I1/W1 A/I1/Wg A/I1/W2"
mapfile -t f < <(seq_files "$T/w1" t,i,w1 t,i,w2)
assert_succeeds "W: two webhook states match the first alternative" credential_plan_walk "$T/w.plan" "${f[@]}"
mapfile -t f < <(seq_files "$T/w2" t,i,w1 t,i,w2 t,i,w3)
out="$(credential_plan_walk "$T/w.plan" "${f[@]}")"
assert_contains "$out" "walk the declared plan: A/I1/W1 A/I1/Wg A/I1/W2" "W: three webhook states match the second alternative"
mapfile -t f < <(seq_files "$T/w3" t,i,w1 t,i,w2 t,i,w1)
assert_fails "W: returning to the supplied webhook certs fails" credential_plan_walk "$T/w.plan" "${f[@]}"

mapfile -t f < <(seq_files "$T/unread" t1,i1 t1,i1)
printf '[trust-roots ConfigMap read failed: exit 1] x\n' >> "${f[1]}"
assert_fails "an unreadable state file fails the walk" credential_plan_walk "$T/one.plan" "${f[@]}"
plan "$T/bad.plan" "trust issuer" "A/I1/W1"
assert_fails "a label with the wrong number of components dies" credential_plan_walk "$T/bad.plan" "${f[0]}"
printf 'plan A/I1\n' > "$T/nocomp.plan"
assert_fails "a plan without a components line dies" credential_plan_walk "$T/nocomp.plan" "${f[0]}"

finish test-plan
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence`, then `test-plan` failing with `cert_facts: command not found` (and further FAIL lines), exit non-zero.

- [ ] **Step 3: Write `demos/cert-hygiene/lab/lib-evidence-plan.sh`**

```bash
#!/usr/bin/env bash
# Credential facts and the planned-credential-transition walk (design section 1.3).
# Pure: no kubectl, no cluster. Sourced by lab/lib-evidence.sh; do not execute.

# cert_facts PREFIX: identity facts of the PEM certificate on stdin. The fingerprint is
# the SHA-256 of the DER encoding, lowercase hex without colons.
cert_facts() {
  local p="${1:?cert_facts: PREFIX required}" pem fp serial end epoch sans
  pem="$(cat)"
  fp="$(printf '%s\n' "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null)" \
    || die "cert_facts: stdin is not a PEM certificate"
  fp="${fp#*=}"
  fp="$(printf '%s' "${fp//:/}" | tr 'A-F' 'a-f')"
  serial="$(printf '%s\n' "$pem" | openssl x509 -noout -serial)" || die "cert_facts: cannot read serial"
  end="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate)" || die "cert_facts: cannot read notAfter"
  end="${end#notAfter=}"
  epoch="$(date -u -d "$end" +%s)" || die "cert_facts: cannot parse notAfter '$end'"
  sans="$(printf '%s\n' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
    | awk 'NR > 1 { gsub(/ /, ""); print }' | paste -sd, -)"
  [ -n "$sans" ] || sans=-
  printf '%s_sha256=%s\n%s_serial=%s\n%s_not_after_epoch=%s\n%s_not_after=%s\n%s_sans=%s\n' \
    "$p" "$fp" "$p" "${serial#serial=}" "$p" "$epoch" "$p" "$end" "$p" "$sans"
}

# credential_state_key FILE COMPONENT...: the comparable key of one credential-state
# file (credentials/<tick>.txt). Dies if the collector recorded a failed read in it.
credential_state_key() {
  local f="${1:?credential_state_key: FILE required}" c k v out=()
  shift
  [ $# -ge 1 ] || die "credential_state_key: at least one COMPONENT required"
  if grep -q '^\[' "$f"; then die "credential_state_key: $f records a failed read: $(grep -m1 '^\[' "$f")"; fi
  for c in "$@"; do
    case "$c" in
      trust) k=trust_roots_sha256 ;;
      issuer) k=issuer_sha256 ;;
      webhooks) k=webhooks_sha256 ;;
      *) die "credential_state_key: unknown component '$c'" ;;
    esac
    v="$(grep -m1 "^$k=" "$f" | cut -d= -f2-)"
    [ -n "$v" ] || die "credential_state_key: no $k in $f"
    out+=("$c=$v")
  done
  echo "${out[*]}"
}

_field() { # STRING SEPARATOR INDEX(0-based): one field of STRING
  awk -F"$2" -v i="$(( $3 + 1 ))" '{ print $i }' <<< "$1"
}

# _plan_matches LABELS NCOMP OBSERVED...: the walk rule for one plan alternative.
_plan_matches() {
  local alt="$1" n="$2" labels j k c
  shift 2
  local obs=("$@")
  read -r -a labels <<< "$alt"
  for j in "${labels[@]}"; do
    [ "$(awk -F/ '{ print NF }' <<< "$j")" -eq "$n" ] \
      || die "credential_plan_walk: label '$j' does not have $n components"
  done
  [ "${#labels[@]}" -eq "${#obs[@]}" ] || return 1
  for ((c = 0; c < n; c++)); do
    for ((j = 0; j < ${#obs[@]}; j++)); do
      for ((k = j + 1; k < ${#obs[@]}; k++)); do
        local same_label=no same_value=no
        [ "$(_field "${labels[j]}" / "$c")" != "$(_field "${labels[k]}" / "$c")" ] || same_label=yes
        [ "$(_field "${obs[j]}" ' ' "$c")" != "$(_field "${obs[k]}" ' ' "$c")" ] || same_value=yes
        [ "$same_label" = "$same_value" ] || return 1
      done
    done
  done
  return 0
}

# credential_plan_walk PLAN_FILE STATE_FILE...: do the observed credential states, with
# consecutive repeats collapsed, walk one of the plan's alternatives? Returns 0 if so.
credential_plan_walk() {
  local plan="${1:?credential_plan_walk: PLAN_FILE required}" comps f key prev="" obs=() alt i
  shift
  [ $# -ge 1 ] || die "credential_plan_walk: at least one STATE_FILE required"
  read -r -a comps <<< "$(awk '$1 == "components" { $1 = ""; print; exit }' "$plan")"
  [ "${#comps[@]}" -ge 1 ] || die "credential_plan_walk: no components line in $plan"
  grep -q '^plan ' "$plan" || die "credential_plan_walk: no plan line in $plan"
  for f in "$@"; do
    if ! key="$(credential_state_key "$f" "${comps[@]}")"; then
      echo "fail: $f has no usable credential state"
      return 1
    fi
    [ "$key" = "$prev" ] || obs+=("$key")
    prev="$key"
  done
  for i in "${!obs[@]}"; do echo "observed $(( i + 1 )): ${obs[i]}"; done
  while read -r alt; do
    if _plan_matches "$alt" "${#comps[@]}" "${obs[@]}"; then
      echo "ok: ${#obs[@]} observed states walk the declared plan: $alt"
      return 0
    fi
  done < <(awk '$1 == "plan" { $1 = ""; sub(/^ /, ""); print }' "$plan")
  echo "fail: ${#obs[@]} observed states match no declared plan ($(awk '$1 == "plan"' "$plan" | wc -l | tr -d ' ') alternatives)"
  return 1
}
```

A malformed label makes `_plan_matches` die inside the `while` loop's body, which runs in the current shell, so the walk exits non-zero; the test for it expects failure.

- [ ] **Step 4: Source it from `demos/cert-hygiene/lab/lib-evidence.sh`**

Append to the end of `lib-evidence.sh`:

```bash

# The rest of the evidence library, split by concern to keep each file short.
_EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-plan.sh"
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence` and `PASS: test-plan`, exit 0. Fix the library, not the test, unless the test contradicts this task's Interfaces block.

- [ ] **Step 6: Shellcheck**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/lib-evidence.sh lab/lib-evidence-plan.sh lab/tests/*.sh'`
Expected: no findings.

- [ ] **Step 7: Update the article README and commit**

No README status change (the Task 1 bullet still describes the state).

```bash
git add demos/cert-hygiene/lab/lib-evidence.sh demos/cert-hygiene/lab/lib-evidence-plan.sh demos/cert-hygiene/lab/tests/test-plan.sh
git commit -m "cert-hygiene add tested credential facts and plan walk"
git push
```
