import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runTest, fetchTemperature, recoverInterruptedTest, recheckGolden, validateTemperature } from './runner.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(here, 'public');
const runtimeDir = path.join(here, 'runtime');
const stateFile = path.join(runtimeDir, 'status.json');
const sampleReference = JSON.parse(readFileSync(path.join(here, 'sample-reference.json'), 'utf8'));
if (sampleReference.mode !== 'cpu-self-test' || sampleReference.fpga !== null)
  throw new Error('Dashboard sample must be a CPU-only reference');
const listenHost = '127.0.0.1';
const listenPort = 4174;
const allowedHosts = new Set(['127.0.0.1:4174', 'localhost:4174']);
const staticTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
};

function headers(extra = {}) {
  return {
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    ...extra,
  };
}

function sendJson(response, status, value) {
  const data = Buffer.from(JSON.stringify(value));
  response.writeHead(status, headers({ 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length }));
  response.end(data);
}

function parseSavedJob() {
  try {
    const value = JSON.parse(readFileSync(stateFile, 'utf8'));
    return value && typeof value === 'object' && typeof value.id === 'string' ? value : null;
  } catch { return null; }
}

function persist(job) {
  mkdirSync(runtimeDir, { recursive: true });
  const temp = path.join(runtimeDir, `status-${process.pid}.tmp`);
  writeFileSync(temp, JSON.stringify(job, null, 2), { encoding: 'utf8', mode: 0o600 });
  renameSync(temp, stateFile);
}

async function readEmptyJson(request) {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 256) throw new Error('Request body too large');
    chunks.push(chunk);
  }
  const value = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
  if (!value || Array.isArray(value) || typeof value !== 'object' || Object.keys(value).length !== 0)
    throw new Error('This action accepts no input');
}

function newJob() {
  return {
    id: randomUUID(),
    state: 'running',
    phase: 'queued',
    steps: [],
    startedAt: new Date().toISOString(),
    finishedAt: null,
    error: null,
    restoreStatus: 'pending',
    report: null,
    monitor: null,
  };
}

/** Exported for API tests; production still listens only on 127.0.0.1:4174. */
export function createDashboardServer(options = {}) {
  const run = options.run ?? runTest;
  const recover = options.recover ?? recoverInterruptedTest;
  const recheck = options.recheck ?? recheckGolden;
  const monitorReader = options.monitor ?? fetchTemperature;
  const save = options.save ?? persist;
  let job = options.initialJob === undefined ? parseSavedJob() : options.initialJob;
  let active = null;
  let controller = null;
  let monitorCache = null;
  let monitorTime = 0;
  let monitorPending = null;

  function setJob(value) {
    job = value;
    save(job);
  }

  async function monitorStatus() {
    if (monitorCache && Date.now() - monitorTime < 10_000) return monitorCache;
    if (!monitorPending) {
      monitorPending = monitorReader().then((value) => {
        let ready = true;
        let message = '温度、供电和主机状态已就绪';
        try { validateTemperature(value); }
        catch (error) { ready = false; message = error.message; }
        return {
          status: value.status,
          temperature: value.temperature,
          sampledAt: value.sampledAt,
          power: value.protection?.power?.state ?? 'unknown',
          hostInterlock: value.protection?.hostInterlock?.state ?? 'unknown',
          ready,
          message,
        };
      }).catch((error) => ({ status: 'unavailable', ready: false, message: error.message }))
        .then((value) => {
          monitorCache = value;
          monitorTime = Date.now();
          monitorPending = null;
          return value;
        });
    }
    return monitorPending;
  }

  const server = http.createServer(async (request, response) => {
    const host = request.headers.host?.toLowerCase();
    const origin = request.headers.origin;
    const fetchSite = request.headers['sec-fetch-site'];
    if (!allowedHosts.has(host) ||
        (origin && origin !== `http://${host}`) ||
        (fetchSite && !['same-origin', 'none'].includes(fetchSite))) {
      sendJson(response, 403, { error: 'Local same-origin access only' });
      return;
    }
    let url;
    try { url = new URL(request.url, `http://${host}`); }
    catch { sendJson(response, 400, { error: 'Invalid URL' }); return; }

    if (url.pathname === '/api/status' && request.method === 'GET') {
      sendJson(response, 200, { test: job, monitor: await monitorStatus(), sample: sampleReference });
      return;
    }
    if (url.pathname === '/api/recheck-golden' && request.method === 'POST') {
      if (origin !== `http://${host}` || request.headers['x-wq-action'] !== 'recheck-golden' ||
          request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
        sendJson(response, 403, { error: 'Same-origin JSON action header required' });
        return;
      }
      try { await readEmptyJson(request); }
      catch (error) { sendJson(response, 400, { error: error.message }); return; }
      if (active) { sendJson(response, 409, { error: 'A hardware test or recovery is already running', test: job }); return; }
      if (job?.state !== 'failed' || job.restoreStatus !== 'failed') {
        sendJson(response, 409, { error: 'No failed Golden state needs rechecking', test: job });
        return;
      }
      const previous = job;
      active = Promise.resolve().then(() => recheck(previous, { onUpdate: () => save(previous) }))
        .catch((error) => {
          previous.goldenRecheck = {
            state: 'failed', finishedAt: new Date().toISOString(),
            detail: `Golden recheck failed: ${error.message}`,
          };
          save(previous);
        }).finally(() => { active = null; });
      sendJson(response, 202, { test: previous });
      return;
    }
    if (url.pathname === '/api/test' && request.method === 'POST') {
      if (origin !== `http://${host}` || request.headers['x-wq-action'] !== 'run' ||
          request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
        sendJson(response, 403, { error: 'Same-origin JSON action header required' });
        return;
      }
      try { await readEmptyJson(request); }
      catch (error) { sendJson(response, 400, { error: error.message }); return; }
      if (active) { sendJson(response, 409, { error: 'A hardware test or recovery is already running', test: job }); return; }
      if (job?.restoreStatus === 'failed') {
        sendJson(response, 409, { error: 'Golden restoration failed; recover the board before another test', test: job });
        return;
      }
      const next = newJob();
      setJob(next);
      controller = new AbortController();
      active = Promise.resolve().then(() => run(next, {
        signal: controller.signal,
        onUpdate: () => save(next),
      })).catch((error) => {
        next.state = 'failed';
        next.phase = 'complete';
        next.finishedAt = new Date().toISOString();
        next.error = `Unexpected runner failure: ${error.message}`;
        next.restoreStatus = 'failed';
        save(next);
      }).finally(() => { active = null; controller = null; });
      sendJson(response, 202, { test: next });
      return;
    }
    if (url.pathname.startsWith('/api/')) {
      sendJson(response, 404, { error: 'Unknown API endpoint' });
      return;
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      sendJson(response, 405, { error: 'Method not allowed' });
      return;
    }
    let pathname;
    try { pathname = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname); }
    catch { sendJson(response, 400, { error: 'Invalid path' }); return; }
    const candidate = path.resolve(publicDir, `.${pathname}`);
    const relative = path.relative(publicDir, candidate);
    if (!relative || relative.startsWith('..') || path.isAbsolute(relative) || !existsSync(candidate)) {
      sendJson(response, 404, { error: 'Not found' });
      return;
    }
    try {
      const data = await readFile(candidate);
      response.writeHead(200, headers({ 'Content-Type': staticTypes[path.extname(candidate)] ?? 'application/octet-stream',
        'Content-Length': data.length }));
      response.end(request.method === 'HEAD' ? undefined : data);
    } catch { sendJson(response, 404, { error: 'Not found' }); }
  });

  // A duplicate process must not touch the board before its loopback bind succeeds.
  server.on('listening', () => {
    if (job?.state === 'failed' && job.restoreStatus === 'failed' &&
        job.goldenRecheck?.state === 'running') {
      job.goldenRecheck.state = 'failed';
      job.goldenRecheck.finishedAt = new Date().toISOString();
      job.goldenRecheck.detail = 'The previous read-only Golden recheck was interrupted; it can be retried';
      save(job);
    }
    if (job?.state !== 'running') return;
    job.error = 'The previous test was interrupted; restoring Golden before another test';
    job.phase = 'startup_recovery';
    active = Promise.resolve().then(() => recover(job, { onUpdate: () => save(job) }))
      .catch((error) => {
        job.state = 'failed';
        job.restoreStatus = 'failed';
        job.error = `${job.error}; recovery failed: ${error.message}`;
        job.finishedAt = new Date().toISOString();
        save(job);
      }).finally(() => { active = null; });
  });

  return {
    server,
    getJob: () => job,
    getActive: () => active,
    async stop() {
      controller?.abort();
      if (active) await active;
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dashboard = createDashboardServer();
  dashboard.server.listen(listenPort, listenHost, () => {
    process.stdout.write(`WolfQuant FPGA dashboard: http://${listenHost}:${listenPort}/\n`);
  });
  let stopping = false;
  async function stop() {
    if (stopping) return;
    stopping = true;
    await dashboard.stop();
    process.exit(0);
  }
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
