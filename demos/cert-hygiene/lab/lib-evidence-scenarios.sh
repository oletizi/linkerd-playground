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
