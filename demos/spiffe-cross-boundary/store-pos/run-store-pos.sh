#!/usr/bin/env bash
# Runs INSIDE the edge VM. Serves the on-prem POS on port 80 (host network),
# so the ExternalWorkload port 80 wiring is unchanged from the echo demo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo docker rm -f store-pos edge-echo 2>/dev/null || true
sudo docker run -d --name store-pos --restart=unless-stopped --network host \
  -e PORT=80 -e STORE_ID=042 \
  -v "$HERE/server.js:/app/server.js:ro" \
  node:20-alpine node /app/server.js
sleep 2
sudo docker ps --filter name=store-pos --format '{{.Names}} {{.Status}}'
curl -s -m5 http://localhost:80/inventory | head -c 160; echo
