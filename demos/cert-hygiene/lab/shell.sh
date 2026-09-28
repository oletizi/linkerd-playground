#!/usr/bin/env bash
# Runs INSIDE the lab VM. A login shell in the demo directory; extra args go to bash
# (e.g. `-c 'kubectl get pods -A'`).
set -euo pipefail
exec bash -l "$@"
