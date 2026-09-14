#!/usr/bin/env bash
# Scenario V (design section 8): the lab-supplied tap serving certificate expires while
# the trust anchor and issuer stay valid (profile tap-short: a 15-minute tap
# certificate). T_mark is the tap certificate's notAfter, exactly as the webhook
# scenarios take theirs from their own serving certificate (lab/scenario-webhook.sh).
# Unlike W, nothing is deleted, scaled or replaced -- V has no recovery branch. The run
# only RECORDS what tap, the tap APIService and `linkerd viz check` do before, at and
# after the expiry; V1 is judged later, in the write-up, never here. Launch with
# scripts/run.sh.
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

scenario_recover() { # V has no recovery branch: the tap certificate is never replaced,
  # so there is nothing to apply, delete or restart (design section 8 is record-only).
  mark v-recover "no recovery: V records tap and APIService state through the expiry; the tap certificate is never replaced"
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
