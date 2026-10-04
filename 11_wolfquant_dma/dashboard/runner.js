import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '..');
const ctf = path.resolve(here, '..', '..', '..', 'msa2020-ctf');
const hostDir = path.join(project, 'host');
const moduleDir = '/home/quake0day/corundum/modules';
const remoteScripts = '/home/quake0day/corundum/wq-dma';
const remoteProbe = `${moduleDir}/wqfpga_dma/dashboard_probe.py`;
const remoteHost = 'quake0day@192.168.1.253';
const sof = path.join(project, 'output_files', 'wolfquant_dma.sof');
const goldenSof = path.join(ctf, 'challenges', 'bar-fuzzing', 'golden', 'bar_fuzz.sof');
const probe = path.join(hostDir, 'wqfpga_dma', 'dashboard_probe.py');
const expectedSofSha256 = '6a72aa68ac3cbfd36887ceda60666e19e2013717b09009455490277effa62b55';
const bash = 'C:\\Program Files\\Git\\bin\\bash.exe';
const ssh = 'C:\\Windows\\System32\\OpenSSH\\ssh.exe';
const scp = 'C:\\Windows\\System32\\OpenSSH\\scp.exe';
const sshOptions = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
  '-o', 'NumberOfPasswordPrompts=0', '-o', 'StrictHostKeyChecking=yes'];
const maxOutputBytes = 64 * 1024;
const sumNames = ['sum_x', 'sum_y', 'sum_x2', 'sum_y2', 'sum_xy'];

export function msysPath(value) {
  const match = /^([A-Za-z]):[\\/](.*)$/.exec(value);
  if (!match) throw new Error('Expected a fixed Windows drive path');
  return `/${match[1].toLowerCase()}/${match[2].replaceAll('\\', '/')}`;
}

function excerpt(value, limit = 1800) {
  const trimmed = String(value ?? '').trim();
  return trimmed.length <= limit ? trimmed : `…${trimmed.slice(-limit)}`;
}

function killTree(child) {
  if (!child.pid) return;
  if (process.platform === 'win32') {
    const killer = spawn('C:\\Windows\\System32\\taskkill.exe',
      ['/PID', String(child.pid), '/T', '/F'],
      { windowsHide: true, stdio: 'ignore' });
    killer.on('error', () => child.kill('SIGKILL'));
    const fallback = setTimeout(() => child.kill('SIGKILL'), 2_000);
    fallback.unref();
    return;
  }
  child.kill('SIGKILL');
}

/** Run a fixed command without a shell; never accept browser-controlled arguments. */
export function execute(spec, signal) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(spec.file, spec.args, {
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'],
        env: spec.env ? { ...process.env, ...spec.env } : process.env,
      });
    } catch (error) {
      reject(error);
      return;
    }
    let stdout = '';
    let stderr = '';
    let bytes = 0;
    let timedOut = false;
    let oversized = false;
    let aborted = false;
    let stopping = false;
    let spawnError = null;
    const append = (kind, chunk) => {
      bytes += chunk.length;
      if (bytes > maxOutputBytes) {
        oversized = true;
        if (!stopping) { stopping = true; killTree(child); }
        return;
      }
      if (kind === 'stdout') stdout += chunk.toString('utf8');
      else stderr += chunk.toString('utf8');
    };
    child.stdout.on('data', (chunk) => append('stdout', chunk));
    child.stderr.on('data', (chunk) => append('stderr', chunk));
    child.on('error', (error) => { spawnError = error; });
    const timer = setTimeout(() => { timedOut = true; if (!stopping) { stopping = true; killTree(child); } }, spec.timeoutMs);
    const onAbort = () => { aborted = true; if (!stopping) { stopping = true; killTree(child); } };
    if (signal?.aborted) onAbort();
    else signal?.addEventListener('abort', onAbort, { once: true });
    child.stdin.on('error', () => {}); // a failed child can close stdin early
    child.stdin.end(spec.stdin ?? '');
    child.on('close', (code) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      if (spawnError || timedOut || oversized || aborted || code !== 0) {
        const reason = spawnError?.message ??
          (timedOut ? `Timed out after ${spec.timeoutMs} ms` :
            oversized ? 'Command output exceeded 64 KiB' :
              aborted ? 'Test interrupted' : `Exited with code ${code}`);
        const error = new Error(`${spec.label}: ${reason}${excerpt(stderr || stdout) ? `: ${excerpt(stderr || stdout, 1000)}` : ''}`);
        error.stdout = stdout;
        error.stderr = stderr;
        error.code = code;
        reject(error);
      } else {
        resolve({ stdout, stderr, code });
      }
    });
  });
}

function bashScript(scriptPath, label, timeoutMs) {
  return { label, file: bash, args: ['--noprofile', '--norc', msysPath(scriptPath)], timeoutMs };
}

function remote(command, label, timeoutMs, stdin) {
  return { label, file: ssh, args: [...sshOptions, remoteHost, command], timeoutMs, stdin };
}

function scpProbe() {
  return {
    label: 'Copy fixed probe', file: scp,
    args: [...sshOptions, '-B', probe, `${remoteHost}:${remoteProbe}`],
    timeoutMs: 30_000,
  };
}

const remotePreflight = `set -eu
sudo -n true
kernel=$(uname -r)
for file in ${moduleDir}/mqnic/mqnic.ko ${moduleDir}/mqnic_app_dma_smoketest/mqnic_app_dma_smoketest.ko ${moduleDir}/wqfpga_dma/wqfpga_dma.ko; do
  test -f "$file"
  case "$(modinfo -F vermagic "$file")" in "$kernel "*) ;; *) echo "Kernel/module mismatch: $file" >&2; exit 1 ;; esac
done
for file in ${remoteScripts}/reenumerate_dma.sh ${remoteScripts}/verify_on_board.sh ${remoteScripts}/verify_moments.sh ${moduleDir}/wqfpga_dma/wqfpga-moments-test ${moduleDir}/wqfpga_dma/moments_vol20_demo.py; do test -f "$file"; done
for module in mqnic wqfpga_dma mqnic_app_dma_smoketest; do
  if grep -q "^$module " /proc/modules; then echo "FPGA driver already in use: $module" >&2; exit 1; fi
done
printf 'Linux %s; sudo and matching FPGA modules ready\\n' "$kernel"
`;

const remoteCleanup = `failed=0
for module in wqfpga_dma mqnic_app_dma_smoketest mqnic; do
  if grep -q "^$module " /proc/modules; then
    sudo -n rmmod "$module" || failed=1
  fi
done
for module in wqfpga_dma mqnic_app_dma_smoketest mqnic; do
  if grep -q "^$module " /proc/modules; then echo "Still loaded: $module" >&2; failed=1; fi
done
exit "$failed"
`;

export async function fetchTemperature() {
  const response = await fetch('http://127.0.0.1:4173/api/temperature',
    { signal: AbortSignal.timeout(3_000), cache: 'no-store' });
  if (!response.ok) throw new Error(`Temperature monitor HTTP ${response.status}`);
  return response.json();
}

export async function fetchPowerStatus() {
  const response = await fetch('http://127.0.0.1:4173/api/power',
    { signal: AbortSignal.timeout(3_000), cache: 'no-store' });
  if (!response.ok) throw new Error(`FPGA power status HTTP ${response.status}`);
  const status = await response.json();
  if (status?.ok !== true || status.on !== true)
    throw new Error('FPGA 独立电源未开启');
  return status;
}

export function validateTemperature(monitor) {
  if (monitor?.status !== 'online' || !Number.isFinite(monitor.temperature))
    throw new Error('温度监控未在线');
  if (monitor.temperature <= 0 || monitor.temperature >= 125)
    throw new Error(`FPGA 温度读数异常：${monitor.temperature}°C`);
  const sampled = Date.parse(monitor.sampledAt);
  if (!Number.isFinite(sampled) || Math.abs(Date.now() - sampled) > 45_000)
    throw new Error('FPGA 温度读数已过期');
  const threshold = Number(monitor.protection?.threshold);
  const ceiling = Number.isFinite(threshold) ? Math.min(75, threshold - 5) : 75;
  if (monitor.temperature >= ceiling)
    throw new Error(`FPGA 温度 ${monitor.temperature}°C 超过测试上限 ${ceiling}°C`);
  if (!['ready', 'on'].includes(monitor.protection?.power?.state))
    throw new Error('FPGA 独立电源尚未就绪');
  if (monitor.protection?.hostInterlock?.state !== 'online')
    throw new Error('Linux 主机未在线');
  return monitor;
}

async function checkFixedFiles() {
  for (const file of [sof, goldenSof, probe,
    path.join(hostDir, 'program_dma.sh'),
    path.join(ctf, 'infra', 'golden_reset.sh'),
    path.join(ctf, 'infra', 'board_health.sh')]) {
    await access(file);
  }
  const actual = createHash('sha256').update(await readFile(sof)).digest('hex');
  if (actual !== expectedSofSha256)
    throw new Error('Moments FPGA image differs from the validated SOF');
}

export function validateReport(report) {
  const validSums = (sums) => sums && typeof sums === 'object' &&
    !Array.isArray(sums) && sumNames.every((name) =>
      typeof sums[name] === 'string' && /^-?\d+$/.test(sums[name]));
  if (!report || typeof report !== 'object' || report.report_version !== 1 ||
      report.mode !== 'fpga' ||
      !Array.isArray(report.sample?.closes) || report.sample.closes.length !== 21 ||
      !Array.isArray(report.sample?.returns) || report.sample.returns.length !== 20 ||
      !Array.isArray(report.sample?.q20) || report.sample.q20.length !== 20 ||
      !validSums(report.cpu?.sums) || !validSums(report.fpga?.sums) ||
      report.fpga.exact_match !== true ||
      report.fpga.reconstruction_match !== true ||
      sumNames.some((name) => report.fpga.sums[name] !== report.cpu.sums[name]) ||
      !Number.isFinite(report.fpga.exec_us) || report.fpga.exec_us < 0 ||
      !Number.isFinite(report.fpga.vol20) ||
      !Number.isFinite(report.cpu.vol20_original) ||
      !Number.isFinite(report.cpu.vol20_quantized) ||
      !Number.isFinite(report.error?.vol20_abs) ||
      !Number.isFinite(report.error?.max_return_quantization) ||
      !Number.isFinite(Date.parse(report.tested_at))) {
    throw new Error('Probe did not return a complete, exact FPGA result');
  }
  return report;
}

/** The caller owns job storage. On any hardware-phase failure, cleanup and Golden restoration still run. */
export async function runTest(job, dependencies = {}) {
  const command = dependencies.command ?? execute;
  const temperature = dependencies.temperature ?? fetchTemperature;
  const powerStatus = dependencies.power ?? fetchPowerStatus;
  const fixedFiles = dependencies.fixedFiles ?? checkFixedFiles;
  const update = () => dependencies.onUpdate?.(job);
  const signal = dependencies.signal;
  let enteredHardware = false;
  let primaryError = null;

  async function step(name, action, cleanup = false) {
    job.phase = name;
    const record = { name, status: 'running', detail: '' };
    job.steps.push(record);
    update();
    try {
      const detail = await action();
      record.status = 'passed';
      record.detail = excerpt(detail, 2000);
      update();
      return detail;
    } catch (error) {
      record.status = 'failed';
      record.detail = excerpt(error.message, 2000);
      update();
      if (!cleanup) throw error;
      return null;
    }
  }

  try {
    await step('preflight', async () => {
      await fixedFiles();
      const monitor = validateTemperature(await temperature());
      await powerStatus();
      job.monitor = { temperature: monitor.temperature, sampledAt: monitor.sampledAt,
        power: monitor.protection.power.state };
      const result = await command(remote('bash -s', 'Remote preflight', 25_000, remotePreflight), signal);
      return `${result.stdout.trim()}; FPGA ${monitor.temperature.toFixed(1)}°C; independent power ${monitor.protection.power.state}`;
    });

    enteredHardware = true;
    await step('program', async () => {
      const result = await command(bashScript(path.join(hostDir, 'program_dma.sh'), 'Program moments FPGA image', 390_000), signal);
      return excerpt(`${result.stdout}\n${result.stderr}`);
    });
    await step('dma', async () => {
      const result = await command(remote(`bash ${remoteScripts}/verify_on_board.sh`, 'DMA hardware verification', 120_000), signal);
      return excerpt(`${result.stdout}\n${result.stderr}`);
    });
    await step('moments', async () => {
      const result = await command(remote(`bash ${remoteScripts}/verify_moments.sh`, 'Moments hardware verification', 180_000), signal);
      return excerpt(`${result.stdout}\n${result.stderr}`);
    });
    await step('copy_probe', async () => {
      await command(scpProbe(), signal);
      return 'Fixed dashboard probe copied to Linux host';
    });
    await step('load_probe_driver', async () => {
      const result = await command(remote(`sudo -n insmod ${moduleDir}/wqfpga_dma/wqfpga_dma.ko`, 'Load FPGA probe driver', 30_000), signal);
      return excerpt(result.stdout || result.stderr || 'wqfpga_dma loaded');
    });
    await step('probe', async () => {
      const result = await command(remote(`sudo -n python3 ${remoteProbe} --device /dev/wqfpga0`, 'Read exact FPGA result', 45_000), signal);
      const report = validateReport(JSON.parse(result.stdout.trim()));
      job.report = report;
      update();
      return `Five FPGA sums match CPU exactly; EXEC ${report.fpga.exec_us.toFixed(1)} µs`;
    });
  } catch (error) {
    primaryError = error;
    job.error = excerpt(error.message, 2000);
    update();
  } finally {
    if (enteredHardware) {
      const cleanupBefore = job.steps.length;
      await step('unload_drivers', async () => {
        const result = await command(remote('bash -s', 'Unload FPGA drivers', 45_000, remoteCleanup));
        return excerpt(result.stdout || result.stderr || 'FPGA drivers unloaded');
      }, true);
      if (job.steps[cleanupBefore].status === 'failed') {
        primaryError ??= new Error('FPGA drivers did not unload cleanly');
        job.error ??= 'FPGA drivers did not unload cleanly';
      }
      const restoreIndex = job.steps.length;
      await step('restore_golden', async () => {
        const spec = bashScript(path.join(ctf, 'infra', 'golden_reset.sh'),
          'Restore Golden image', 420_000);
        spec.args.push('--challenge', 'bar-fuzzing');
        const result = await command(spec);
        return excerpt(`${result.stdout}\n${result.stderr}`);
      }, true);
      const resetPassed = job.steps[restoreIndex].status === 'passed';
      const healthIndex = job.steps.length;
      await step('verify_golden', async () => {
        const spec = bashScript(path.join(ctf, 'infra', 'board_health.sh'), 'Verify Golden health', 45_000);
        spec.args.push('--challenge', 'bar-fuzzing');
        const result = await command(spec);
        if (result.stdout.trim() !== 'GOLDEN')
          throw new Error(`Expected GOLDEN, got ${excerpt(result.stdout)}`);
        return 'GOLDEN: 1234:1002 and BAR0 magic 0x42415246 verified';
      }, true);
      const healthPassed = job.steps[healthIndex].status === 'passed';
      job.restoreStatus = resetPassed && healthPassed ? 'golden' : 'failed';
      if (job.restoreStatus !== 'golden') {
        primaryError ??= new Error('Golden restoration was not verified');
        job.error = job.error ? `${job.error}; Golden restoration was not verified` : 'Golden restoration was not verified';
      }
    } else {
      job.restoreStatus = 'not_needed';
    }
    job.state = primaryError ? 'failed' : 'passed';
    job.phase = 'complete';
    job.finishedAt = new Date().toISOString();
    update();
  }
  return job;
}

/** A server restart during a test must attempt hardware recovery before allowing a new job. */
export async function recoverInterruptedTest(job, dependencies = {}) {
  const command = dependencies.command ?? execute;
  const update = () => dependencies.onUpdate?.(job);
  job.state = 'running';
  job.phase = 'startup_recovery';
  job.error = job.error ?? 'Previous test was interrupted';
  let cleanupPassed = false;
  let resetPassed = false;
  let healthPassed = false;

  async function attempt(name, spec, verify) {
    const record = { name, status: 'running', detail: '' };
    job.phase = name;
    job.steps.push(record);
    update();
    try {
      const result = await command(spec);
      verify?.(result);
      record.status = 'passed';
      record.detail = excerpt(`${result.stdout}\n${result.stderr}`) || 'Completed';
      update();
      return true;
    } catch (error) {
      record.status = 'failed';
      record.detail = excerpt(error.message);
      update();
      return false;
    }
  }

  cleanupPassed = await attempt('unload_drivers', remote('bash -s', 'Unload FPGA drivers', 45_000, remoteCleanup));
  const reset = bashScript(path.join(ctf, 'infra', 'golden_reset.sh'), 'Restore Golden image', 420_000);
  reset.args.push('--challenge', 'bar-fuzzing');
  resetPassed = await attempt('restore_golden', reset);
  const health = bashScript(path.join(ctf, 'infra', 'board_health.sh'), 'Verify Golden health', 45_000);
  health.args.push('--challenge', 'bar-fuzzing');
  healthPassed = await attempt('verify_golden', health, (result) => {
    if (result.stdout.trim() !== 'GOLDEN') throw new Error(`Expected GOLDEN, got ${excerpt(result.stdout)}`);
  });
  job.restoreStatus = resetPassed && healthPassed ? 'golden' : 'failed';
  if (!cleanupPassed) job.error += '; FPGA drivers did not unload cleanly';
  if (job.restoreStatus !== 'golden') job.error += '; Golden restoration was not verified';
  job.state = 'failed';
  job.phase = 'complete';
  job.finishedAt = new Date().toISOString();
  update();
  return job;
}
