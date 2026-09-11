#!/usr/bin/env bash
# Runs on the macOS HOST. Launches a scenario detached inside the lab machine, after
# recording the harness's git state (the VM never runs git). The harness is lib/ plus
# demos/cert-hygiene/ excluding runs/. Prints the demo-relative run dir last.
# Usage: run.sh [--discovery [--short]] <scenario>, e.g. run.sh 00-baseline-control. With
# --discovery the run goes under runs/_discovery/, carries discovery.txt and is never
# evidence; --short (discovery only) shortens its observation windows.
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb git shasum

discovery=no; short=no
while [ $# -gt 0 ]; do
  case "$1" in
    --discovery) discovery=yes; shift ;;
    --short) short=yes; shift ;;
    *) break ;;
  esac
done
[ "$short" = no ] || [ "$discovery" = yes ] || die "--short is discovery-only: evidence runs refuse shortened windows"
scenario="${1:?usage: run.sh [--discovery [--short]] <scenario>}"
[ -f "$DEMO/scenarios/$scenario.sh" ] || die "no scenario '$scenario' in $DEMO/scenarios/"
if [ "$discovery" = yes ]; then
  rel="runs/_discovery/$(date -u +%Y%m%dT%H%M%SZ)-$scenario"
else
  rel="runs/$scenario/$(date -u +%Y%m%dT%H%M%SZ)"
fi
run="$DEMO/$rel"
mkdir -p "$run"
if [ "$discovery" = yes ]; then printf 'discovery=yes\nshort_windows=%s\n' "$short" > "$run/discovery.txt"; fi

commit="$(git -C "$ROOT" rev-parse HEAD)"
status="$(git -C "$ROOT" status --porcelain -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs')"
if [ -f "$DEMO/config.local.env" ]; then
  status="$(printf '%s\n%s' "$status" "config.local.env present (overrides config.example.env)")"
fi
tree="$(git -C "$ROOT" ls-tree -r HEAD -- lib demos/cert-hygiene \
  | awk -F '\t' '$2 !~ /^demos\/cert-hygiene\/runs\//' | shasum -a 256 | cut -d' ' -f1)"
if [ -z "$status" ]; then dirty=false; else dirty=true; fi
printf 'demo_repo_commit=%s\ndemo_repo_dirty=%s\nharness_tree_sha256=%s\n' "$commit" "$dirty" "$tree" > "$run/git-state.txt"
if [ "$dirty" = true ]; then
  { printf '%s\n' "$status"; git -C "$ROOT" diff HEAD -- lib demos/cert-hygiene ':(exclude)demos/cert-hygiene/runs'; } > "$run/harness.diff"
  log "WARNING: harness tree is dirty; this run can never be valid evidence (see $rel/harness.diff)"
fi
printf 'orbstack_version=%s\nhost_os=%s\n' "$(orb version 2>/dev/null | head -n 1)" "$(sw_vers -productVersion 2>/dev/null || uname -sr)" > "$run/host.txt"

bash "$DEMO/scripts/in-lab.sh" --detach "$rel/harness.log" "scenarios/$scenario.sh" "$rel"
log "follow: tail -f $DEMO/$rel/timeline.log"
echo "$rel"
