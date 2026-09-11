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
  local d="$1" p="$1/probes/final"
  mkdir -p "$p" "$d/pods" "$d/checks"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n' > "$d/timeline.log"
  printf '$ kubectl -n lab logs probe-http-1 -c probe\n2026-09-10T10:04:58Z probe-http seq=1 fail curl_rc=7 http=000 err=refused\n2026-09-10T10:05:01Z probe-http seq=2 ok http=200\n[exit 0]\n' > "$p/probe-http-1.log"
  printf '$ kubectl -n lab logs probe-http-1 -c probe --previous\nError from server (BadRequest): previous terminated container "probe" in pod "probe-http-1" not found\n[exit 1]\n' > "$p/probe-http-1-previous.log"
  printf '2026-09-10T10:05:01Z probe-tcp-new seq=2 ok\n' > "$p/probe-tcp-new-1.log"
  printf '2026-09-10T10:04:59Z probe-tcp-stream seq=0 conn=ab-1 connect target=s:9000\n2026-09-10T10:05:01Z probe-tcp-stream seq=2 conn=ab-1 ok\n' > "$p/probe-tcp-stream-1.log"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-restart-target.txt"
  printf '$ kubectl rollout status\n[exit 0]\n' > "$d/pods/verify-rollout-probe-new.txt"
  printf '$ linkerd check\n√ issuer cert is valid for at least 60 days\n‼ cli is up-to-date\n[exit 0]\n' > "$d/checks/verify-check.txt"
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

finish test-control
