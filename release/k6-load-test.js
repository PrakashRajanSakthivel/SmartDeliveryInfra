/**
 * SmartDelivery — k6 Load Test
 *
 * Simulates the full checkout flow:
 *   register/login → browse restaurant → add to cart → create order → pay → clear cart
 *
 * Each VU uses its own isolated user account (registered once per VU in setup),
 * so cart state doesn't collide across virtual users.
 *
 * Usage:
 *   k6 run SmartDelivery/scripts/k6-load-test.js
 *
 * Override target VUs / duration:
 *   k6 run --vus 10 --duration 2m SmartDelivery/scripts/k6-load-test.js
 *
 * Targets: https://smartdeliveryapi.rajanlabs.com
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate } from 'k6/metrics';

// ── Ingress base paths ────────────────────────────────────────────────────────
const BASE  = 'https://smartdeliveryapi.rajanlabs.com';
const AUTH  = `${BASE}/authservice`;
const REST  = `${BASE}/restaurentservice`;
const ORDER = `${BASE}/orderservice`;
const CART  = `${BASE}/cartservice`;
const PAY   = `${BASE}/paymentservice`;

// Seeded restaurant — fixed GUID from scripts/seed-restaurants.sql
// If not seeded, setup() will create it automatically.
const SEED_RESTAURANT_ID = '11111111-0000-0000-0000-000000000001';

// ── Custom metrics ────────────────────────────────────────────────────────────
const checkoutDuration = new Trend('checkout_full_flow_ms', true);
const orderErrors      = new Rate('order_errors');

// ── Load shape ────────────────────────────────────────────────────────────────
// Conservative for a single-node 4vCPU / 7.5 GiB VPS.
// Adjust maxVUs and hold duration to push further once baseline is confirmed.
export const options = {
  stages: [
    { duration: '1m',  target: 5  },  // warm-up
    { duration: '3m',  target: 20 },  // ramp up
    { duration: '3m',  target: 20 },  // hold — observe HPA + Grafana
    { duration: '1m',  target: 0  },  // ramp down
  ],
  thresholds: {
    http_req_failed:        ['rate<0.05'],   // < 5% HTTP errors overall
    http_req_duration:      ['p(95)<2000'],  // p95 latency < 2 s
    checkout_full_flow_ms:  ['p(95)<5000'],  // full checkout p95 < 5 s
    order_errors:           ['rate<0.05'],   // < 5% order creation failures
  },
};

// ── Setup: seed restaurant once before load starts ────────────────────────────
export function setup() {
  const headers = { 'Content-Type': 'application/json' };

  // Check if seeded restaurant exists
  let r = http.get(`${REST}/api/restaurants/${SEED_RESTAURANT_ID}/details`);
  if (r.status !== 200) {
    console.log('Seeded restaurant not found — creating it now...');
    http.post(`${REST}/api/restaurants`, JSON.stringify({
      name: 'Burger House',
      description: 'Juicy burgers and crispy fries',
      address: '10 Burger Lane',
      phoneNumber: '555-100-0001',
      deliveryFee: 1.99,
      minOrderAmount: 8.00,
      categories: [{ name: 'Burgers', displayOrder: 1 }],
      menuItems: [{
        name: 'Classic Cheeseburger',
        description: 'Beef patty, cheese, lettuce, tomato',
        price: 9.99,
        categoryId: null,
        isVegetarian: false,
        isVegan: false,
        preparationTime: 15,
      }],
    }), { headers });
    r = http.get(`${REST}/api/restaurants/${SEED_RESTAURANT_ID}/details`);
  }

  const details = JSON.parse(r.body);
  const menuItem = details.menuItems[0];

  console.log(`Restaurant ready. Menu item: ${menuItem.name} @ $${menuItem.price}`);
  return {
    menuItemId:    menuItem.id,
    menuItemName:  menuItem.name,
    menuItemPrice: menuItem.price,
  };
}

// ── Main VU scenario ──────────────────────────────────────────────────────────
export default function (data) {
  const headers = { 'Content-Type': 'application/json' };

  // Each VU registers its own user account on first iteration.
  // Username is stable per VU so re-runs just fall back to login.
  const username = `loadtest_vu_${__VU}`;
  const password = 'LoadTest#2026!';

  // ── Step 1: Register (or login if already exists) ─────────────────────────
  let loginRes = http.post(`${AUTH}/api/auth/register`,
    JSON.stringify({ username, password }),
    { headers, tags: { name: 'register' } }
  );

  // If username already exists (pod rerun), fall back to login
  if (loginRes.status !== 201) {
    loginRes = http.post(`${AUTH}/api/auth/login`,
      JSON.stringify({ username, password }),
      { headers, tags: { name: 'login' } }
    );
  }

  const loginOk = check(loginRes, {
    'auth success': r => r.status === 200 || r.status === 201,
    'token present': r => {
      try { return !!JSON.parse(r.body).token; } catch { return false; }
    },
  });
  if (!loginOk) { sleep(1); return; }

  const authBody = JSON.parse(loginRes.body);
  const token  = authBody.token;
  const userId = authBody.user?.userId;
  const authHeaders = { ...headers, Authorization: `Bearer ${token}` };

  // ── Start timing the full checkout flow ───────────────────────────────────
  const flowStart = Date.now();

  sleep(0.3);

  // ── Step 2: Browse restaurant ─────────────────────────────────────────────
  const restRes = http.get(
    `${REST}/api/restaurants/${SEED_RESTAURANT_ID}/details`,
    { headers: authHeaders, tags: { name: 'get_restaurant' } }
  );
  check(restRes, { 'restaurant 200': r => r.status === 200 });

  sleep(0.5);

  // ── Step 3: Add item to cart ──────────────────────────────────────────────
  const cartRes = http.post(
    `${CART}/api/cart/${userId}/items`,
    JSON.stringify({
      menuItemId:   data.menuItemId,
      menuItemName: data.menuItemName,
      quantity:     1,
      unitPrice:    data.menuItemPrice,
      imageUrl:     null,
    }),
    { headers: authHeaders, tags: { name: 'add_to_cart' } }
  );
  check(cartRes, { 'cart add 2xx': r => r.status >= 200 && r.status < 300 });

  sleep(0.5);

  // ── Step 4: Create order ──────────────────────────────────────────────────
  const orderRes = http.post(
    `${ORDER}/api/orders`,
    JSON.stringify({
      userId:       userId,
      restaurantId: SEED_RESTAURANT_ID,
      items: [{
        menuItemId: data.menuItemId,
        itemName:   data.menuItemName,
        quantity:   1,
        unitPrice:  data.menuItemPrice,
      }],
      notes: 'k6 load test',
    }),
    { headers: authHeaders, tags: { name: 'create_order' } }
  );
  const orderOk = check(orderRes, { 'order created 2xx': r => r.status >= 200 && r.status < 300 });
  orderErrors.add(!orderOk);

  let orderId = null;
  if (orderOk) {
    try {
      const ob = JSON.parse(orderRes.body);
      orderId = ob.orderId || ob.id || ob.Id;
    } catch {}
  }

  sleep(0.5);

  // ── Step 5: Payment intent ────────────────────────────────────────────────
  const total = parseFloat((data.menuItemPrice + 2.99).toFixed(2));
  const intentRes = http.post(
    `${PAY}/api/payments/intents`,
    JSON.stringify({ amount: total, currency: 'usd' }),
    { headers: authHeaders, tags: { name: 'payment_intent' } }
  );
  check(intentRes, { 'payment intent 2xx': r => r.status >= 200 && r.status < 300 });

  let paymentIntentId = null;
  if (intentRes.status >= 200 && intentRes.status < 300) {
    try {
      const pb = JSON.parse(intentRes.body);
      paymentIntentId = pb.paymentIntentId || pb.id || pb.Id;
    } catch {}
  }

  sleep(0.3);

  // ── Step 6: Confirm payment ───────────────────────────────────────────────
  if (paymentIntentId) {
    const confirmRes = http.post(
      `${PAY}/api/payments/confirm`,
      JSON.stringify({ paymentIntentId }),
      { headers: authHeaders, tags: { name: 'payment_confirm' } }
    );
    check(confirmRes, { 'payment confirmed 2xx': r => r.status >= 200 && r.status < 300 });
  }

  sleep(0.3);

  // ── Step 7: Clear cart ────────────────────────────────────────────────────
  http.del(
    `${CART}/api/cart/${userId}`,
    null,
    { headers: authHeaders, tags: { name: 'clear_cart' } }
  );

  // ── Record full checkout duration ─────────────────────────────────────────
  checkoutDuration.add(Date.now() - flowStart);

  sleep(1);
}

// ── Teardown (optional summary logging) ──────────────────────────────────────
export function teardown(data) {
  console.log('Load test complete.');
  console.log(`Restaurant used: ${SEED_RESTAURANT_ID}`);
  console.log(`Menu item tested: ${data.menuItemName} @ $${data.menuItemPrice}`);
}
