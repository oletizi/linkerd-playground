#!/usr/bin/env bash
# Scenario V (design section 8): the lab-supplied tap serving certificate expires while
# the trust anchor and issuer stay valid (profile tap-short: a 15-minute tap
# certificate). T_mark is the tap certificate's notAfter, exactly as the webhook
# scenarios take theirs from their own serving certificate (lab/scenario-webhook.sh).
# Unlike W, no credential is ever deleted, scaled or replaced -- V has no recovery branch.
# The run only RECORDS what tap, the tap APIService and `linkerd viz check` do before, at
# and after the expiry; V1 is judged later, in the write-up, never here. After the
# post-expiry window, a forced-reconnect phase (Task 3b, the same shape and reason as W's
# own) restarts the tap Deployment once, so the API server must open a new connection to it
# rather than reuse one from before the expiry, and probes continue through that window too.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

# linkerd viz tap has no --timeout flag (Task 1 discovery, lab/discover-tap.sh): the
# shell's timeout(1) bounds each probe instead, the same way discover-tap.sh does.
V_TAP_TIMEOUT_S=10
V_TAP_TARGET=deploy/server

scenario_mark_epoch() { # T_mark: the tap certificate's notAfter
  cert_not_after_epoch "$CERTS/webhooks/tap.crt"
}

V_RECONNECT_EPOCH=""   # when the reconnect rollout finished; reconnect-0000 is relative to it

scenario_recover() { # V has no credential recovery: the tap certificate is never replaced.
  # It does force a new API-server connection first (Task 3b), the same reason and shape as
  # W's own reconnect phase: a certificate that has already expired does not bite while the
  # API server is still using a connection it opened before that (design section 8's basis,
  # confirmed by Task 3's throwaway run).
  _v_reconnect
  mark v-recover "no recovery: the tap certificate is never replaced; only the forced-reconnect phase (above) ran"
}

# _v_backing: reconnect/backing.txt, "component=tap service=<svc> deployment=<d|-> [error=...]
# namespace=<ns|->" -- the Deployment behind the Service the tap APIService actually points
# at, derived now from that Service's selector (w_backing_line, reused unchanged from the
# webhook phase), plus the namespace that selector was read in. Unlike W's fixed
# webhook_service table, the Service name and its namespace both come from the live
# APIService: this is one component, not three, but neither the Service, its namespace nor
# its Deployment is ever hardcoded (Task 3b; slice 2 review finding on taking a mapping on
# trust; slice 3 review finding on deriving the namespace and then hardcoding it anyway --
# _v_reconnect below reads it back from this line instead). A failed read at any step is
# recorded, never fatal; "-" marks a namespace that read never resolved.
_v_backing() {
  local f="$RUN_DIR/reconnect/backing.txt" tmp svc="" ns="" err="" line
  tmp="$(mktemp -d)"
  mkdir -p "$RUN_DIR/reconnect"
  if ! _record "tap APIService read" kubectl get apiservice v1alpha1.tap.linkerd.io -o json > "$tmp/a.json"; then
    err="$(cat "$tmp/a.json")"
  else
    svc="$(jq -r '.spec.service.name // empty' "$tmp/a.json")"
    ns="$(jq -r '.spec.service.namespace // empty' "$tmp/a.json")"
    [ -n "$svc" ] && [ -n "$ns" ] || err="tap APIService names no backing Service"
  fi
  if [ -n "$err" ]; then
    line="$(w_backing_line tap "${svc:-<none>}" "$tmp/a.json" "$tmp/a.json" "$err")"
  elif ! _record "Service $ns/$svc read" kubectl -n "$ns" get svc "$svc" -o json > "$tmp/s.json"; then
    line="$(w_backing_line tap "$svc" "$tmp/s.json" "$tmp/s.json" "$(cat "$tmp/s.json")")"
  elif ! _record "$ns Deployment listing" kubectl -n "$ns" get deploy -o json > "$tmp/d.json"; then
    line="$(w_backing_line tap "$svc" "$tmp/s.json" "$tmp/d.json" "$(cat "$tmp/d.json")")"
  else
    line="$(w_backing_line tap "$svc" "$tmp/s.json" "$tmp/d.json")"
  fi
  # namespace= is inserted right after the fixed component/service/deployment prefix,
  # never appended after the line as a whole: w_backing_line's optional trailing
  # "error=<free text>" holds exactly that -- free text -- and a reader scanning fields
  # left to right for the first one matching "^namespace=" (_v_backing_namespace, below)
  # could otherwise be fooled by an error message that happens to contain such a token
  # (slice 4 review finding: this field used to be appended after error=, positionally
  # unsafe). component=, service= and deployment=<value> are each a single token with no
  # embedded spaces, so splitting the line on its first three fields and reinserting
  # namespace= before whatever (if anything) follows is exact, never a guess at where
  # the free text starts.
  awk -v ns="${ns:--}" '{ rest = $0; sub(/^[^ ]+ [^ ]+ [^ ]+/, "", rest)
    print $1, $2, $3, "namespace=" ns rest }' <<< "$line" > "$f"
  rm -rf "$tmp"
}

# _v_backing_namespace BACKING_FILE: the namespace= field _v_backing wrote to
# reconnect/backing.txt, or empty when the file holds none (a fixture written before
# this field existed, or a line _v_backing never got to write).
_v_backing_namespace() {
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^namespace=/) { print substr($i, 11); exit } }' "${1:?}"
}

_v_reconnect() { # the forced-reconnect phase (design section 8, added by Task 3b): restart
  # the Deployment behind the tap Service once, so the API server must open a new connection
  # to it, then probe. No lab workload is restarted and no credential changes: the new pod
  # still mounts the expired tap certificate. The namespace comes back from
  # reconnect/backing.txt (_v_backing derived it once, from the live APIService) and is
  # passed straight through, "-" sentinel and all -- never a hardcoded fallback (slice 4
  # review finding: a fallback here would carry the exact hardcoded namespace this task
  # existed to remove, for a reader to copy, even though the path is unreachable: "-" is
  # written only when the APIService read itself failed, which leaves ds empty too, and
  # both the restart and capture_rollouts below already skip on an empty ds regardless of
  # what ns holds).
  local ds=() ns
  snap_viz reconnect-before
  _v_backing
  mark reconnect-backing "$(cat "$RUN_DIR/reconnect/backing.txt")"
  mapfile -t ds < <(w_backing_deployments "$RUN_DIR/reconnect/backing.txt")
  ns="$(_v_backing_namespace "$RUN_DIR/reconnect/backing.txt")"
  mark reconnect-restart "kubectl rollout restart: ${ds[*]:-no backing Deployment}"
  if [ "${#ds[@]}" -gt 0 ]; then
    capture reconnect/restart.txt kubectl -n "$ns" rollout restart "${ds[@]/#/deploy/}"
  else
    capture reconnect/restart.txt bash -c 'echo "no backing Deployment derived; see reconnect/backing.txt"; exit 1'
  fi
  capture_rollouts reconnect/rollout.txt "$ns" "${ds[@]}"
  V_RECONNECT_EPOCH="$(date -u +%s)"
  mark reconnect-rolled-out "rollout.txt $(tail -n 1 "$RUN_DIR/reconnect/rollout.txt")"
  snap_viz reconnect-after
  capture "viz-check/reconnect-0000.txt" linkerd viz check --wait 20s
  _v_tap_probe reconnect-0000
  _v_conditions_snapshot reconnect-0000
  observe_until $(( V_RECONNECT_EPOCH + V_RECONNECT_WINDOW_S )) reconnect
  mark reconnect-end "after ${V_RECONNECT_WINDOW_S}s of reconnect probes; V has no recovery to follow"
}

_v_tap_probe() { # NAME: a bounded tap capture against live traffic, recorded whole --
  # the command line, its exit status and its output -- under tap/NAME.txt. A failure
  # here (including the timeout killing a hung stream) is the observation, never fatal.
  capture "tap/$1.txt" timeout "${V_TAP_TIMEOUT_S}s" linkerd viz tap "$V_TAP_TARGET" -n "$LAB_NS" -o json
}

# _v_tap_events FILE: how many complete JSON objects a _v_tap_probe capture holds.
# Strips capture's "$ ..." header and "[exit N]" footer, then counts jq's one-line-per-
# object output; tolerant of a stream timeout(1) cut mid-object, the same way
# discover-tap.sh's own `|| true` is.
_v_tap_events() {
  tail -n +2 "$1" | head -n -1 | jq -c . 2>/dev/null | grep -c . || true
}

# _v_conditions_snapshot NAME: the Available condition's raw JSON, once before and once
# after the expiry -- evidence that reason/message are populated fields rather than
# assumed ones (review finding, slice 3 Task 3), read straight from the API rather than
# through apiservices/NAME.txt's parsed jq extraction.
_v_conditions_snapshot() {
  capture "apiservices/$1-conditions.json" bash -c \
    'kubectl get apiservice v1alpha1.tap.linkerd.io -o json | jq ".status.conditions"'
}

# _v_baseline_check: tap-baseline.txt's body (design section 8) -- one ok/fail line per
# proof that tap worked while its certificate was valid, in the shape the v-baseline
# validity rule reads (Task 2).
_v_baseline_check() {
  local bad=0 avail checkline events
  avail="$(_kv apiservice_available_status "$RUN_DIR/apiservices/baseline.txt")"
  if [ "$avail" = True ]; then echo "ok: v1alpha1.tap.linkerd.io Available=True"
  else echo "fail: v1alpha1.tap.linkerd.io Available=$avail"; bad=1; fi
  checkline="$(grep -m1 -E 'tap API (service|server) has valid cert' "$RUN_DIR/viz-check/baseline.txt" || true)"
  if [ "$(tail -n 1 "$RUN_DIR/viz-check/baseline.txt")" = "[exit 0]" ] && [ -n "$checkline" ]; then
    echo "ok: linkerd viz check passed (${checkline# })"
  else
    echo "fail: linkerd viz check did not pass the tap row (${checkline:-no matching row found})"
    bad=1
  fi
  events="$(_v_tap_events "$RUN_DIR/tap/baseline.txt")"
  if [ "${events:-0}" -gt 0 ]; then
    echo "ok: linkerd viz tap observed $events event(s) against live traffic"
  else
    echo "fail: linkerd viz tap observed no events against live traffic"
    bad=1
  fi
  return "$bad"
}

scenario_tick_extra() { # NAME: linkerd viz check on every tick (design section 8, "record
  # ... linkerd viz check" before, at and after); a tap probe at baseline (once, feeding
  # the baseline proof below) and on every tick from T_mark on; the Available condition's
  # raw JSON once before the expiry and once after it.
  capture "viz-check/$1.txt" linkerd viz check --wait 20s
  if [ "$1" = baseline ] || [ "$TICK_START_EPOCH" -ge "$T_MARK" ]; then
    _v_tap_probe "$1"
  fi
  case "$1" in
    baseline)
      _v_conditions_snapshot "$1"
      _write_result tap-baseline.txt _v_baseline_check \
        || die "tap did not work while its certificate was valid; see tap-baseline.txt (V's stop gate)"
      ;;
    verify) _v_conditions_snapshot "$1" ;;
  esac
}

run_scenario 30-tap-expiry tap-short "${1:?usage: 30-tap-expiry.sh <run-dir>}"
