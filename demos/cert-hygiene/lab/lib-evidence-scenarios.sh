#!/usr/bin/env bash
# Scenario-specific pure rules: W's admission proof (and, from later tasks, W's recovery
# branch and manifest redaction, K's remaining validity, S-hard's stage-1 condition).
# No kubectl. Sourced by lab/lib-evidence.sh; do not execute.

_last_line() { tail -n 1 "$1" 2>/dev/null; } # FILE

# admission_denied_by NAME FILE: was the object recorded in the response FILE denied by
# the validator NAME, with its own message (design section 3)? A CRD-schema rejection
# (some other non-zero exit) does not count. The one place this check is made; also
# used by discover-admission.sh and Task 12's _w_serving_now.
admission_denied_by() {
  local name="${1:?admission_denied_by: NAME required}" f="${2:?admission_denied_by: FILE required}"
  [ -f "$f" ] && [ "$(_last_line "$f")" != "[exit 0]" ] && grep -qF "admission webhook \"$name\" denied the request" "$f"
}

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
    if admission_denied_by "${o#*:}" "$f"; then
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
  done < <(printf '%s\n' "$text" | LC_ALL=C grep -aoE '[A-Za-z0-9+/]{40,}={0,2}' || true)
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
# A component whose Secret certificate w_fact_line recorded as "unreadable" is neither
# the supplied certificate nor valid-and-verifying, so it always makes the branch iii.
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

# w_fact_line COMPONENT SUPPLIED_SHA256 SECRET_CERT CABUNDLE NOW: one webhook's facts line
# for w_branch_classify. SECRET_CERT is the Secret's decoded tls.crt and CABUNDLE its
# webhook configuration's decoded caBundle; either may be empty (not read). No
# certificate records "-". A non-empty value that is not a readable certificate records
# "unreadable" in its fingerprint and every field depending on it: a failed read is
# recorded, never fatal. Certificates compare by X.509 fingerprint and verify with openssl
# against the caBundle, never by raw bytes: the caBundle loses its PEM's trailing newline
# in the Helm/API round trip (Task 1 discovery).
w_fact_line() {
  local comp="${1:?}" sfp="${2:?}" crt="${3:?}" ca="${4:?}" now="${5:?}" facts fp=- eq=no exp=- valid=no ver=no
  if [ -s "$crt" ]; then
    if facts="$(cert_facts c < "$crt" 2>/dev/null)"; then
      fp="$(awk -F= '$1 == "c_sha256" { print $2 }' <<< "$facts")"
      exp="$(awk -F= '$1 == "c_not_after_epoch" { print $2 }' <<< "$facts")"
      if [ "$fp" = "$sfp" ]; then eq=yes; fi
      if [ "$exp" -gt "$now" ]; then valid=yes; fi
      if [ -s "$ca" ] && openssl verify -partial_chain -CAfile "$ca" "$crt" > /dev/null 2>&1; then ver=yes; fi
    else
      fp=unreadable; eq=unreadable; exp=unreadable; valid=unreadable; ver=unreadable
    fi
  fi
  printf 'component=%s secret_sha256=%s supplied_sha256=%s equals_supplied=%s not_after_epoch=%s valid_now=%s cabundle_verifies=%s\n' \
    "$comp" "$fp" "$sfp" "$eq" "$exp" "$valid" "$ver"
}

# b64_key_hits DIR: files under DIR (or DIR itself, if a file) holding a base64 run (40+
# characters) that decodes, directly or through nested base64 up to three layers, to text
# containing "PRIVATE KEY". Byte-safe: LC_ALL=C grep -a, so no byte hides a match.
b64_key_hits() {
  local d="${1:?b64_key_hits: DIR required}" f
  while IFS= read -r f; do
    if _has_key_b64 3 "$(tr -d '\0' < "$f")"; then echo "$f"; fi
  done < <(LC_ALL=C grep -rlaE '[A-Za-z0-9+/]{40,}' "$d" 2>/dev/null || true)
}

# key_scan PATH: every private key under PATH (a directory, or one file), one line per
# hit: literal PEM key text, then base64 decoding to a key (b64_key_hits). Returns 1 on
# any hit. Fails closed: dies if PATH is missing or anything under it is unreadable. The
# one scan behind assert_no_keys, lab/key-guard.sh and W's manifest redaction.
key_scan() {
  local p="${1:?key_scan: PATH required}" pem b64 rc=0 f
  [ -e "$p" ] || die "key_scan: no such path $p"
  pem="$(LC_ALL=C grep -rlaF 'PRIVATE KEY' "$p")" || rc=$?
  [ "$rc" -le 1 ] || die "key_scan: cannot read everything under $p (grep exit $rc)"
  b64="$(b64_key_hits "$p")"
  [ -n "$pem$b64" ] || return 0
  if [ -n "$pem" ]; then while IFS= read -r f; do echo "private key PEM text: $f"; done <<< "$pem"; fi
  if [ -n "$b64" ]; then while IFS= read -r f; do echo "base64-encoded private key: $f"; done <<< "$b64"; fi
  return 1
}

# k_remaining_check RUN_DIR: do K's two measurements fall on opposite sides of 60 days
# (5184000 s) at the moment each check ran (design section 5)? Conservative: the -10m
# step is judged at each command's start, the +10m step at each command's end.
k_remaining_check() {
  local run="${1:?k_remaining_check: RUN_DIR required}" bad=0 step f na th c s e rem t
  for step in minus plus; do
    f="$run/k/$step-calc.txt"
    if [ ! -s "$f" ]; then echo "fail: $f missing"; bad=1; continue; fi
    na="$(_kv issuer_not_after_epoch "$f")"
    th="$(_kv threshold_s "$f")"
    [ "$th" = 5184000 ] || { echo "fail: $f threshold_s=$th, want 5184000"; bad=1; continue; }
    for c in check check_proxy; do
      t="$run/k/$step-${c//_/-}.txt"
      if [ ! -s "$t" ]; then echo "fail: transcript $t missing"; bad=1; continue; fi
      s="$(_kv "${c}_started_epoch" "$f")"; e="$(_kv "${c}_ended_epoch" "$f")"
      if [ -z "$na" ] || [ -z "$s" ] || [ -z "$e" ]; then echo "fail: $f lacks $c times or notAfter"; bad=1; continue; fi
      if [ "$step" = minus ]; then
        rem=$(( na - s ))
        if [ "$rem" -lt "$th" ]; then echo "ok: minus $c had ${rem}s left at its start (< ${th}s)"
        else echo "fail: minus $c had ${rem}s left at its start (not < ${th}s)"; bad=1; fi
      else
        rem=$(( na - e ))
        if [ "$rem" -gt "$th" ]; then echo "ok: plus $c had ${rem}s left at its end (> ${th}s)"
        else echo "fail: plus $c had ${rem}s left at its end (not > ${th}s); repeat K in a fresh run"; bad=1; fi
      fi
    done
  done
  return "$bad"
}

# _w_upgrade_cmd OUT [ARGS...]: the shell command rendering `linkerd upgrade ARGS` into
# OUT. ARGS are quoted only when there are some: an empty quoted argument would make
# linkerd upgrade (which accepts none) fail and leave an empty manifest (C1's fix).
# Pure string-building, so it lives here rather than in scenario-webhook.sh: this file
# is what the unit tests source, and scenario-webhook.sh is not.
_w_upgrade_cmd() {
  local out="$1" q=""
  shift
  [ $# -eq 0 ] || q="$(printf ' %q' "$@")"
  printf 'linkerd upgrade%s > %q\n' "$q" "$out"
}

# pod_section METRICS_FILE POD: POD's lines in a tick's metrics file (metrics/<tick>.txt).
pod_section() {
  awk -v h="== lab/${2:?pod_section: POD required} " 'index($0, h) == 1 { on = 1; next } /^== / { on = 0 } on' "${1:?}"
}

_exact() { awk -v n="$1" '$1 == n { v = $2 } END { print v }' "$2"; } # NAME FILE

# s_hard_endpoint_state SWAP_EPOCH NOW_EPOCH BEFORE_SECTION NOW_SECTION LINES_FILE:
# S-hard's stage-1 condition for one unrestarted endpoint (design section 7, with a
# successful renewal accepted so that S4 stays falsifiable). Returns 0 when met.
s_hard_endpoint_state() {
  local swap="$1" now="$2" b="$3" c="$4" l="$5" exp ref okb errb okn errn ts first=-
  exp="$(_exact control_identity_cert_expiration_timestamp_seconds "$c")"
  ref="$(_exact control_identity_cert_refresh_timestamp_seconds "$c")"
  okb="$(_exact 'control_identity_cert_refreshes_total{result="ok"}' "$b")"
  errb="$(_exact 'control_identity_cert_refreshes_total{result="error"}' "$b")"
  okn="$(_exact 'control_identity_cert_refreshes_total{result="ok"}' "$c")"
  errn="$(_exact 'control_identity_cert_refreshes_total{result="error"}' "$c")"
  if [ -z "$exp" ] || [ -z "$ref" ] || [ -z "$okb" ] || [ -z "$errb" ] || [ -z "$okn" ] || [ -z "$errn" ]; then
    echo "state=pending reason=metrics-unreadable"; return 1
  fi
  exp="${exp%.*}"; ref="${ref%.*}"
  if [ "$ref" -ge "$swap" ] && [ "$okn" -gt "$okb" ]; then
    echo "state=renewed refresh=$ref leaf_not_after=$exp renew_ok=$(( okn - okb )) renew_err=$(( errn - errb ))"
    return 0
  fi
  while read -r ts _; do
    if [ "$(date -u -d "$ts" +%s)" -gt "$exp" ]; then first="$ts"; break; fi
  done < <(awk '/ fail /' "$l")
  local detail="old_leaf_not_after=$exp renew_attempts=$(( okn + errn - okb - errb )) renew_err=$(( errn - errb )) first_fail_after_expiry=$first"
  if [ "$exp" -lt "$now" ] && [ "$errn" -gt "$errb" ] && [ "$first" != - ]; then
    echo "state=expired-failed $detail"; return 0
  fi
  echo "state=pending $detail"
  return 1
}
