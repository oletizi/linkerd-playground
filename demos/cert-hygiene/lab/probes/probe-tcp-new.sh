#!/bin/sh
# A NEW TCP connection to the opaque echo port on every attempt: send one line, expect
# it back, close. Two Deployments run it (probe-tcp-new, probe-tcp-new-b), told apart by
# PROBE_NAME. Output: <UTC> <PROBE_NAME> seq=<n> <ok|fail> <detail>
: "${PROBE_NAME:?}" "${TARGET_HOST:?}" "${TARGET_PORT:?}" "${PROBE_INTERVAL_S:?}"
seq=0
while :; do
  seq=$((seq + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reply="$(echo "seq=$seq" | socat -t 2 -T 3 - "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=3" 2>/tmp/socat.err)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$reply" = "seq=$seq" ]; then
    echo "$ts $PROBE_NAME seq=$seq ok"
  else
    echo "$ts $PROBE_NAME seq=$seq fail socat_rc=$rc reply=$reply err=$(tr '\n' ' ' < /tmp/socat.err)"
  fi
  sleep "$PROBE_INTERVAL_S"
done
