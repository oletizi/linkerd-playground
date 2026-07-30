'use strict';
// store-pos: the on-prem point-of-sale + inventory service that runs on the
// edge machine and is joined to the mesh via SPIFFE. No dependencies (Node http).
const http = require('http');

const PORT = process.env.PORT || 80;
const STORE = process.env.STORE_ID || '042';

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
  // reflect the sale in stock so inventory drifts like a real store
  const hit = inventory[Math.floor(Math.random() * inventory.length)];
  if (hit.stock > 0) hit.stock -= 1;
}
// periodic restock ("deliveries") so the store stays lively and never drains to empty
function delivery() {
  const p = inventory[Math.floor(Math.random() * inventory.length)];
  p.stock = Math.min(200, p.stock + 15 + Math.floor(Math.random() * 45));
}
for (let i = 0; i < 6; i++) ring();
setInterval(ring, 3000);
setInterval(delivery, 5000);

function status(n) { return n === 0 ? 'out' : n <= 12 ? 'low' : 'ok'; }

function send(res, code, body) {
  const s = JSON.stringify(body);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(s) });
  res.end(s);
}

http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  if (path === '/health') return send(res, 200, { ok: true, store: STORE });
  if (path === '/inventory')
    return send(res, 200, { store: STORE, items: inventory.map(p => ({ ...p, status: status(p.stock) })) });
  if (path === '/sales')
    return send(res, 200, { store: STORE, sales: sales.slice(0, 8) });
  send(res, 404, { error: 'not found' });
}).listen(PORT, () => console.log(`store-pos #${STORE} listening on :${PORT}`));
