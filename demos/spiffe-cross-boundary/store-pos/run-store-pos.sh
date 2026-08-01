#!/usr/bin/env bash
# Runs INSIDE the store (edge) VM. The POS pushes to the cloud, so it's a client:
# it must run as NON-root (uid != proxy's uid 0) so the edge iptables OUTPUT rule
# redirects its traffic through linkerd2-proxy for mTLS + SPIFFE identity.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo docker rm -f store-pos edge-echo 2>/dev/null || true
sudo docker run -d --name store-pos --restart=unless-stopped --network host --user 1000:1000 \
  -e STORE_ID=042 \
  -e INGEST_URL="http://retail-cloud.mixed-env.svc.cluster.local:8090/ingest" \
  -v "$HERE/server.js:/app/server.js:ro" \
  node:20-alpine node /app/server.js
sleep 3
sudo docker logs --tail 4 store-pos
