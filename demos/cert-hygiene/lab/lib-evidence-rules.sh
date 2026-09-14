#!/usr/bin/env bash
# The validity rule table (design section 1.3), keyed by scenario name, and
# evaluate_validity. Pure: no kubectl. Sourced by lab/lib-evidence.sh; do not execute.
# Says nothing about hypotheses.

# Used by test-rules.sh and later tasks, not by this file itself.
# shellcheck disable=SC2034
LAB_SCENARIOS=(00-baseline-control 05-issuer-expiry 02-webhook-expiry-ignore 02-webhook-expiry-fail
  09-identity-outage 20-check-threshold 06-anchor-expiry 07-anchor-rotation-staged 08-anchor-rotation-hard
  30-tap-expiry)

# scenario_rules SCENARIO: the rule ids that apply beyond the common rules and the plan.
scenario_rules() {
  case "${1:?scenario_rules: SCENARIO required}" in
    00-baseline-control) echo control-criteria ;;
    05-issuer-expiry|06-anchor-expiry) printf '%s\n' recovery-apply control-at-tree ;;
    02-webhook-expiry-ignore|02-webhook-expiry-fail) printf '%s\n' webhook-baseline w-reconnect w-plain-render control-at-tree ;;
    09-identity-outage|07-anchor-rotation-staged) echo control-at-tree ;;
    20-check-threshold) echo k-remaining ;;
    08-anchor-rotation-hard) printf '%s\n' s-hard-stage1 control-at-tree ;;
    30-tap-expiry) printf '%s\n' v-baseline v-reconnect control-at-tree ;;
    *) die "scenario_rules: unknown scenario '$1'" ;;
  esac
}

_certs() { local n; for n in "$@"; do printf 'certs/%s.pem\ncerts/%s.txt\n' "$n" "$n"; done; }

# scenario_required_files SCENARIO: run-relative files that must exist, non-empty.
scenario_required_files() {
  local s="${1:?scenario_required_files: SCENARIO required}"
  scenario_rules "$s" > /dev/null
  printf '%s\n' versions.txt git-state.txt timeline.log leaf-lifetime.txt credential-plan.txt
  _certs trust-anchor issuer-initial
  case "$s" in
    00-baseline-control) echo control-criteria.txt ;;
    05-issuer-expiry) _certs issuer-replacement; echo recover/linkerd-upgrade.txt ;;
    02-webhook-expiry-*)
      _certs webhook-ca webhook-proxyInjector webhook-policyValidator webhook-profileValidator
      printf '%s\n' admission-baseline.txt recover/branch.txt recover/plain-render.txt recover/plain-apply.txt recover/plain-manifest.yaml \
        reconnect/backing.txt reconnect/restart.txt reconnect/rollout.txt ;;
    09-identity-outage) ;;
    20-check-threshold) _certs issuer-plus; echo k-remaining.txt ;;
    06-anchor-expiry) _certs trust-anchor-new issuer-replacement; echo recover/linkerd-upgrade.txt ;;
    07-anchor-rotation-staged) _certs trust-anchor-new trust-bundle issuer-new ;;
    08-anchor-rotation-hard) _certs trust-anchor-new issuer-new; echo s-hard/stage1-condition.txt ;;
    30-tap-expiry) printf '%s\n' tap-baseline.txt reconnect/backing.txt reconnect/restart.txt reconnect/rollout.txt ;;
  esac
}

# credential_plan_for SCENARIO: the declared credential plan (design section 1.3).
credential_plan_for() {
  local s="${1:?credential_plan_for: SCENARIO required}"
  scenario_rules "$s" > /dev/null
  case "$s" in
    02-webhook-expiry-*) printf 'components trust issuer webhooks\nplan A/I1/W1 A/I1/W2\n' ;;
    00-baseline-control|09-identity-outage|30-tap-expiry) printf 'components trust issuer\nplan A/I1\n' ;;
    05-issuer-expiry|20-check-threshold) printf 'components trust issuer\nplan A/I1 A/I2\n' ;;
    06-anchor-expiry|08-anchor-rotation-hard) printf 'components trust issuer\nplan A/I1 B/I2\n' ;;
    07-anchor-rotation-staged) printf 'components trust issuer\nplan A/I1 A+B/I1 A+B/I2 B/I2\n' ;;
  esac
}

# credential_plan_check RUN_DIR SCENARIO: walk credentials/<tick>.txt, in timeline
# order, against the scenario's declared plan.
credential_plan_check() {
  local run="${1:?}" scenario="${2:?}" plan t files=() rc=0
  plan="$(mktemp)"
  credential_plan_for "$scenario" > "$plan"
  while read -r t; do files+=("$run/credentials/$t.txt"); done \
    < <(awk '$2 == "tick" { print $3 }' "$run/timeline.log" 2>/dev/null)
  awk '$1 == "plan" { print "declared: " $0 }' "$plan"
  if [ "${#files[@]}" -eq 0 ]; then echo "fail: no ticks in $run/timeline.log"; rc=1; fi
  for t in "${files[@]}"; do
    [ -s "$t" ] || { echo "fail: $t missing"; rc=1; }
  done
  if [ "$rc" -eq 0 ]; then credential_plan_walk "$plan" "${files[@]}" || rc=1; fi
  rm -f "$plan"
  return "$rc"
}

# _pods_txt_parse LINE: one "pod=<name> proxy=<yes|no> containers=<a,b,c>" line of a
# pods.txt file -> "<pod> <containers>" (comma-joined, unsplit). Both _missing_proxy_logs
# here and snap_logs (collect-logs.sh) parse a pods.txt line; this is the one place.
_pods_txt_parse() {
  local line="$1" pod containers
  pod="$(awk '{ print $1 }' <<< "$line")"; pod="${pod#pod=}"
  containers="$(awk '{ print $3 }' <<< "$line")"; containers="${containers#containers=}"
  printf '%s %s\n' "$pod" "$containers"
}

# _missing_proxy_logs RUN_DIR: the proxy-log rule. Every logs/<label>/ directory must
# hold pods.txt, the lab pods the snapshot captured (design section 1.4). Each listed
# container needs its <pod>-<container>.txt; a pod with proxy=yes lists linkerd-proxy
# (a native-sidecar init container), so its proxy log is always required. A snapshot
# that lists no pod fails, so the rule is never vacuous. Prints one line per miss.
_missing_proxy_logs() {
  local run="$1" dir label line pod containers c
  for dir in "$run"/logs/*/; do
    [ -d "$dir" ] || continue
    label="$(basename "$dir")"
    if [ ! -f "$dir/pods.txt" ]; then echo "$label: pods.txt missing"; continue; fi
    if grep -q '^\[' "$dir/pods.txt"; then echo "$label: pods.txt records a failed listing"; continue; fi
    if ! grep -q '^pod=' "$dir/pods.txt"; then echo "$label: pods.txt lists no pod"; continue; fi
    while read -r line; do
      read -r pod containers < <(_pods_txt_parse "$line")
      for c in ${containers//,/ }; do
        [ -s "$dir$pod-$c.txt" ] || echo "$label: $pod has no $pod-$c.txt"
      done
    done < <(grep '^pod=' "$dir/pods.txt")
  done
  return 0
}

_first_is() { [ "$(head -n 1 "$1" 2>/dev/null)" = "$2" ]; } # FILE LINE

# evaluate_validity RUN_DIR SCENARIO EXPECTED_LINKERD_VERSION [CONTROL_RUNS_DIR]:
# decide mechanically whether a run is valid evidence and write RUN_DIR/validity.txt.
evaluate_validity() {
  local run="${1:?}" scenario="${2:?}" expected="${3:?}" control_dir="${4:-}"
  local reasons=() f tick rule tree rules comp
  rules="$(scenario_rules "$scenario")" || die "evaluate_validity: unknown scenario '$scenario'"
  [ "$(_kv demo_repo_dirty "$run/git-state.txt")" = false ] || reasons+=("dirty harness tree, or git-state.txt missing")
  [ ! -e "$run/discovery.txt" ] || reasons+=("discovery run: never evidence")
  while read -r f; do
    [ -s "$run/$f" ] || reasons+=("missing $f")
  done < <(scenario_required_files "$scenario")
  tail -n 1 "$run/timeline.log" 2>/dev/null | grep -qE '^[^ ]+ done$' || reasons+=("timeline does not end in done")
  while read -r tick; do
    for f in "checks/$tick-check.txt" "checks/$tick-check-proxy.txt" "metrics/$tick.txt" "pods/$tick.txt" \
        "credentials/$tick.txt" "webhooks/$tick.txt" "controlplane/$tick.txt"; do
      [ -s "$run/$f" ] || reasons+=("tick $tick missing $f")
    done
  done < <(awk '$2 == "tick" { print $3 }' "$run/timeline.log" 2>/dev/null)
  while read -r f; do
    reasons+=("missing workload proxy log: $f")
  done < <(_missing_proxy_logs "$run")
  _first_is "$run/leaf-lifetime.txt" result=ok || reasons+=("effective leaf lifetime check did not pass")
  _first_is "$run/credential-plan.txt" result=ok || reasons+=("credential states do not walk the declared plan")
  [ "$(_kv linkerd_cli_version "$run/versions.txt")" = "$expected" ] || reasons+=("linkerd CLI is not $expected")
  case "$(_kv linkerd_controller_image "$run/versions.txt")" in
    *":$expected") ;;
    *) reasons+=("control plane is not $expected") ;;
  esac
  for rule in $rules; do
    case "$rule" in
      control-criteria) _first_is "$run/control-criteria.txt" result=ok || reasons+=("control criteria not met") ;;
      recovery-apply)
        [ "$(tail -n 1 "$run/recover/linkerd-upgrade.txt" 2>/dev/null)" = "[exit 0]" ] \
          || reasons+=("recovery apply did not succeed: recover/linkerd-upgrade.txt missing or not ending [exit 0]") ;;
      webhook-baseline)
        _first_is "$run/admission-baseline.txt" result=ok || reasons+=("webhook baseline did not prove every admission probe") ;;
      w-plain-render)
        if [ "$(tail -n 1 "$run/recover/plain-render.txt" 2>/dev/null)" != "[exit 0]" ] \
            || [ "$(tail -n 1 "$run/recover/plain-apply.txt" 2>/dev/null)" != "[exit 0]" ] \
            || [ ! -s "$run/recover/plain-manifest.yaml" ]; then
          reasons+=("plain linkerd upgrade render or apply did not succeed: recover/plain-render.txt or plain-apply.txt does not end [exit 0], or plain-manifest.yaml is empty")
        fi ;;
      w-reconnect)   # the components are lib-webhook.sh's WEBHOOK_COMPONENTS, which this pure library does not source
        for comp in proxyInjector policyValidator profileValidator; do
          awk -v c="component=$comp" '$1 == c && $3 ~ /^deployment=[^-]/ { found = 1 } END { exit !found }' \
            "$run/reconnect/backing.txt" 2>/dev/null || reasons+=("forced reconnect: reconnect/backing.txt names no Deployment for $comp")
        done
        for f in restart rollout; do
          [ "$(tail -n 1 "$run/reconnect/$f.txt" 2>/dev/null)" = "[exit 0]" ] \
            || reasons+=("forced reconnect: reconnect/$f.txt does not end [exit 0]")
        done ;;
      k-remaining)
        _first_is "$run/k-remaining.txt" result=ok || reasons+=("K measurements are not on opposite sides of 60 days at check time") ;;
      s-hard-stage1)
        _first_is "$run/s-hard/stage1-condition.txt" result=met \
          || reasons+=("S-hard stage 1 did not reach its per-endpoint condition before its timeout") ;;
      v-baseline)
        _first_is "$run/tap-baseline.txt" result=ok \
          || reasons+=("tap was never proved working while its certificate was valid: tap-baseline.txt") ;;
      v-reconnect)   # V has one component (tap); its Service and Deployment are derived at
        # run time from the live APIService, never a fixed table (Task 3b)
        awk '$3 ~ /^deployment=[^-]/ { found = 1 } END { exit !found }' "$run/reconnect/backing.txt" 2>/dev/null \
          || reasons+=("forced reconnect: reconnect/backing.txt names no Deployment")
        for f in restart rollout; do
          [ "$(tail -n 1 "$run/reconnect/$f.txt" 2>/dev/null)" = "[exit 0]" ] \
            || reasons+=("forced reconnect: reconnect/$f.txt does not end [exit 0]")
        done ;;
      control-at-tree)
        tree="$(_kv harness_tree_sha256 "$run/git-state.txt")"
        _control_passed "$control_dir" "$tree" || reasons+=("no valid 00-baseline-control run with harness tree $tree") ;;
      *) die "evaluate_validity: rule '$rule' has no check" ;;
    esac
  done
  if [ ${#reasons[@]} -eq 0 ]; then
    echo evidence_valid=yes > "$run/validity.txt"
    return 0
  fi
  { echo evidence_valid=no; printf 'reason=%s\n' "${reasons[@]}"; } > "$run/validity.txt"
  return 1
}
