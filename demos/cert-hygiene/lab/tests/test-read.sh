#!/usr/bin/env bash
# Unit tests for the read-only evidence helpers in scripts/.
set -euo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$TESTS/../.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$DEMO/lab/lib-evidence.sh"
# shellcheck source=/dev/null
. "$TESTS/assert.sh"
set +e   # assertions count failures; they must not abort the suite

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
R="$T/run"
mkdir -p "$R/probes/pre-stage2" "$R/probes/final" "$R/metrics" "$R/gates"
printf '$ kubectl logs\n2026-09-11T10:00:02Z probe-tcp-new seq=2 ok\n2026-09-11T10:00:00Z probe-tcp-new seq=1 ok\n[exit 0]\n' > "$R/probes/pre-stage2/probe-tcp-new-a.log"
printf '2026-09-11T10:00:02Z probe-tcp-new seq=2 ok\n2026-09-11T10:05:00Z probe-tcp-new seq=1 fail socat_rc=1\n2026-09-11T10:00:01Z probe-http seq=1 ok http=200\n' > "$R/probes/final/probe-tcp-new-b.log"
out="$(bash "$DEMO/scripts/probe-lines.sh" "$R" probe-tcp-new)"
assert_eq "$(wc -l <<< "$out" | tr -d ' ')" 3 "merged across snapshots, duplicates removed, other probes excluded"
assert_eq "$(head -n 1 <<< "$out")" "2026-09-11T10:00:00Z probe-tcp-new seq=1 ok" "time order"
assert_eq "$(bash "$DEMO/scripts/probe-lines.sh" "$R" probe-tcp-new 2026-09-11T10:00:01Z 2026-09-11T10:05:00Z)" \
  "2026-09-11T10:00:02Z probe-tcp-new seq=2 ok" "window [from, to)"
assert_fails "no lines for a probe dies" bash "$DEMO/scripts/probe-lines.sh" "$R" probe-nope

# ---- probe-lines.sh and _all_probe_lines (lab/lib-evidence-control.sh, Task 8) agree ----
# Twins that must not drift: probe-lines.sh runs on the host (macOS bash 3.2 / POSIX
# awk); _all_probe_lines runs inside the lab VM (bash 5). Same fixture as above, same
# merge (find every probes/*/*.log, keep field 2 == probe, dedup and sort).
assert_eq "$(bash "$DEMO/scripts/probe-lines.sh" "$R" probe-tcp-new)" "$(_all_probe_lines "$R" probe-tcp-new)" \
  "probe-lines.sh and _all_probe_lines merge the same fixture identically"

printf '2026-09-11T10:00:00Z tick baseline\n2026-09-11T10:00:30Z tick pre-1\n' > "$R/timeline.log"
printf 'sampled_at_epoch=1\n== lab/probe-http-abc12-x1y2 :4191\ntcp_open_total{direction="outbound",peer="dst"} 1\nother 2\n== lab/probe-http-b-abc12-x1y2 :4191\ntcp_open_total{direction="outbound",peer="dst"} 9\n== lab/server-abc12-y3z4 :4191\ntcp_open_total{direction="inbound"} 5\n' > "$R/metrics/baseline.txt"
printf 'sampled_at_epoch=2\n== lab/probe-http-abc12-x1y2 :4191\ntcp_open_total{direction="outbound",peer="dst"} 1\n' > "$R/metrics/pre-1.txt"
out="$(bash "$DEMO/scripts/pod-series.sh" "$R" probe-http tcp_open_total)"
assert_eq "$(wc -l <<< "$out" | tr -d ' ')" 2 "one line per tick for the matching pod only; probe-http-b-... (a different Deployment) is excluded"
assert_contains "$out" 'pre-1 2026-09-11T10:00:30Z probe-http-abc12-x1y2 tcp_open_total{direction="outbound",peer="dst"} 1' "tick, time, pod, series, value"
out_b="$(bash "$DEMO/scripts/pod-series.sh" "$R" probe-http-b tcp_open_total)"
assert_eq "$(wc -l <<< "$out_b" | tr -d ' ')" 1 "the -b Deployment's own prefix matches only its own pod"
assert_contains "$out_b" 'probe-http-b-abc12-x1y2 tcp_open_total{direction="outbound",peer="dst"} 9' "prefix matching is exact, not a bare substring"

printf 'stage=stage2-client-a\nrestarted=probe-tcp-new\ngate=pass\ncell pair=A ok=10 fail=0 status=classified\nleaf t role=clientA pod=p refresh=1 expiry=2 ok=1 err=0\n' > "$R/gates/stage2-client-a.txt"
printf 'stage=s04-restart\nrestarted=server\ngate=pass\ncell pair=A ok=10 fail=0 status=classified\n' > "$R/gates/s04-restart.txt"
out="$(bash "$DEMO/scripts/gate-table.sh" "$R")"
assert_contains "$out" "stage=stage2-client-a restarted=probe-tcp-new gate=pass unmet=-" "gate header"
assert_contains "$out" "cell pair=A ok=10 fail=0 status=classified" "cells"
assert_contains "$out" "leaf t role=clientA" "leaf lines"
assert_contains "$out" "stage=s04-restart restarted=server gate=pass unmet=-" "a stage named -restart is listed too"

finish test-read
