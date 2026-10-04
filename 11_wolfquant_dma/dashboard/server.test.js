import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createDashboardServer } from './server.js';

const correctHost = '127.0.0.1:4174';
const origin = `http://${correctHost}`;
const monitor = async () => ({
  status: 'online', temperature: 40, sampledAt: new Date().toISOString(),
  protection: { power: { state: 'ready' }, hostInterlock: { state: 'online' } },
});

async function start(options) {
  const dashboard = createDashboardServer({ initialJob: null, save: () => {}, monitor, ...options });
  await new Promise((resolve) => dashboard.server.listen(0, '127.0.0.1', resolve));
  return dashboard;
}

function request(dashboard, pathname, method = 'GET', headers = {}, body = '') {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: dashboard.server.address().port,
      path: pathname, method, headers: { Host: correctHost, ...headers },
    }, (res) => {
      let text = '';
      res.on('data', (chunk) => { text += chunk; });
      res.on('end', () => {
        let data;
        try { data = JSON.parse(text); } catch { data = text; }
        resolve({ status: res.statusCode, data, headers: res.headers });
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

test('status exposes monitor and no test before first click', async () => {
  const dashboard = await start();
  try {
    const result = await request(dashboard, '/api/status');
    assert.equal(result.status, 200);
    assert.equal(result.data.test, null);
    assert.equal(result.data.monitor.temperature, 40);
    assert.equal(result.data.monitor.ready, true);
    assert.equal(result.data.sample.mode, 'cpu-self-test');
    assert.equal(result.data.sample.fpga, null);
    assert.equal(result.data.sample.sample.closes.length, 21);
    assert.equal(result.headers['cache-control'], 'no-store');
  } finally { await dashboard.stop(); }
});

test('status flags implausible sensor readings before a click', async () => {
  const dashboard = await start({ monitor: async () => ({
    status: 'online', temperature: -8388607.996, sampledAt: new Date().toISOString(),
    protection: { threshold: 80, power: { state: 'ready' }, hostInterlock: { state: 'online' } },
  }) });
  try {
    const result = await request(dashboard, '/api/status');
    assert.equal(result.data.monitor.ready, false);
    assert.match(result.data.monitor.message, /温度读数异常/);
  } finally { await dashboard.stop(); }
});

test('Host, Origin, custom action header, and empty payload protect hardware action', async () => {
  const dashboard = await start({ run: async () => {} });
  try {
    const base = { Origin: origin, 'Content-Type': 'application/json', 'X-WQ-Action': 'run' };
    assert.equal((await request(dashboard, '/api/test', 'POST', { ...base, Host: 'evil.example' }, '{}')).status, 403);
    assert.equal((await request(dashboard, '/api/test', 'POST', { ...base, Origin: 'https://evil.example' }, '{}')).status, 403);
    assert.equal((await request(dashboard, '/api/test', 'POST', { Origin: origin, 'Content-Type': 'application/json' }, '{}')).status, 403);
    assert.equal((await request(dashboard, '/api/test', 'POST', base, '{"command":"reboot"}')).status, 400);
    assert.equal(dashboard.getJob(), null);
  } finally { await dashboard.stop(); }
});

test('only files inside the public dashboard directory are served', async () => {
  const dashboard = await start();
  try {
    const home = await request(dashboard, '/');
    assert.equal(home.status, 200);
    assert.match(home.data, /WolfQuant/);
    const privateFile = await request(dashboard, '/server.js');
    assert.equal(privateFile.status, 404);
    const traversal = await request(dashboard, '/%2e%2e/%2e%2e/runner.js');
    assert.equal(traversal.status, 404);
  } finally { await dashboard.stop(); }
});

test('only one fixed hardware job runs at a time', async () => {
  let release;
  const hold = new Promise((resolve) => { release = resolve; });
  const dashboard = await start({ run: async (job, { onUpdate }) => {
    await hold;
    job.state = 'passed';
    job.finishedAt = new Date().toISOString();
    onUpdate();
  } });
  try {
    const headers = { Origin: origin, 'Content-Type': 'application/json', 'X-WQ-Action': 'run' };
    const first = await request(dashboard, '/api/test', 'POST', headers, '{}');
    const second = await request(dashboard, '/api/test', 'POST', headers, '{}');
    assert.equal(first.status, 202);
    assert.equal(second.status, 409);
    assert.equal(first.data.test.id, second.data.test.id);
    release();
    await dashboard.getActive();
    const status = await request(dashboard, '/api/status');
    assert.equal(status.data.test.state, 'passed');
  } finally { release(); await dashboard.stop(); }
});

test('failed Golden restoration blocks another hardware job', async () => {
  let calls = 0;
  const dashboard = await start({
    initialJob: { id: 'old-job', state: 'failed', restoreStatus: 'failed', steps: [], report: null },
    run: async () => { calls += 1; },
  });
  try {
    const headers = { Origin: origin, 'Content-Type': 'application/json', 'X-WQ-Action': 'run' };
    const result = await request(dashboard, '/api/test', 'POST', headers, '{}');
    assert.equal(result.status, 409);
    assert.match(result.data.error, /Golden restoration failed/);
    assert.equal(calls, 0);
  } finally { await dashboard.stop(); }
});
