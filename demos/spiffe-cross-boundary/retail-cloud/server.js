'use strict';
// retail-cloud: the in-cluster web app. Serves the dashboard, fetches the store's
// POS data across the mesh (mTLS), and flips the real Linkerd AuthorizationPolicy
// so the "void" button denies the cloud app's identity for real. No dependencies.
const http = require('http');
const https = require('https');
const fs = require('fs');

const PORT = process.env.PORT || 8080;
const STORE_BASE = process.env.STORE_BASE || 'http://store-pos.mixed-env.svc.cluster.local';
const NS = process.env.DEMO_NS || 'mixed-env';
const AUTHN = process.env.AUTHN_NAME || 'allow-retail-cloud';
const CLOUD_ID = 'retail-cloud.' + NS + '.serviceaccount.identity.linkerd.cluster.local';
const STORE_ID = 'spiffe://root.linkerd.cluster.local/store-pos';
const DENY_ID = 'blocked.' + NS + '.serviceaccount.identity.linkerd.cluster.local';

const html = fs.readFileSync(__dirname + '/index.html');
const tutorial = fs.readFileSync(__dirname + '/tutorial.html');

function getJSON(url) {
  const t0 = Date.now();
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: 4000 }, (r) => {
      let d = '';
      r.on('data', (c) => (d += c));
      r.on('end', () => resolve({ code: r.statusCode, body: d, ms: Date.now() - t0 }));
    });
    req.on('error', (e) => resolve({ code: 0, error: e.code || String(e), ms: Date.now() - t0 }));
    req.on('timeout', () => { req.destroy(); resolve({ code: 0, error: 'timeout', ms: Date.now() - t0 }); });
  });
}

// PATCH the MeshTLSAuthentication identities via the in-cluster API using the SA token.
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

const server = http.createServer(async (req, res) => {
  const path = req.url.split('?')[0];

  if (path === '/' || path === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(html);
  }
  if (path === '/tutorial') {
    res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(tutorial);
  }

  if (path === '/api/data') {
    const [inv, sales] = await Promise.all([getJSON(STORE_BASE + '/inventory'), getJSON(STORE_BASE + '/sales')]);
    const ok = inv.code >= 200 && inv.code < 300;
    const out = { ok, identities: { cloud: CLOUD_ID, store: STORE_ID }, link: { ok, code: inv.code, ms: inv.ms } };
    if (ok) { out.inventory = JSON.parse(inv.body).items; out.sales = JSON.parse(sales.body || '{"sales":[]}').sales; }
    else { out.reason = inv.code === 403 ? 'denied' : (inv.error || 'unreachable'); out.code = inv.code; }
    res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify(out));
  }

  if (path === '/api/policy' && req.method === 'POST') {
    let b = ''; req.on('data', c => b += c);
    req.on('end', async () => {
      try {
        const allow = JSON.parse(b || '{}').allow !== false;
        await setAllowed(allow ? CLOUD_ID : DENY_ID);
        res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ allow }));
      } catch (e) { res.writeHead(500, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: String(e.message || e) })); }
    });
    return;
  }

  res.writeHead(404); res.end('not found');
});
server.listen(PORT, () => console.log('retail-cloud on :' + PORT));
