#!/usr/bin/env bash
# Runs INSIDE the cluster VM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/k3s.sh"

install_k3s
echo -n 'kube-dns ClusterIP (must match COREDNS_ADDR): '
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
