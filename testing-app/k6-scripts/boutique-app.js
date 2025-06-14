import http from 'k6/http';
import { sleep, check } from 'k6';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';

// Frontend IP - Replace with yours (e.g., 'http://34.XXX.XXX.XXX:8080')
const BASE_URL = 'http://34.170.63.98:80';

// Products from Locust
const PRODUCTS = [
  '0PUK6V6EV0', '1YMWWN1N4O', '2ZYFJ3GM2N', '66VCHSJNUP',
  '6E92ZMYYFZ', '9SIQT8TOJO', 'L9ECAV7KIM', 'LS4PSXUNUM', 'OLJCESPC7Z'
];

// Currencies from Locust
const CURRENCIES = ['EUR', 'USD', 'JPY', 'CAD', 'GBP', 'TRY'];

// Options: 1000 users, ramp to match Locust
export const options = {
  stages: [
    { duration: '60s', target: 20 }, // Ramp to 1000 users (21 RPS avg)
    { duration: '5m', target: 20 },  // Hold 1000 users (peaks ~200 RPS)
    { duration: '30s', target: 0 },    // Ramp down
  ],
  thresholds: {
    'http_req_duration': ['p(95)<1500'], // Check p99 < 2000ms (your SLO?)
  },
};

// Weighted tasks (1:2:10:2:3:1 = 19 total weight)
const TASKS = [
  { fn: index, weight: 1 },
  { fn: setCurrency, weight: 2 },
  { fn: browseProduct, weight: 10 },
  { fn: addToCart, weight: 2 },
  { fn: viewCart, weight: 3 },
  { fn: checkout, weight: 1 },
];

// Task functions
function index() {
  const res = http.get(`${BASE_URL}/`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}

function setCurrency() {
  const currency = CURRENCIES[Math.floor(Math.random() * CURRENCIES.length)];
  const res = http.post(`${BASE_URL}/setCurrency`, JSON.stringify({ currency_code: currency }), {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status is 200': (r) => r.status === 200 });
}

function browseProduct() {
  const product = PRODUCTS[Math.floor(Math.random() * PRODUCTS.length)];
  const res = http.get(`${BASE_URL}/product/${product}`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}

function addToCart() {
  const product = PRODUCTS[Math.floor(Math.random() * PRODUCTS.length)];
  http.get(`${BASE_URL}/product/${product}`); // Mimic Locust's product view
  const res = http.post(`${BASE_URL}/cart`, JSON.stringify({
    product_id: product,
    quantity: randomIntBetween(1, 10),
  }), {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status is 200': (r) => r.status === 200 });
}

function viewCart() {
  const res = http.get(`${BASE_URL}/cart`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}

function checkout() {
  addToCart(); // Pre-checkout cart add, like Locust
  const currentYear = new Date().getFullYear() + 1;
  const res = http.post(`${BASE_URL}/cart/checkout`, JSON.stringify({
    email: `test${randomIntBetween(1, 10000)}@example.com`,
    street_address: `${randomIntBetween(1, 999)} Main St`,
    zip_code: `${randomIntBetween(10000, 99999)}`,
    city: 'Testville',
    state: 'CA',
    country: 'United States',
    credit_card_number: `4${randomIntBetween(100000000000, 999999999999)}`, // Visa prefix
    credit_card_expiration_month: randomIntBetween(1, 12),
    credit_card_expiration_year: randomIntBetween(currentYear, currentYear + 70),
    credit_card_cvv: randomIntBetween(100, 999),
  }), {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status is 200': (r) => r.status === 200 });
}

// Weighted random task picker
function pickTask() {
  const totalWeight = TASKS.reduce((sum, task) => sum + task.weight, 0);
  let rand = Math.random() * totalWeight;
  for (const task of TASKS) {
    if (rand < task.weight) return task.fn;
    rand -= task.weight;
  }
}

// Main test function
export default function () {
  const task = pickTask();
  task();
  sleep(randomIntBetween(1, 10) / 1000); // 1-10s wait, in seconds
}
