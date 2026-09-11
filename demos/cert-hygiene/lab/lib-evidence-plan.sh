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
