'use strict';
// store-pos: the on-prem point-of-sale service. It runs on the store machine,
// outside Kubernetes, and PUSHES inventory + sales up to the cloud over the mesh
// (the realistic direction — the cloud never depends on the store being reachable).
// Its outbound traffic goes through the standalone linkerd2-proxy, so every push
// carries the store's SPIFFE identity and is mTLS-encrypted. No dependencies.
const http = require('http');

const STORE = process.env.STORE_ID || '042';
const INGEST = process.env.INGEST_URL || 'http://retail-cloud.mixed-env.svc.cluster.local:8090/ingest';
const PUSH_MS = Number(process.env.PUSH_MS || 2000);

const inventory = [
  { sku: 'CFE-102', name: 'House Blend Coffee 1kg', aisle: 'A3', stock: 142 },
  { sku: 'MLK-011', name: 'Oat Milk 1L', aisle: 'C1', stock: 8 },
  { sku: 'BRD-204', name: 'Sourdough Loaf', aisle: 'B2', stock: 0 },
  { sku: 'EGG-050', name: 'Free-range Eggs 12ct', aisle: 'C4', stock: 64 },
  { sku: 'BTR-013', name: 'Salted Butter 250g', aisle: 'C2', stock: 11 },
  { sku: 'APL-088', name: 'Gala Apples /kg', aisle: 'Produce', stock: 96 },
];
const CART = [
  ['Coffee 1kg', 14.99], ['Oat Milk ×2', 6.40], ['Eggs · Butter', 9.15],
  ['Apples 0.8kg', 3.12], ['Sourdough', 5.50], ['Coffee · Oat Milk ×2', 18.40],
];

let ticket = 8838;
const sales = [];
function ring() {
  const [items, amount] = CART[Math.floor(Math.random() * CART.length)];
  sales.unshift({ id: ticket++, items, amount, at: new Date().toISOString() });
  if (sales.length > 12) sales.pop();
  const hit = inventory[Math.floor(Math.random() * inventory.length)];
  if (hit.stock > 0) hit.stock -= 1;
}
function delivery() {
  const p = inventory[Math.floor(Math.random() * inventory.length)];
  p.stock = Math.min(200, p.stock + 15 + Math.floor(Math.random() * 45));
}
function status(n) { return n === 0 ? 'out' : n <= 12 ? 'low' : 'ok'; }
for (let i = 0; i < 6; i++) ring();
setInterval(ring, 3000);
setInterval(delivery, 5000);

function snapshot() {
  return JSON.stringify({
    store: STORE,
    inventory: inventory.map(p => ({ ...p, status: status(p.stock) })),
    sales: sales.slice(0, 8),
  });
}

// Push the current snapshot to the cloud. The proxy adds mTLS + identity;
// if the cloud has revoked our identity, this comes back 403.
function push() {
  const body = snapshot();
  const u = new URL(INGEST);
  const req = http.request({
    hostname: u.hostname, port: u.port || 80, path: u.pathname, method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    timeout: 4000,
  }, (r) => { r.resume(); console.log(`push -> ${r.statusCode}${r.statusCode === 403 ? ' (authorization voided by cloud)' : ''}`); });
  req.on('error', (e) => console.log('push error:', e.code || String(e)));
  req.on('timeout', () => { req.destroy(); console.log('push timeout'); });
  req.end(body);
}
console.log(`store-pos #${STORE} reporting to ${INGEST} every ${PUSH_MS}ms`);
setInterval(push, PUSH_MS);
push();
