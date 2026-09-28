#!/usr/bin/env bash
# Runs on the macOS HOST. Compares the before/after records of the SPIFFE cluster-side
# scripts (lab/refactor-check.sh). Fails on any difference that matters: an exit
# status, the final `linkerd check`, the versions, or the set of pods and their state.
# Prints the remaining per-log diffs for a human to classify.
# Usage: refactor-compare.sh <before-dir> <after-dir>
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
require_cmd perl
before="${1:?usage: refactor-compare.sh <before-dir> <after-dir>}"
after="${2:?usage: refactor-compare.sh <before-dir> <after-dir>}"
bad=0

for f in gen-certs.log install-k3s.log install-linkerd.log linkerd-check.txt; do
  b="$(tail -n 1 "$before/$f")"; a="$(tail -n 1 "$after/$f")"
  [ "$b" = "$a" ] || { err "$f: exit differs (before '$b', after '$a')"; bad=1; }
done
diff -u "$before/linkerd-version.txt" "$after/linkerd-version.txt" || { err "linkerd-version.txt differs"; bad=1; }
# linkerd check lists control-plane/viz proxy pod names, which carry a
# ReplicaSet-hash and pod-suffix that differ on every install -- even with
# identical inputs -- because Kubernetes hashes the pod template, which
# embeds the freshly generated trust anchor. Normalise those suffixes out
# before comparing. perl (not awk) because macOS's BSD awk lacks reliable
# {n,m} interval regexes.
normalize_pods() { perl -pe 's/-[a-z0-9]{6,10}-[a-z0-9]{5}(?= )/-<pod-suffix>/g' "$1"; }
diff -u <(normalize_pods "$before/linkerd-check.txt") <(normalize_pods "$after/linkerd-check.txt") \
  || { err "linkerd-check.txt differs"; bad=1; }
# Pod names carry random suffixes; compare namespace, READY and STATUS per pod count.
pod_shape() { awk 'NR>1 {print $1, $3, $4}' "$1/pods.txt" | sort | uniq -c; }
diff -u <(pod_shape "$before") <(pod_shape "$after") || { err "pod set differs"; bad=1; }

for f in gen-certs.log install-k3s.log install-linkerd.log; do
  log "diff of $f (classify every hunk in COMPARISON.md):"
  diff -u "$before/$f" "$after/$f" || true
done
[ "$bad" -eq 0 ] || die "the refactor changed SPIFFE behaviour"
log "exit statuses, linkerd check, versions and pod set all match"
