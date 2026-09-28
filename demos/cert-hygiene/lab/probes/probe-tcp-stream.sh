#!/bin/sh
# ONE TCP connection to the opaque echo port, held for the pod's life. FAILS CLOSED:
# when the connection ends it logs that and idles -- it never reconnects, so every ok
# line after an expiry belongs to the connection opened before it. The conn id embeds
# the pod UID and connect time, so even a container restart shows up as a new id.
: "${TARGET_HOST:?}" "${TARGET_PORT:?}" "${PROBE_INTERVAL_S:?}" "${POD_UID:?}"
CONN="$(echo "$POD_UID" | cut -c1-8)-$(date -u +%s)"
export CONN PROBE_INTERVAL_S
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) probe-tcp-stream seq=0 conn=$CONN connect target=$TARGET_HOST:$TARGET_PORT"
socat "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=5" "EXEC:sh /probes/stream-session.sh"
rc=$?
last="$(cat /tmp/stream.seq 2>/dev/null || echo 0)"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) probe-tcp-stream seq=$last conn=$CONN closed socat_rc=$rc fail-closed, not reconnecting"
while :; do sleep 3600; done
