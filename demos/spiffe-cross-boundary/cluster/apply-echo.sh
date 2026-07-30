#!/usr/bin/env bash
# Runs INSIDE the cluster VM.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
kubectl apply -f "$HERE/echo.yaml"
kubectl -n mixed-env rollout status deploy/echo --timeout=120s
kubectl -n mixed-env wait --for=condition=Ready pod/client --timeout=120s
