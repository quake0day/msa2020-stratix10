import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createDashboardServer } from './server.js';
import { recheckGolden } from './runner.js';

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

test('same-origin read-only recheck verifies Golden and preserves the failed test', async () => {
  const original = {
    id: 'old-job', state: 'failed', restoreStatus: 'failed', error: 'Original program failure',
    steps: [{ name: 'restore_golden', status: 'failed' }], report: null,
  };
  const specs = [];
  let runs = 0;
  const dashboard = await start({
    initialJob: original,
    recheck: (job, deps) => recheckGolden(job, {
      ...deps, command: async (spec) => { specs.push(spec); return { stdout: 'GOLDEN\n', stderr: '' }; },
    }),
    run: async () => { runs += 1; },
  });
  try {
    const headers = { Origin: origin, 'Content-Type': 'application/json', 'X-WQ-Action': 'recheck-golden' };
    assert.equal((await request(dashboard, '/api/recheck-golden', 'POST', { ...headers, Origin: 'https://evil.example' }, '{}')).status, 403);
    assert.equal((await request(dashboard, '/api/recheck-golden', 'POST', { ...headers, 'X-WQ-Action': 'run' }, '{}')).status, 403);
    assert.equal((await request(dashboard, '/api/recheck-golden', 'POST', headers, '{"command":"reset"}')).status, 400);
    assert.equal(specs.length, 0);
    const response = await request(dashboard, '/api/recheck-golden', 'POST', headers, '{}');
    assert.equal(response.status, 202);
    await dashboard.getActive();
    assert.equal(specs.length, 1);
    assert.equal(specs[0].label, 'Recheck Golden health');
    assert.equal(original.state, 'failed');
    assert.equal(original.error, 'Original program failure');
    assert.equal(original.steps[0].status, 'failed');
    assert.equal(original.restoreStatus, 'golden');
    assert.equal(original.goldenRecheck.state, 'passed');
    assert.equal((await request(dashboard, '/api/recheck-golden', 'POST', headers, '{}')).status, 409);
    const runHeaders = { ...headers, 'X-WQ-Action': 'run' };
    assert.equal((await request(dashboard, '/api/test', 'POST', runHeaders, '{}')).status, 202);
    await dashboard.getActive();
    assert.equal(runs, 1);
  } finally { await dashboard.stop(); }
});

test('failed Golden recheck keeps the hardware job locked', async () => {
  const original = { id: 'old-job', state: 'failed', restoreStatus: 'failed', error: 'Original failure', steps: [] };
  const dashboard = await start({
    initialJob: original,
    recheck: (job, deps) => recheckGolden(job, {
      ...deps, command: async () => ({ stdout: 'DEGRADED\n', stderr: '' }),
    }),
  });
  try {
    const headers = { Origin: origin, 'Content-Type': 'application/json', 'X-WQ-Action': 'recheck-golden' };
    assert.equal((await request(dashboard, '/api/recheck-golden', 'POST', headers, '{}')).status, 202);
    await dashboard.getActive();
    assert.equal(original.restoreStatus, 'failed');
    assert.equal(original.goldenRecheck.state, 'failed');
    assert.equal((await request(dashboard, '/api/test', 'POST', { ...headers, 'X-WQ-Action': 'run' }, '{}')).status, 409);
  } finally { await dashboard.stop(); }
});

test('interrupted read-only recheck becomes retryable only after a successful bind', async () => {
  const first = await start();
  const original = {
    id: 'old-job', state: 'failed', restoreStatus: 'failed', error: 'Original program failure',
    steps: [{ name: 'restore_golden', status: 'failed' }],
    goldenRecheck: { state: 'running', startedAt: '2026-10-04T08:55:00.000Z', finishedAt: null },
  };
  let saved = 0;
  const duplicate = createDashboardServer({
    initialJob: original, save: () => { saved += 1; }, monitor,
    recheck: async () => { throw new Error('must not run'); },
  });
  try {
    await new Promise((resolve) => {
      duplicate.server.once('error', (error) => {
        assert.equal(error.code, 'EADDRINUSE');
        resolve();
      });
      duplicate.server.listen(first.server.address().port, '127.0.0.1');
    });
    assert.equal(original.goldenRecheck.state, 'running');
    assert.equal(saved, 0);
    const bound = await start({
      initialJob: original,
      recheck: (job, deps) => recheckGolden(job, {
        ...deps, command: async () => ({ stdout: 'GOLDEN\n', stderr: '' }),
      }),
    });
    try {
      assert.equal(original.goldenRecheck.state, 'failed');
      assert.ok(original.goldenRecheck.finishedAt);
      assert.match(original.goldenRecheck.detail, /interrupted/);
      assert.equal(original.state, 'failed');
      assert.equal(original.restoreStatus, 'failed');
      assert.equal(original.error, 'Original program failure');
      assert.deepEqual(original.steps, [{ name: 'restore_golden', status: 'failed' }]);
      const headers = { Origin: origin, 'Content-Type': 'application/json', 'X-WQ-Action': 'recheck-golden' };
      assert.equal((await request(bound, '/api/recheck-golden', 'POST', headers, '{}')).status, 202);
      await bound.getActive();
      assert.equal(original.goldenRecheck.state, 'passed');
      assert.equal(original.restoreStatus, 'golden');
      assert.equal(original.state, 'failed');
    } finally { await bound.stop(); }
  } finally { await first.stop(); }
});

test('interrupted-job recovery starts only after a successful loopback bind', async () => {
  const first = await start();
  let recoveryCalls = 0;
  let saved = 0;
  const running = { id: 'interrupted', state: 'running', restoreStatus: 'pending', error: null, steps: [] };
  const duplicate = createDashboardServer({
    initialJob: running, save: () => { saved += 1; }, monitor,
    recover: async () => { recoveryCalls += 1; },
  });
  try {
    await new Promise((resolve) => {
      duplicate.server.once('error', (error) => {
        assert.equal(error.code, 'EADDRINUSE');
        resolve();
      });
      duplicate.server.listen(first.server.address().port, '127.0.0.1');
    });
    assert.equal(recoveryCalls, 0);
    assert.equal(saved, 0);
    assert.equal(running.error, null);
    const bound = await start({
      initialJob: running,
      recover: async (job, { onUpdate }) => {
        recoveryCalls += 1;
        job.state = 'failed';
        job.restoreStatus = 'golden';
        onUpdate();
      },
    });
    try {
      await bound.getActive();
      assert.equal(recoveryCalls, 1);
      assert.equal(bound.getJob().restoreStatus, 'golden');
    } finally { await bound.stop(); }
  } finally { await first.stop(); }
});
