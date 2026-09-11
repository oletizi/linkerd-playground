#!/usr/bin/env bash
# Pure evidence helpers for the cert-hygiene lab: no kubectl, no cluster. The file
# formats they read are the contracts in the implementation plan (Task 4). Source
# after lib/common.sh. Runs inside the lab VM (GNU date, openssl).

# duration_to_seconds D: "15m" / "720h" / "90s" / "1h30m5s" -> seconds. Dies otherwise.
duration_to_seconds() {
  local d="$1" rest="$1" total=0 n unit
  if [ -z "$d" ] || [[ ! "$d" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]]; then
    die "duration_to_seconds: unsupported duration '$d' (use h, m, s in that order)"
  fi
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

# control_criteria_check RUN_DIR: the negative control's pass criteria (design spec
# section 4.4) that a script can judge. Probe lines before the baseline tick are
# startup noise and are ignored. Other check warnings are compared by a human.
control_criteria_check() {
  local run="${1:?control_criteria_check: RUN_DIR required}" bad=0 t p n f
  t="$(awk '$2 == "tick" && $3 == "baseline" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  [ -n "$t" ] || { echo "fail: no baseline tick in timeline.log"; return 1; }
  for p in probe-http probe-tcp-new probe-tcp-stream; do
    f="$run/probes/$p.log"
    if [ ! -s "$f" ]; then echo "fail: $f missing"; bad=1; continue; fi
    n="$(awk -v t="$t" '$1 >= t && / (fail|closed) /' "$f" | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then echo "ok: $p has no fail/closed lines after baseline"
    else echo "fail: $p has $n fail/closed lines after baseline"; bad=1; fi
  done
  n="$(grep -c ' connect ' "$run/probes/probe-tcp-stream.log" 2>/dev/null || true)"
  if [ "$n" = 1 ]; then echo "ok: one stream connection"
  else echo "fail: $n stream connect lines, want 1"; bad=1; fi
  for f in verify-rollout-restart-target verify-rollout-probe-new; do
    if [ "$(tail -n 1 "$run/pods/$f.txt" 2>/dev/null)" = "[exit 0]" ]; then echo "ok: $f completed"
    else echo "fail: $f did not complete"; bad=1; fi
  done
  n="$(grep -l '×' "$run"/checks/*.txt 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no fatal check results"
  else echo "fail: $n check files contain a fatal (×) result"; bad=1; fi
  n="$(grep -lE '‼.*valid for at least 60 days' "$run"/checks/*.txt 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no certificate-lifetime warnings"
  else echo "fail: $n check files carry a certificate-lifetime warning"; bad=1; fi
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
  if [ "$scenario" = 00-baseline-control ]; then
    [ "$(head -n 1 "$run/control-criteria.txt" 2>/dev/null)" = result=ok ] || reasons+=("control criteria not met")
  fi
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
