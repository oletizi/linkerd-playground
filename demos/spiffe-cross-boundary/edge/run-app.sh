#!/usr/bin/env bash
# Runs INSIDE the edge VM. The edge-hosted echo app (host networking, port 80).
set -euo pipefail
sudo docker rm -f edge-echo 2>/dev/null || true
sudo docker run -d --name edge-echo --network host -e PORT=80 ealen/echo-server:latest
