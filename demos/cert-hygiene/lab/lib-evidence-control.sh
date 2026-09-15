#!/usr/bin/env bash
# The negative control's criteria and restart-gate record parsing. Pure: no kubectl.
# Sourced by lab/lib-evidence.sh; do not execute.

# _all_probe_lines RUN_DIR PROBE: PROBE's lines from every probes/<label>/ snapshot
# (restart stages replace probe pods, so no single snapshot holds them all),
# deduplicated and sorted by time. Twin: scripts/probe-lines.sh (Task 18) does the same
# merge on the host (macOS bash 3.2 / POSIX awk); kept as a separate implementation for
# that reason. lab/tests/test-read.sh checks the two agree on one fixture.
_all_probe_lines() {
  local run="$1" p="$2" dir
  for dir in "$run"/probes/*/; do
    [ -d "$dir" ] || continue
    _probe_lines "$dir" "$p"
  done | sort -u
}

# control_criteria_check RUN_DIR: the restart-choreography control's criteria (design
# section 1.7). Probe lines count only from the baseline tick to the recover marker:
# before baseline is startup noise, and during the restart stages failures are the
# rollout-disruption baseline, recorded but not judged here. The stages are judged by
# their gate records: every gate passed and every gated sample succeeded.
control_criteria_check() {
  local run="${1:?control_criteria_check: RUN_DIR required}" bad=0 t r p n f lines g s
  t="$(awk '$2 == "tick" && $3 == "baseline" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  r="$(awk '$2 == "recover" { print $1; exit }' "$run/timeline.log" 2>/dev/null)"
  [ -n "$t" ] || { echo "fail: no baseline tick in timeline.log"; return 1; }
  [ -n "$r" ] || { echo "fail: no recover marker in timeline.log"; return 1; }
  for p in probe-http probe-tcp-new probe-tcp-new-b probe-tcp-stream; do
    lines="$(_all_probe_lines "$run" "$p")"
    if [ -z "$lines" ]; then echo "fail: no $p lines in $run/probes/"; bad=1; continue; fi
    n="$(printf '%s\n' "$lines" | awk -v t="$t" -v r="$r" '$1 >= t && $1 < r && / (fail|closed) /' | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then echo "ok: $p has no fail/closed lines between baseline and recover"
    else echo "fail: $p has $n fail/closed lines between baseline and recover"; bad=1; fi
  done
  n="$(_all_probe_lines "$run" probe-tcp-stream | awk -v r="$r" '$1 < r && / connect /' | wc -l | tr -d ' ')"
  if [ "$n" = 1 ]; then echo "ok: one stream connection before recover"
  else echo "fail: $n stream connect lines before recover, want 1"; bad=1; fi
  n=0
  for f in "$run"/gates/*.txt; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    if ! s="$(gate_summary "$f")"; then echo "$s"; bad=1; continue; fi
    g="${s%% *}"
    if [ "$g" = gate=timeout ]; then echo "fail: $(basename "$f") gate timed out"; bad=1; fi
    if grep -qE '^cell .* fail=[1-9]' "$f" || grep -qE '^cell .* ok=0 ' "$f"; then
      echo "fail: $(basename "$f") has failed gated samples: $s"; bad=1
    else
      echo "ok: $(basename "$f") $s"
    fi
  done
  if [ "$n" -eq 0 ]; then echo "fail: no gate records in $run/gates/"; bad=1; fi
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

# gate_summary FILE: one line summarising a restart-stage gate record (gates/<stage>.txt):
# "gate=<pass|timeout|none> <pair>=<ok>/<fail>/<status> ...". Returns 1 if the record
# has no gate line or no cell line.
gate_summary() {
  local f="${1:?gate_summary: FILE required}" g cells
  g="$(awk -F= '$1 == "gate" { v = $2 } END { print v }' "$f" 2>/dev/null)"
  [ -n "$g" ] || { echo "fail: $f has no gate line"; return 1; }
  cells="$(awk '$1 == "cell" {
      split($2, p, "="); split($3, o, "="); split($4, x, "="); split($5, s, "=")
      printf " %s=%s/%s/%s", p[2], o[2], x[2], s[2] }' "$f")"
  [ -n "$cells" ] || { echo "fail: $f has no cell line"; return 1; }
  echo "gate=$g$cells"
}
