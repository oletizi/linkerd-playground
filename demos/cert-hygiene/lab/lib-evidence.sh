#!/usr/bin/env bash
# Pure evidence helpers for the cert-hygiene lab: no kubectl, no cluster. The file
# formats they read are the contracts in the implementation plan (slice-1 plan Task 4;
# slice-2 plan Tasks 2–3). Source after lib/common.sh. Runs inside the lab VM (GNU
# date, openssl).

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

# _probe_lines DIR PROBE: every line PROBE wrote (field 2 is the probe name), from the
# current and previous logs of all its pods under DIR. Never fails.
_probe_lines() {
  local dir="$1" p="$2" f
  for f in "$dir"/*.log; do
    [ -f "$f" ] || continue
    awk -v p="$p" '$2 == p' "$f"
  done
  return 0
}

_kv() { # KEY FILE: the value of KEY=... in FILE, or nothing
  grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2-
}

_control_passed() { # CONTROL_RUNS_DIR HARNESS_TREE_SHA: a valid 00-baseline-control at
  # HARNESS_TREE_SHA, proved either from a run directory still on disk or from a
  # committed manifest (tools/evidence-upload.sh). Both are checked because the publish
  # workflow deletes a control's local copy once it is uploaded -- so a control that was
  # published and whose directory is gone must still satisfy this rule from its
  # manifest's header alone, with nothing materialised -- while a control still on disk
  # (not yet published, or Task 5's own directory-moved-aside check) must keep working
  # exactly as before. Neither source is required when the other already proves it.
  local dir="$1" tree="$2" v m
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  for v in "$dir"/*/validity.txt; do
    [ -f "$v" ] || continue
    [ "$(head -n 1 "$v")" = evidence_valid=yes ] || continue
    [ "$(_kv harness_tree_sha256 "$(dirname "$v")/git-state.txt")" = "$tree" ] && return 0
  done
  for m in "$dir"/*.manifest.txt; do
    [ -f "$m" ] || continue
    [ "$(_kv validity_evidence_valid "$m")" = yes ] || continue
    [ "$(_kv harness_tree_sha256 "$m")" = "$tree" ] && return 0
  done
  return 1
}

# The rest of the evidence library, split by concern to keep each file short.
_EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-plan.sh"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-rules.sh"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-control.sh"
# shellcheck source=/dev/null
. "$_EVIDENCE_DIR/lib-evidence-scenarios.sh"
