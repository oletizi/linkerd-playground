#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a lab with baseline workloads deployed. Answers the
# design's open lab questions from raw data: which identity metrics the proxy and the
# identity controller export, and which proxy counters grow per probe attempt.
# Usage: discover.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
out="${1:?usage: discover.sh <out-dir>}"
[ ! -e "$out" ] || die "$out exists; refusing to overwrite"
mkdir -p "$out"
apps=(probe-http probe-tcp-new probe-tcp-stream server restart-target)

pod_of() { kubectl -n "$LAB_NS" get pod -l "app=$1" -o jsonpath='{.items[0].metadata.name}'; }
metrics() { kubectl get --raw "/api/v1/namespaces/$1/pods/$2:$3/proxy/metrics"; }
idpod="$(kubectl -n linkerd get pod -l linkerd.io/control-plane-component=identity -o jsonpath='{.items[0].metadata.name}')"

snap() { # label
  local app
  for app in "${apps[@]}"; do metrics "$LAB_NS" "$(pod_of "$app")" 4191 > "$out/$app-$1.txt"; done
  metrics linkerd "$idpod" 9990 > "$out/identity-$1.txt"
}

snap t0
sleep 30
snap t1
for app in probe-http probe-tcp-new probe-tcp-stream; do
  kubectl -n "$LAB_NS" logs "deploy/$app" -c probe --since=40s > "$out/$app.log"
done

# Every sample whose value changed between t0 and t1: "<delta> <series>".
for app in "${apps[@]}"; do
  awk 'FNR == NR && !/^#/ { k = $0; sub(/ [^ ]+$/, "", k); a[k] = $NF; next }
       !/^#/ { k = $0; sub(/ [^ ]+$/, "", k); if ((k in a) && $NF != a[k]) print $NF - a[k], k }' \
    "$out/$app-t0.txt" "$out/$app-t1.txt" | sort -k2 > "$out/$app-delta.txt"
done

# Metric names mentioning identity or issuer, from the proxies and the controller.
cat "$out"/*-t1.txt | awk '!/^#/ { n = $1; sub(/\{.*/, "", n); print n }' \
  | grep -i -e identity -e issuer | sort -u > "$out/identity-metric-names.txt"
log "discovery data in $out"
