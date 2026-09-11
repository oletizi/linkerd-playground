#!/bin/sh
# Runs under socat EXEC: stdin/stdout ARE the TCP connection; log lines go to stderr
# (the container log). One exchange per interval. A read that fails well before its
# timeout means end-of-stream: the connection is gone, so exit and let the caller log it.
seq=0
while :; do
  seq=$((seq + 1))
  echo "$seq" > /tmp/stream.seq
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start="$(date -u +%s)"
  echo "seq=$seq" || { echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail write-error" >&2; exit 1; }
  # Runs under busybox ash (the pod's /bin/sh), which supports read -t.
  # shellcheck disable=SC3045
  if read -r -t 5 reply; then
    if [ "$reply" = "seq=$seq" ]; then
      echo "$ts probe-tcp-stream seq=$seq conn=$CONN ok" >&2
    else
      echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail unexpected-reply=$reply" >&2
    fi
  else
    rc=$?
    if [ $(( $(date -u +%s) - start )) -lt 4 ]; then
      echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail end-of-stream read_rc=$rc" >&2
      exit 0
    fi
    echo "$ts probe-tcp-stream seq=$seq conn=$CONN fail no-reply-within-5s read_rc=$rc" >&2
  fi
  sleep "$PROBE_INTERVAL_S"
done
