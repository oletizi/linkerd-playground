#!/bin/sh
# A NEW TCP connection to the opaque echo port on every attempt: send one line, expect
# it back, close. Output: <UTC> probe-tcp-new seq=<n> <ok|fail> <detail>
: "${TARGET_HOST:?}" "${TARGET_PORT:?}" "${PROBE_INTERVAL_S:?}"
seq=0
while :; do
  seq=$((seq + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reply="$(echo "seq=$seq" | socat -t 2 -T 3 - "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=3" 2>/tmp/socat.err)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$reply" = "seq=$seq" ]; then
    echo "$ts probe-tcp-new seq=$seq ok"
  else
    echo "$ts probe-tcp-new seq=$seq fail socat_rc=$rc reply=$reply err=$(tr '\n' ' ' < /tmp/socat.err)"
  fi
  sleep "$PROBE_INTERVAL_S"
done
