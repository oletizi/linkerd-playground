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
