'use strict';
// retail-cloud: the in-cluster app. It RECEIVES pushes from the store on a meshed
// ingest port (gated so only the store's SPIFFE identity may report), caches the
// latest report, and serves the dashboard from that cache. The Void button flips
// the real Linkerd policy so the store's pushes are refused. No dependencies.
const http = require('http');
const https = require('https');
const fs = require('fs');

const UI_PORT = Number(process.env.PORT || 8080);
const INGEST_PORT = Number(process.env.INGEST_PORT || 8090);
const NS = process.env.DEMO_NS || 'mixed-env';
const AUTHN = process.env.AUTHN_NAME || 'allow-store';
const STORE_ID = 'spiffe://root.linkerd.cluster.local/store-pos';
const CLOUD_ID = 'retail-cloud.' + NS + '.serviceaccount.identity.linkerd.cluster.local';
const DENY_ID = 'blocked.' + NS + '.serviceaccount.identity.linkerd.cluster.local';
const STALE_MS = 6000;

const html = fs.readFileSync(__dirname + '/index.html');
const tutorial = fs.readFileSync(__dirname + '/tutorial.html');

let latest = { inventory: [], sales: [], reportedAt: 0 };
let voided = false;

function json(res, o) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); }

// PATCH the MeshTLSAuthentication identities via the in-cluster API (SA token).
function setAllowed(identity) {
  return new Promise((resolve, reject) => {
    const sa = '/var/run/secrets/kubernetes.io/serviceaccount';
    const token = fs.readFileSync(sa + '/token', 'utf8');
    const ca = fs.readFileSync(sa + '/ca.crt');
    const body = JSON.stringify({ spec: { identities: [identity] } });
    const req = https.request({
      host: 'kubernetes.default.svc', port: 443,
      path: `/apis/policy.linkerd.io/v1alpha1/namespaces/${NS}/meshtlsauthentications/${AUTHN}`,
      method: 'PATCH', ca,
      headers: { 'Content-Type': 'application/merge-patch+json', Authorization: 'Bearer ' + token, 'Content-Length': Buffer.byteLength(body) },
    }, (r) => { let d = ''; r.on('data', c => d += c); r.on('end', () => (r.statusCode < 300 ? resolve() : reject(new Error('k8s ' + r.statusCode + ' ' + d)))); });
    req.on('error', reject); req.end(body);
  });
}

// Ingest server (:8090). A Linkerd Server + AuthorizationPolicy gate this port so
// only the store's SPIFFE identity may push; when voided, requests never arrive here.
http.createServer((req, res) => {
  if (req.method === 'POST' && req.url.split('?')[0] === '/ingest') {
    let b = ''; req.on('data', c => (b += c));
    req.on('end', () => {
      try {
        const d = JSON.parse(b || '{}');
        latest = { inventory: d.inventory || [], sales: d.sales || [], reportedAt: Date.now() };
        res.writeHead(200); res.end('ok');
      } catch (e) { res.writeHead(400); res.end('bad'); }
    });
    return;
  }
  res.writeHead(404); res.end();
}).listen(INGEST_PORT, () => console.log('ingest on :' + INGEST_PORT));

// UI + API server (:8080), open to the browser (no Linkerd Server on this port).
http.createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  if (path === '/' || path === '/index.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(html); }
  if (path === '/tutorial') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(tutorial); }

  if (path === '/api/data') {
    const ageMs = latest.reportedAt ? Date.now() - latest.reportedAt : null;
    const reporting = ageMs !== null && ageMs < STALE_MS;
    return json(res, {
      ok: reporting && !voided, voided, reporting, ageMs,
      identities: { cloud: CLOUD_ID, store: STORE_ID },
      inventory: latest.inventory, sales: latest.sales,
    });
  }

  if (path === '/api/policy' && req.method === 'POST') {
    let b = ''; req.on('data', c => (b += c));
    req.on('end', async () => {
      try {
        const allow = JSON.parse(b || '{}').allow !== false;
        await setAllowed(allow ? STORE_ID : DENY_ID);
        voided = !allow;
        json(res, { allow });
      } catch (e) { res.writeHead(500); res.end(JSON.stringify({ error: String(e.message || e) })); }
    });
    return;
  }

  res.writeHead(404); res.end('not found');
}).listen(UI_PORT, () => console.log('retail-cloud UI on :' + UI_PORT));
