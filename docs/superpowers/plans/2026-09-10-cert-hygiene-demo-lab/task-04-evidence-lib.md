# Task 4: Evidence library (TDD)

Part of the [cert-hygiene demo lab plan](README.md). Read its Global Constraints first.

**Goal:** Write the pure functions that decide evidence validity (spec § 5) and turn raw artifacts into facts: durations, certificate metadata, metric values, the leaf-lifetime check, the trust-anchor invariant, and `validity.txt`. Test-first, in the lab VM. Nothing here touches a cluster.

**Files:**
- Create: `demos/cert-hygiene/lab/lib-evidence.sh`
- Create: `demos/cert-hygiene/lab/tests/assert.sh`, `demos/cert-hygiene/lab/tests/test-evidence.sh`, `demos/cert-hygiene/lab/tests/run.sh`
- Modify: `demos/cert-hygiene/Justfile` (add `test`)

**Interfaces:**
- Consumes: `lib/common.sh` (`die`); Task 1's `scripts/in-lab.sh`
- Produces. These file formats are **contracts** that the collector (Task 6), the host launcher (Task 7), and the scenarios (Tasks 7–8) must write exactly:
  - `timeline.log`: one line per marker, `<UTC ISO-8601> <phase> [detail...]`. Snapshot ticks are `<UTC> tick <name>`. A finished run's last line is `<UTC> done`; an aborted run's is `<UTC> aborted <reason>`.
  - `git-state.txt`: `demo_repo_commit=<sha>`, `demo_repo_dirty=true|false`, `harness_tree_sha256=<hex>`.
  - `versions.txt`: contains at least `linkerd_cli_version=<v>` and `linkerd_controller_image=<image:tag>`.
  - `leaf-lifetime.txt` and `trust-invariant.txt`: first line `result=ok` or `result=fail`, then detail lines.
  - `trust/<tick>.txt`: first line `configmap_sha256=<hex>`, then one line per pod, `<ns>/<pod> <trust-root-sha256 annotation or ->`.
  - Per tick `<t>`: `checks/<t>-check.txt`, `checks/<t>-check-proxy.txt`, `metrics/<t>.txt`, `pods/<t>.txt`.
  - `validity.txt`: `evidence_valid=yes`, or `evidence_valid=no` followed by `reason=<text>` lines.
- Functions:
  - `duration_to_seconds D` → prints an integer. Accepts `Nh`, `Nm`, `Ns`, and combinations in that order. Dies otherwise.
  - `cert_not_after_epoch PEM_FILE` → prints epoch seconds.
  - `cert_meta` (reads a PEM on stdin) → prints `serial=`, `sha256 Fingerprint=`, `notBefore=`, `notAfter=`, `subject=`, `issuer=` lines.
  - `metric_values METRIC FILE` → prints each sample value of METRIC (labelled or not), one per line.
  - `leaf_lifetime_check METRIC NOW MAX_S FILE...` → prints `ok …` / `fail …` per value. Returns 1 if any value is outside `(NOW, NOW+MAX_S]` or the metric is absent from a file.
  - `trust_summary FILE` and `trust_invariant_check FILE FILE...` → the latter prints `ok: …` or `fail: …` and returns 1 on any difference.
  - `evaluate_validity RUN_DIR SCENARIO EXPECTED_LINKERD_VERSION [CONTROL_RUNS_DIR]` → writes `RUN_DIR/validity.txt`. Returns 0 only if valid.

- [ ] **Step 1: Write `demos/cert-hygiene/lab/tests/assert.sh`**

```bash
#!/usr/bin/env bash
# Minimal assertions for the lab's bash unit tests. Source; do not execute.
FAILS=0
assert_eq() { # actual expected message
  [ "$1" = "$2" ] || { printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1"; FAILS=$((FAILS + 1)); }
}
assert_contains() { # haystack needle message
  case "$1" in *"$2"*) ;; *) printf 'FAIL: %s\n  [%s] not found in:\n%s\n' "$3" "$2" "$1"; FAILS=$((FAILS + 1)) ;; esac
}
assert_succeeds() { # message command...
  local msg="$1"; shift
  ( "$@" ) >/dev/null 2>&1 || { printf 'FAIL: %s (expected success: %s)\n' "$msg" "$*"; FAILS=$((FAILS + 1)); }
}
assert_fails() { # message command...
  local msg="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then printf 'FAIL: %s (expected failure: %s)\n' "$msg" "$*"; FAILS=$((FAILS + 1)); fi
}
finish() { # suite-name
  if [ "$FAILS" -eq 0 ]; then echo "PASS: $1"; else echo "FAILED: $1 ($FAILS failures)"; exit 1; fi
}
```

- [ ] **Step 2: Write `demos/cert-hygiene/lab/tests/run.sh`**

```bash
#!/usr/bin/env bash
# Runs INSIDE the lab VM. Runs every lab/tests/test-*.sh; exits non-zero if any fails.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$TESTS"/test-*.sh; do
  bash "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 3: Write the failing tests, `demos/cert-hygiene/lab/tests/test-evidence.sh`**

```bash
#!/usr/bin/env bash
# Unit tests for lab/lib-evidence.sh. Runs INSIDE the lab VM (GNU date, openssl).
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

# ---- duration_to_seconds ----
assert_eq "$(duration_to_seconds 15m)" 900 "15m"
assert_eq "$(duration_to_seconds 720h)" 2592000 "720h"
assert_eq "$(duration_to_seconds 90s)" 90 "90s"
assert_eq "$(duration_to_seconds 1h30m5s)" 5405 "1h30m5s"
assert_fails "rejects unknown unit" duration_to_seconds 15x
assert_fails "rejects empty" duration_to_seconds ""
assert_fails "rejects out-of-order units" duration_to_seconds 5m1h

# ---- cert_not_after_epoch / cert_meta ----
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 1 -subj /CN=unit-test >/dev/null 2>&1
now="$(date -u +%s)"
got="$(cert_not_after_epoch "$T/c.pem")"
delta=$(( got - now - 86400 ))
[ "$delta" -ge -5 ] && [ "$delta" -le 5 ]
assert_eq "$?" 0 "cert_not_after_epoch is now+1d (delta ${delta}s)"
meta="$(cert_meta < "$T/c.pem")"
assert_contains "$meta" "notAfter=" "cert_meta prints notAfter"
assert_contains "$meta" "serial=" "cert_meta prints serial"
assert_contains "$meta" "Fingerprint=" "cert_meta prints the fingerprint"
assert_contains "$meta" "CN=unit-test" "cert_meta prints the subject"
assert_fails "cert_meta rejects non-PEM input" bash -c ". '$ROOT/lib/common.sh'; . '$DEMO/lab/lib-evidence.sh'; echo nope | cert_meta"

# ---- metric_values ----
cat > "$T/m1.txt" <<'EOF'
identity_cert_expiration_timestamp_seconds 1800000300
identity_cert_refreshes_total 4
EOF
cat > "$T/m2.txt" <<'EOF'
identity_cert_expiration_timestamp_seconds{pod="a"} 1.8000002e9
identity_cert_expiration_timestamp_seconds_other 7
EOF
assert_eq "$(metric_values identity_cert_expiration_timestamp_seconds "$T/m1.txt")" 1800000300 "unlabelled sample"
assert_eq "$(metric_values identity_cert_expiration_timestamp_seconds "$T/m2.txt")" 1.8000002e9 "labelled sample; no prefix match"

# ---- leaf_lifetime_check ----
M=identity_cert_expiration_timestamp_seconds
assert_succeeds "within bound" leaf_lifetime_check "$M" 1800000000 320 "$T/m1.txt" "$T/m2.txt"
assert_fails "beyond bound" leaf_lifetime_check "$M" 1800000000 100 "$T/m1.txt"
assert_fails "already expired" leaf_lifetime_check "$M" 1800000400 320 "$T/m1.txt"
printf 'unrelated_metric 1\n' > "$T/m3.txt"
assert_fails "metric absent" leaf_lifetime_check "$M" 1800000000 320 "$T/m3.txt"
out="$(leaf_lifetime_check "$M" 1800000000 100 "$T/m1.txt")"
assert_contains "$out" "fail" "failure is reported, not just returned"

# ---- trust_invariant_check ----
printf 'configmap_sha256=aaa\nlab/server-1 h1\nkube-system/coredns -\n' > "$T/t1.txt"
printf 'configmap_sha256=aaa\nlab/server-1 h1\nlab/probe-new-9 h1\n' > "$T/t2.txt"
printf 'configmap_sha256=bbb\nlab/server-1 h1\n' > "$T/t3.txt"
printf 'configmap_sha256=aaa\nlab/server-1 h1\nlab/probe-new-9 h2\n' > "$T/t4.txt"
assert_succeeds "same bundle, pods added" trust_invariant_check "$T/t1.txt" "$T/t2.txt"
assert_fails "configmap hash changed" trust_invariant_check "$T/t1.txt" "$T/t3.txt"
assert_fails "a pod carries a second bundle" trust_invariant_check "$T/t1.txt" "$T/t4.txt"

# ---- evaluate_validity ----
make_run() { # dir scenario commit harness dirty
  local d="$1"
  mkdir -p "$d/certs" "$d/checks" "$d/metrics" "$d/pods"
  printf 'demo_repo_commit=%s\ndemo_repo_dirty=%s\nharness_tree_sha256=%s\n' "$3" "$5" "$4" > "$d/git-state.txt"
  printf 'linkerd_cli_version=edge-26.9.1\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$d/versions.txt"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n2026-09-10T10:40:00Z tick verify\n2026-09-10T10:41:00Z done\n' > "$d/timeline.log"
  local t f
  for t in baseline verify; do
    for f in "checks/$t-check.txt" "checks/$t-check-proxy.txt" "metrics/$t.txt" "pods/$t.txt"; do echo x > "$d/$f"; done
  done
  for f in trust-anchor issuer-initial issuer-replacement; do echo x > "$d/certs/$f.pem"; echo x > "$d/certs/$f.txt"; done
  printf 'result=ok\n' > "$d/leaf-lifetime.txt"
  printf 'result=ok\n' > "$d/trust-invariant.txt"
}
V=edge-26.9.1
make_run "$T/ctl/r1" 00-baseline-control c1 h1 false
assert_succeeds "clean control run is valid" evaluate_validity "$T/ctl/r1" 00-baseline-control "$V"
assert_eq "$(head -n1 "$T/ctl/r1/validity.txt")" evidence_valid=yes "validity.txt says yes"

make_run "$T/r5" 05-issuer-expiry c2 h1 false
assert_succeeds "#5 valid with a valid control at the same harness tree" evaluate_validity "$T/r5" 05-issuer-expiry "$V" "$T/ctl"

make_run "$T/r5b" 05-issuer-expiry c3 h2 false
assert_fails "#5 invalid when no control matches its harness tree" evaluate_validity "$T/r5b" 05-issuer-expiry "$V" "$T/ctl"
assert_contains "$(cat "$T/r5b/validity.txt")" "reason=no valid 00-baseline-control run" "reason names the missing control"

make_run "$T/dirty" 00-baseline-control c1 h1 true
assert_fails "dirty tree is never evidence" evaluate_validity "$T/dirty" 00-baseline-control "$V"

make_run "$T/gap" 00-baseline-control c1 h1 false
rm "$T/gap/checks/verify-check-proxy.txt"
assert_fails "a tick missing a check is invalid" evaluate_validity "$T/gap" 00-baseline-control "$V"
assert_contains "$(cat "$T/gap/validity.txt")" "tick verify missing checks/verify-check-proxy.txt" "reason names the gap"

make_run "$T/abort" 00-baseline-control c1 h1 false
printf '2026-09-10T10:20:00Z aborted probes never became ready\n' >> "$T/abort/timeline.log"
assert_fails "an aborted run is invalid" evaluate_validity "$T/abort" 00-baseline-control "$V"

make_run "$T/ver" 00-baseline-control c1 h1 false
printf 'linkerd_cli_version=edge-26.7.2\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$T/ver/versions.txt"
assert_fails "wrong CLI version is invalid" evaluate_validity "$T/ver" 00-baseline-control "$V"

make_run "$T/leaf" 00-baseline-control c1 h1 false
printf 'result=fail\nfail x\n' > "$T/leaf/leaf-lifetime.txt"
assert_fails "failed leaf-lifetime check is invalid" evaluate_validity "$T/leaf" 00-baseline-control "$V"

make_run "$T/trust" 05-issuer-expiry c2 h1 false
printf 'result=fail\n' > "$T/trust/trust-invariant.txt"
assert_fails "broken trust invariant is invalid" evaluate_validity "$T/trust" 05-issuer-expiry "$V" "$T/ctl"

make_run "$T/norep" 05-issuer-expiry c2 h1 false
rm "$T/norep/certs/issuer-replacement.pem"
assert_fails "#5 without the replacement issuer is invalid" evaluate_validity "$T/norep" 05-issuer-expiry "$V" "$T/ctl"

finish test-evidence
```

- [ ] **Step 4: Add the `test` verb to `demos/cert-hygiene/Justfile`**

Append:

```just

# Unit tests for the lab's evidence helpers (run inside the lab machine)
test:
    bash scripts/in-lab.sh lab/tests/run.sh
```

- [ ] **Step 5: Run the tests and confirm they fail**

Run: `just demo cert-hygiene test`
Expected: a non-zero exit, with an error that `lab/lib-evidence.sh` does not exist.

- [ ] **Step 6: Write `demos/cert-hygiene/lab/lib-evidence.sh`**

```bash
#!/usr/bin/env bash
# Pure evidence helpers for the cert-hygiene lab: no kubectl, no cluster. The file
# formats they read are the contracts in the implementation plan (Task 4). Source
# after lib/common.sh. Runs inside the lab VM (GNU date, openssl).

# duration_to_seconds D: "15m" / "720h" / "90s" / "1h30m5s" -> seconds. Dies otherwise.
duration_to_seconds() {
  local d="$1" rest="$1" total=0 n unit
  [ -n "$d" ] && [[ "$d" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]] \
    || die "duration_to_seconds: unsupported duration '$d' (use h, m, s in that order)"
  while [[ "$rest" =~ ^([0-9]+)([hms])(.*)$ ]]; do
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    case "$unit" in
      h) total=$((total + n * 3600)) ;;
      m) total=$((total + n * 60)) ;;
      s) total=$((total + n)) ;;
    esac
  done
  echo "$total"
}

# cert_not_after_epoch PEM_FILE: the certificate's notAfter as epoch seconds.
cert_not_after_epoch() {
  local pem="${1:?cert_not_after_epoch: PEM_FILE required}" end
  end="$(openssl x509 -noout -enddate -in "$pem")" || die "cert_not_after_epoch: cannot read $pem"
  date -u -d "${end#notAfter=}" +%s
}

# cert_meta: metadata of the PEM certificate on stdin -- never anything secret.
cert_meta() {
  openssl x509 -noout -serial -fingerprint -sha256 -startdate -enddate -subject -issuer -nameopt RFC2253
}

# metric_values METRIC FILE: each sample value of METRIC in a Prometheus text dump.
# Matches `METRIC value` and `METRIC{labels} value`; never a longer metric name.
metric_values() {
  local metric="${1:?metric_values: METRIC required}" file="${2:?metric_values: FILE required}"
  awk -v m="$metric" '$1 == m || index($1, m "{") == 1 { print $NF }' "$file"
}

# leaf_lifetime_check METRIC NOW MAX_S FILE...: every METRIC value in every file must
# lie in (NOW, NOW+MAX_S]. Guards against Linkerd silently replacing an unparseable
# --identity-issuance-lifetime with 24h. Prints one ok/fail line per value.
leaf_lifetime_check() {
  local metric="${1:?}" now="${2:?}" max_s="${3:?}" f v vals bad=0
  shift 3
  [ $# -ge 1 ] || die "leaf_lifetime_check: at least one metrics file required"
  for f in "$@"; do
    vals="$(metric_values "$metric" "$f")"
    if [ -z "$vals" ]; then
      echo "fail $f: $metric absent"; bad=1; continue
    fi
    while read -r v; do
      if awk -v v="$v" -v now="$now" -v max="$max_s" 'BEGIN { exit !(v > now && v - now <= max) }'; then
        echo "ok $f: expires $(awk -v v="$v" -v now="$now" 'BEGIN { printf "%d", v - now }')s after now (bound ${max_s}s)"
      else
        echo "fail $f: $metric=$v not in (now, now+${max_s}s] with now=$now"; bad=1
      fi
    done <<< "$vals"
  done
  return "$bad"
}

# trust_summary FILE: the trust-roots ConfigMap hash plus the distinct trust-bundle
# annotations carried by pods (pods without one are ignored).
trust_summary() {
  local f="${1:?trust_summary: FILE required}"
  grep -m1 '^configmap_sha256=' "$f" || die "trust_summary: no configmap_sha256 line in $f"
  printf 'annotations=%s\n' "$(awk 'NR > 1 && $2 != "-" { print $2 }' "$f" | sort -u | paste -sd, -)"
}

# trust_invariant_check FILE FILE...: the trust configuration must be identical in
# every snapshot. Recovery in scenario #5 replaces the issuer, never the anchor.
trust_invariant_check() {
  [ $# -ge 2 ] || die "trust_invariant_check: two or more snapshots required"
  local first="$1" ref f bad=0
  ref="$(trust_summary "$first")"
  shift
  for f in "$@"; do
    if [ "$(trust_summary "$f")" != "$ref" ]; then
      echo "fail: $f differs from $first"
      diff <(printf '%s\n' "$ref") <(trust_summary "$f") || true
      bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then echo "ok: trust configuration identical across $(( $# + 1 )) snapshots"; fi
  return "$bad"
}

_kv() { # KEY FILE: the value of KEY=... in FILE, or nothing
  grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2-
}

_control_passed() { # CONTROL_RUNS_DIR HARNESS_TREE_SHA
  local dir="$1" tree="$2" v
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  for v in "$dir"/*/validity.txt; do
    [ -f "$v" ] || continue
    [ "$(head -n 1 "$v")" = evidence_valid=yes ] || continue
    [ "$(_kv harness_tree_sha256 "$(dirname "$v")/git-state.txt")" = "$tree" ] && return 0
  done
  return 1
}

# evaluate_validity RUN_DIR SCENARIO EXPECTED_LINKERD_VERSION [CONTROL_RUNS_DIR]:
# decide mechanically whether a run is valid evidence (design spec section 5) and
# write RUN_DIR/validity.txt. Says nothing about hypotheses H1-H8.
evaluate_validity() {
  local run="${1:?}" scenario="${2:?}" expected="${3:?}" control_dir="${4:-}"
  local reasons=() f tick
  local required=(versions.txt git-state.txt timeline.log leaf-lifetime.txt trust-invariant.txt
    certs/trust-anchor.pem certs/trust-anchor.txt certs/issuer-initial.pem certs/issuer-initial.txt)
  if [ "$scenario" = 05-issuer-expiry ]; then
    required+=(certs/issuer-replacement.pem certs/issuer-replacement.txt)
  fi

  [ "$(_kv demo_repo_dirty "$run/git-state.txt")" = false ] || reasons+=("dirty harness tree, or git-state.txt missing")
  for f in "${required[@]}"; do
    [ -s "$run/$f" ] || reasons+=("missing $f")
  done
  tail -n 1 "$run/timeline.log" 2>/dev/null | grep -qE '^[^ ]+ done$' || reasons+=("timeline does not end in done")
  while read -r tick; do
    for f in "checks/$tick-check.txt" "checks/$tick-check-proxy.txt" "metrics/$tick.txt" "pods/$tick.txt"; do
      [ -s "$run/$f" ] || reasons+=("tick $tick missing $f")
    done
  done < <(awk '$2 == "tick" { print $3 }' "$run/timeline.log" 2>/dev/null)
  [ "$(head -n 1 "$run/leaf-lifetime.txt" 2>/dev/null)" = result=ok ] || reasons+=("effective leaf lifetime check did not pass")
  [ "$(head -n 1 "$run/trust-invariant.txt" 2>/dev/null)" = result=ok ] || reasons+=("trust-anchor invariant did not hold")
  [ "$(_kv linkerd_cli_version "$run/versions.txt")" = "$expected" ] || reasons+=("linkerd CLI is not $expected")
  case "$(_kv linkerd_controller_image "$run/versions.txt")" in
    *":$expected") ;;
    *) reasons+=("control plane is not $expected") ;;
  esac
  if [ "$scenario" = 05-issuer-expiry ]; then
    local tree
    tree="$(_kv harness_tree_sha256 "$run/git-state.txt")"
    _control_passed "$control_dir" "$tree" || reasons+=("no valid 00-baseline-control run with harness tree $tree")
  fi

  if [ ${#reasons[@]} -eq 0 ]; then
    echo evidence_valid=yes > "$run/validity.txt"
    return 0
  fi
  { echo evidence_valid=no; printf 'reason=%s\n' "${reasons[@]}"; } > "$run/validity.txt"
  return 1
}
```

- [ ] **Step 7: Run the tests and confirm they pass**

Run: `just demo cert-hygiene test`
Expected: `PASS: test-evidence`, exit 0. On any `FAIL:` line, fix `lib-evidence.sh` (not the test) unless the test contradicts this task's Interfaces block.

- [ ] **Step 8: Shellcheck**

Run: `cd demos/cert-hygiene && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/lib-evidence.sh lab/tests/*.sh'`
Expected: no findings.

- [ ] **Step 9: Update the article README and commit**

In `docs/articles/cert-hygiene/README.md`, set the `Lab harness` row to `In progress: evidence validity library tested (plan Task 4 of 9)`.

```bash
git add demos/cert-hygiene/lab/lib-evidence.sh demos/cert-hygiene/lab/tests demos/cert-hygiene/Justfile docs/articles/cert-hygiene/README.md
git commit -m "cert-hygiene add tested evidence validity helpers"
git push
```
