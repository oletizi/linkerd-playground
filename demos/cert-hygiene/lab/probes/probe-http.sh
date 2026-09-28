#!/bin/sh
# One HTTP request to the lab server per attempt. No client retries (a single curl,
# no --retry); connection reuse between proxies stays on, deliberately: this is what an
# ordinary application sees. Output: <UTC> probe-http seq=<n> <ok|fail> <detail>
: "${TARGET_URL:?}" "${PROBE_INTERVAL_S:?}"
seq=0
while :; do
  seq=$((seq + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$TARGET_URL" 2>/tmp/curl.err)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
    echo "$ts probe-http seq=$seq ok http=$code"
  else
    echo "$ts probe-http seq=$seq fail curl_rc=$rc http=$code err=$(tr '\n' ' ' < /tmp/curl.err)"
  fi
  sleep "$PROBE_INTERVAL_S"
done
