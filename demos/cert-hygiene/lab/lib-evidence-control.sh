#!/usr/bin/env bash
# The negative control's criteria and restart-gate record parsing. Pure: no kubectl.
# Sourced by lab/lib-evidence.sh; do not execute.

# control_criteria_check RUN_DIR: the negative control's pass criteria (design spec
# section 4.4) that a script can judge, from the per-pod probe logs the run captured
# at its end (probes/final/). Probe lines before the baseline tick are startup noise
# and are ignored. Other check warnings are compared by a human.
control_criteria_check() {
  local run="${1:?control_criteria_check: RUN_DIR required}" bad=0 t p n f lines
  local pdir="$run/probes/final"
  t="$(awk '$2 == "tick" && $3 == "baseline" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  [ -n "$t" ] || { echo "fail: no baseline tick in timeline.log"; return 1; }
  for p in probe-http probe-tcp-new probe-tcp-stream; do
    lines="$(_probe_lines "$pdir" "$p")"
    if [ -z "$lines" ]; then echo "fail: no $p lines in $pdir"; bad=1; continue; fi
    n="$(printf '%s\n' "$lines" | awk -v t="$t" '$1 >= t && / (fail|closed) /' | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then echo "ok: $p has no fail/closed lines after baseline"
    else echo "fail: $p has $n fail/closed lines after baseline"; bad=1; fi
  done
  n="$(_probe_lines "$pdir" probe-tcp-stream | awk '/ connect /' | wc -l | tr -d ' ')"
  if [ "$n" = 1 ]; then echo "ok: one stream connection"
  else echo "fail: $n stream connect lines, want 1"; bad=1; fi
  for f in verify-rollout-restart-target verify-rollout-probe-new; do
    if [ "$(tail -n 1 "$run/pods/$f.txt" 2>/dev/null)" = "[exit 0]" ]; then echo "ok: $f completed"
    else echo "fail: $f did not complete"; bad=1; fi
  done
  # grep -l exits 1 when nothing matches -- the passing case -- so it must not fail
  # the pipeline under set -e / pipefail.
  n="$({ grep -l '×' "$run"/checks/*.txt 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no fatal check results"
  else echo "fail: $n check files contain a fatal (×) result"; bad=1; fi
  n="$({ grep -lE '‼.*valid for at least 60 days' "$run"/checks/*.txt 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then echo "ok: no certificate-lifetime warnings"
  else echo "fail: $n check files carry a certificate-lifetime warning"; bad=1; fi
  return "$bad"
}
