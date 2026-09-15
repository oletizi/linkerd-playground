#!/usr/bin/env bash
# Unit tests for lab/lib-evidence-control.sh. Runs INSIDE the lab VM.
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

# ---- control_criteria_check ----
make_ctl() { # dir: a control run that meets every criterion (probes/final/, one pod per probe)
  local d="$1" p="$1/probes/final" s
  mkdir -p "$p" "$d/pods" "$d/checks" "$d/gates"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n2026-09-10T10:30:00Z recover\n' > "$d/timeline.log"
  printf '$ kubectl -n lab logs probe-http-1 -c probe\n2026-09-10T10:04:58Z probe-http seq=1 fail curl_rc=7 http=000 err=refused\n2026-09-10T10:05:01Z probe-http seq=2 ok http=200\n[exit 0]\n' > "$p/probe-http-1.log"
  printf '$ kubectl -n lab logs probe-http-1 -c probe --previous\nError from server (BadRequest): previous terminated container "probe" in pod "probe-http-1" not found\n[exit 1]\n' > "$p/probe-http-1-previous.log"
  printf '2026-09-10T10:05:01Z probe-tcp-new seq=2 ok\n' > "$p/probe-tcp-new-1.log"
  printf '2026-09-10T10:05:01Z probe-tcp-new-b seq=2 ok\n' > "$p/probe-tcp-new-b-1.log"
  printf '2026-09-10T10:04:59Z probe-tcp-stream seq=0 conn=ab-1 connect target=s:9000\n2026-09-10T10:05:01Z probe-tcp-stream seq=2 conn=ab-1 ok\n' > "$p/probe-tcp-stream-1.log"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-restart-target.txt"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-probe-new.txt"
  printf '$ linkerd check\n√ issuer cert is valid for at least 60 days\n‼ cli is up-to-date\n[exit 0]\n' > "$d/checks/verify-check.txt"
  for s in stage1-norestart stage2-client-a stage3-server stage4-all; do
    printf 'stage=%s\ngate=pass\ncell pair=A ok=10 fail=0 status=classified\ncell pair=B ok=10 fail=0 status=classified\n' "$s" > "$d/gates/$s.txt"
  done
}
make_ctl "$T/cc"
assert_succeeds "healthy control meets criteria (a fail before baseline is ignored)" control_criteria_check "$T/cc"
assert_succeeds "control_criteria_check completes under set -e when nothing matches" \
  bash -c ". '$ROOT/lib/common.sh'; . '$DEMO/lab/lib-evidence.sh'; set -euo pipefail; control_criteria_check '$T/cc'"
make_ctl "$T/cc1"; printf '2026-09-10T10:20:00Z probe-tcp-new seq=9 fail socat_rc=1\n' >> "$T/cc1/probes/final/probe-tcp-new-1.log"
assert_fails "a probe failure after baseline breaks the control" control_criteria_check "$T/cc1"
make_ctl "$T/cc2"; printf '2026-09-10T10:20:00Z probe-tcp-stream seq=0 conn=ab-2 connect target=s:9000\n' > "$T/cc2/probes/final/probe-tcp-stream-2.log"
assert_fails "a second stream connection, in another pod, breaks the control" control_criteria_check "$T/cc2"
make_ctl "$T/cc6"; printf '2026-09-10T10:20:00Z probe-http seq=9 fail curl_rc=7\n' > "$T/cc6/probes/final/probe-http-1-previous.log"
assert_fails "a failure in a previous container's log breaks the control" control_criteria_check "$T/cc6"
make_ctl "$T/cc7"; rm -r "$T/cc7/probes/final"
assert_fails "no probe logs breaks the control" control_criteria_check "$T/cc7"
make_ctl "$T/cc3"; printf '$ kubectl rollout status\n[exit 1]\n' > "$T/cc3/pods/verify-rollout-probe-new.txt"
assert_fails "an incomplete rollout breaks the control" control_criteria_check "$T/cc3"
make_ctl "$T/cc4"; printf '× issuer cert is within its validity period\n' >> "$T/cc4/checks/verify-check.txt"
assert_fails "a fatal check result breaks the control" control_criteria_check "$T/cc4"
make_ctl "$T/cc5"; printf '‼ issuer cert is valid for at least 60 days\n' >> "$T/cc5/checks/verify-check.txt"
assert_fails "a certificate-lifetime warning breaks the control" control_criteria_check "$T/cc5"

make_ctl "$T/ccb"; rm "$T/ccb/probes/final/probe-tcp-new-b-1.log"
assert_fails "the control needs the second client's lines" control_criteria_check "$T/ccb"
make_ctl "$T/cr1"; printf '2026-09-10T10:40:00Z probe-tcp-new seq=900 fail socat_rc=1\n' >> "$T/cr1/probes/final/probe-tcp-new-1.log"
assert_succeeds "a failure during the restart stages is recorded, not a criteria failure" control_criteria_check "$T/cr1"
make_ctl "$T/cr2"; mkdir -p "$T/cr2/probes/pre-stage4"
printf '2026-09-10T10:50:00Z probe-tcp-stream seq=0 conn=cd-2 connect target=s:9000\n' > "$T/cr2/probes/pre-stage4/probe-tcp-stream-2.log"
assert_succeeds "a stream reconnect after the recover marker is allowed" control_criteria_check "$T/cr2"
make_ctl "$T/cr3"; mkdir -p "$T/cr3/probes/pre-stage2"
printf '2026-09-10T10:20:00Z probe-http seq=9 fail curl_rc=7\n' > "$T/cr3/probes/pre-stage2/probe-http-1.log"
assert_fails "a pre-recover failure in an earlier probe snapshot breaks the control" control_criteria_check "$T/cr3"
make_ctl "$T/cr4"; printf 'stage=stage3-server\ngate=pass\ncell pair=A ok=9 fail=1 status=classified\ncell pair=B ok=10 fail=0 status=classified\n' > "$T/cr4/gates/stage3-server.txt"
assert_fails "a failed gated sample breaks the control" control_criteria_check "$T/cr4"
make_ctl "$T/cr5"; printf 'stage=stage2-client-a\ngate=timeout\ncell pair=A ok=10 fail=0 status=unclassified\ncell pair=B ok=10 fail=0 status=unclassified\n' > "$T/cr5/gates/stage2-client-a.txt"
assert_fails "a timed-out gate breaks the control" control_criteria_check "$T/cr5"
make_ctl "$T/cr6"; rm -r "$T/cr6/gates"
assert_fails "no gate records breaks the control" control_criteria_check "$T/cr6"
make_ctl "$T/cr7"; printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n' > "$T/cr7/timeline.log"
assert_fails "no recover marker breaks the control" control_criteria_check "$T/cr7"
make_ctl "$T/crs"; printf 'stage=s04-restart\ngate=pass\ncell pair=A ok=9 fail=1 status=classified\ncell pair=B ok=10 fail=0 status=classified\n' > "$T/crs/gates/s04-restart.txt"
assert_fails "a gate record whose stage name ends in -restart is read too" control_criteria_check "$T/crs"

# ---- gate_summary ----
gate_file() { # FILE GATE A_OK A_FAIL B_OK B_FAIL STATUS
  printf 'stage=s\nrestarted=server\nstarted_at=x\nstarted_epoch=1\ngate=%s\ngate_at=y\n' "$2" > "$1"
  printf 'sample t pair=A client=c server=s n=1 ok\n' >> "$1"
  printf 'cell pair=A ok=%s fail=%s status=%s\ncell pair=B ok=%s fail=%s status=%s\n' "$3" "$4" "$7" "$5" "$6" "$7" >> "$1"
}
gate_file "$T/g1.txt" pass 10 0 10 0 classified
assert_eq "$(gate_summary "$T/g1.txt")" "gate=pass A=10/0/classified B=10/0/classified" "passed gate summary"
gate_file "$T/g2.txt" timeout 3 7 0 10 unclassified
assert_eq "$(gate_summary "$T/g2.txt")" "gate=timeout A=3/7/unclassified B=0/10/unclassified" "timed-out gate summary"
printf 'stage=s\ncell pair=A ok=1 fail=0 status=classified\n' > "$T/g3.txt"
assert_fails "no gate line fails" gate_summary "$T/g3.txt"
printf 'stage=s\ngate=none\n' > "$T/g4.txt"
assert_fails "no cell line fails" gate_summary "$T/g4.txt"

finish test-control
