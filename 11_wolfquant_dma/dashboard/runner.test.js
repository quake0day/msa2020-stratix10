import test from 'node:test';
import assert from 'node:assert/strict';
import { msysPath, runTest, validateTemperature, validateReport,
  recoverInterruptedTest, recheckGolden } from './runner.js';

function monitor(temperature = 40) {
  return {
    status: 'online', temperature, sampledAt: new Date().toISOString(),
    protection: {
      threshold: 80,
      power: { state: 'ready' },
      hostInterlock: { state: 'online' },
    },
  };
}

function job() {
  return {
    id: 'test-job', state: 'running', phase: 'queued', steps: [],
    startedAt: new Date().toISOString(), finishedAt: null,
    error: null, restoreStatus: 'pending', report: null,
  };
}

function report() {
  const sums = { sum_x: '0', sum_y: '0', sum_x2: '0', sum_y2: '0', sum_xy: '0' };
  return {
    report_version: 1, mode: 'fpga', tested_at: new Date().toISOString(),
    sample: { closes: Array(21).fill(100), returns: Array(20).fill(0), q20: Array(20).fill(0) },
    cpu: { sums: { ...sums }, vol20_original: 0, vol20_quantized: 0 },
    fpga: { sums: { ...sums }, vol20: 0, exec_us: 123.4,
      exact_match: true, reconstruction_match: true },
    error: { vol20_abs: 0, max_return_quantization: 0 },
  };
}

test('fixed Windows paths convert to Git Bash paths', () => {
  assert.equal(msysPath('H:\\msa2020-dma\\test.sh'), '/h/msa2020-dma/test.sh');
  assert.throws(() => msysPath('/tmp/user-input'), /fixed Windows/);
});

test('temperature preflight rejects invalid FPGA sensor readings', () => {
  validateTemperature(monitor(40));
  assert.throws(() => validateTemperature(monitor(-8388607.996)), /温度读数异常/);
  assert.throws(() => validateTemperature(monitor(0)), /温度读数异常/);
  assert.throws(() => validateTemperature(monitor(125)), /温度读数异常/);
  assert.throws(() => validateTemperature(monitor(76)), /测试上限/);
});

test('report rejects CPU fallback or mismatched FPGA sums', () => {
  assert.equal(validateReport(report()).mode, 'fpga');
  const fallback = report();
  fallback.mode = 'cpu-self-test';
  assert.throws(() => validateReport(fallback), /exact FPGA/);
  const mismatch = report();
  mismatch.fpga.sums.sum_x = '1';
  assert.throws(() => validateReport(mismatch), /exact FPGA/);
  const unsafeNumber = report();
  unsafeNumber.fpga.sums.sum_x2 = 2 ** 55;
  assert.throws(() => validateReport(unsafeNumber), /exact FPGA/);
});

test('preflight failure never programs or changes hardware', async () => {
  const current = job();
  const calls = [];
  await runTest(current, {
    fixedFiles: async () => {},
    temperature: async () => monitor(-8388607.996),
    power: async () => ({ on: true }),
    command: async (spec) => { calls.push(spec.label); return { stdout: '', stderr: '' }; },
  });
  assert.equal(current.state, 'failed');
  assert.equal(current.restoreStatus, 'not_needed');
  assert.deepEqual(calls, []);
});

test('hardware failure still unloads modules and verifies Golden restoration', async () => {
  const current = job();
  const calls = [];
  await runTest(current, {
    fixedFiles: async () => {},
    temperature: async () => monitor(),
    power: async () => ({ on: true }),
    command: async (spec) => {
      calls.push(spec.label);
      if (spec.label === 'DMA hardware verification') throw new Error('DMA byte mismatch');
      return { stdout: spec.label === 'Verify Golden health' ? 'GOLDEN\n' : 'PASS\n', stderr: '' };
    },
  });
  assert.equal(current.state, 'failed');
  assert.equal(current.restoreStatus, 'golden');
  assert.match(current.error, /DMA byte mismatch/);
  assert.deepEqual(calls.slice(-3), ['Unload FPGA drivers', 'Restore Golden image', 'Verify Golden health']);
  assert.equal(current.report, null);
});

test('successful sample requires real FPGA JSON and Golden verification', async () => {
  const current = job();
  const calls = [];
  await runTest(current, {
    fixedFiles: async () => {},
    temperature: async () => monitor(),
    power: async () => ({ on: true }),
    command: async (spec) => {
      calls.push(spec.label);
      if (spec.label === 'Read exact FPGA result')
        return { stdout: JSON.stringify(report()), stderr: '' };
      return { stdout: spec.label === 'Verify Golden health' ? 'GOLDEN\n' : 'PASS\n', stderr: '' };
    },
  });
  assert.equal(current.state, 'passed');
  assert.equal(current.restoreStatus, 'golden');
  assert.equal(current.report.fpga.exact_match, true);
  assert.equal(current.steps.every((step) => step.status === 'passed'), true);
  assert.deepEqual(calls.slice(-3), ['Unload FPGA drivers', 'Restore Golden image', 'Verify Golden health']);
});

test('recovery after a server interruption attempts cleanup and Golden', async () => {
  const current = job();
  const calls = [];
  await recoverInterruptedTest(current, {
    command: async (spec) => {
      calls.push(spec.label);
      return { stdout: spec.label === 'Verify Golden health' ? 'GOLDEN\n' : '', stderr: '' };
    },
  });
  assert.equal(current.state, 'failed');
  assert.equal(current.restoreStatus, 'golden');
  assert.deepEqual(calls, ['Unload FPGA drivers', 'Restore Golden image', 'Verify Golden health']);
});

test('read-only Golden recheck unlocks after exact GOLDEN while preserving failed test history', async () => {
  const current = { ...job(), state: 'failed', restoreStatus: 'failed', error: 'Program failed' };
  const oldSteps = [...current.steps];
  const specs = [];
  await recheckGolden(current, {
    command: async (spec) => { specs.push(spec); return { stdout: 'GOLDEN\n', stderr: '' }; },
  });
  assert.equal(current.state, 'failed');
  assert.equal(current.error, 'Program failed');
  assert.deepEqual(current.steps, oldSteps);
  assert.equal(current.restoreStatus, 'golden');
  assert.equal(current.goldenRecheck.state, 'passed');
  assert.equal(specs.length, 1);
  assert.equal(specs[0].label, 'Recheck Golden health');
  assert.deepEqual(specs[0].args.slice(-2), ['--challenge', 'bar-fuzzing']);
  assert.match(specs[0].args[2], /board_health\.sh$/);
});

test('Golden recheck rejects extra or non-GOLDEN output and leaves lockout intact', async () => {
  for (const stdout of ['DEGRADED\n', 'GOLDEN\nDEGRADED\n', ' GOLDEN\n']) {
    const current = { ...job(), state: 'failed', restoreStatus: 'failed', error: 'Original failure' };
    await recheckGolden(current, { command: async () => ({ stdout, stderr: '' }) });
    assert.equal(current.state, 'failed');
    assert.equal(current.error, 'Original failure');
    assert.equal(current.restoreStatus, 'failed');
    assert.equal(current.goldenRecheck.state, 'failed');
  }
  const notBlocked = { ...job(), state: 'passed', restoreStatus: 'golden' };
  await assert.rejects(recheckGolden(notBlocked, { command: async () => { throw new Error('must not run'); } }),
    /requires a failed test/);
});
