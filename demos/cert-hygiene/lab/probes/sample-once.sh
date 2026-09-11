#!/bin/sh
# One fresh TCP connection to the opaque echo port, for a restart-stage sample (design
# 1.6), run by kubectl exec in a client pod: send one line, expect it back, close.
# Prints "ok" or "fail <detail>"; always exits 0. TARGET_* come from the pod's env.
: "${TARGET_HOST:?}" "${TARGET_PORT:?}"
n="${1:?usage: sample-once.sh <n>}"
reply="$(echo "sample=$n" | socat -t 2 -T 3 - "TCP:$TARGET_HOST:$TARGET_PORT,connect-timeout=3" 2>/tmp/sample.err)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$reply" = "sample=$n" ]; then
  echo ok
else
  echo "fail socat_rc=$rc reply=$reply err=$(tr '\n' ' ' < /tmp/sample.err)"
fi
