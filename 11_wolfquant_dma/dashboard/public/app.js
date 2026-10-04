"use strict";

const fields = Object.fromEntries(
  [
    "runButton", "runButtonLabel", "runHint", "notice", "temperatureValue",
    "temperatureDetail", "powerValue", "powerDetail", "serviceValue",
    "serviceDetail", "runState", "phaseText", "stepsList", "runStarted",
    "runFinished", "restoreStatus", "resultTimestamp", "resultsEmpty",
    "resultsBody", "fpgaVol", "fpgaMatch", "cpuVol", "volError",
    "execTime", "sumsRows", "quantizedVol", "closesChart", "returnError",
    "inputRows"
  ].map((id) => [id, document.getElementById(id)])
);

const SUMS = [
  ["sum_x", "Σx", "Q20"],
  ["sum_y", "Σy", "Q20"],
  ["sum_x2", "Σx²", "Q40"],
  ["sum_y2", "Σy²", "Q40"],
  ["sum_xy", "Σxy", "Q40"]
];

const STEP_LABELS = {
  preflight: "环境与温度检查",
  program: "加载 FPGA 测试程序",
  dma: "验证双向 DMA",
  moments: "验证统计计算",
  copy_probe: "准备结果采集",
  load_probe_driver: "连接 FPGA 计算接口",
  probe: "读取 FPGA 原始结果",
  unload_drivers: "卸载测试驱动",
  restore_golden: "恢复 Golden 程序",
  verify_golden: "核对 Golden 状态",
  startup_recovery: "恢复上次中断的测试",
  complete: "全部步骤结束"
};

const STEP_DETAILS = {
  preflight: "核对供电、温度与主机状态",
  program: "加载测试程序并重新发现 PCIe 设备",
  dma: "检查双向数据传输",
  moments: "检查多组精确计算",
  copy_probe: "准备固定样本的结果采集",
  load_probe_driver: "打开受限的计算接口",
  probe: "读取并核对五项 FPGA 原始结果",
  unload_drivers: "卸载硬件测试驱动",
  restore_golden: "恢复已知正常的 FPGA 程序",
  verify_golden: "复核 Golden 设备状态"
};

const terminalStates = new Set(["passed", "pass", "complete", "completed", "success", "succeeded", "failed", "error", "cancelled", "canceled"]);
const successStates = new Set(["passed", "pass", "complete", "completed", "success", "succeeded"]);
const failureStates = new Set(["failed", "error", "cancelled", "canceled"]);

const view = {
  connected: false,
  monitorReady: false,
  monitorMessage: "",
  submitting: false,
  test: null,
  localRunId: null,
  pendingUntil: 0,
  polling: false,
  networkNotice: false,
  reportFingerprint: null,
  sampleReference: null
};

function setText(element, value) {
  element.textContent = value == null || value === "" ? "—" : String(value);
}

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function stateOf(value) {
  return String(value ?? "").trim().toLowerCase();
}

function isActive(test) {
  return Boolean(test && test.id && !terminalStates.has(stateOf(test.state)));
}

function restoreFailed(test) {
  return Boolean(test && stateOf(test.restoreStatus) === "failed");
}

function formatTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString("zh-CN", { hour12: false });
}

function formatDecimal(value, places = 12) {
  if (value == null || value === "") return "—";
  const number = Number(value);
  return Number.isFinite(number) ? number.toFixed(places) : "—";
}

function formatSmall(value) {
  if (value == null || value === "") return "—";
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  return number !== 0 && Math.abs(number) < 0.00001
    ? number.toExponential(6)
    : number.toFixed(12).replace(/0+$/, "").replace(/\.$/, "");
}

function showNotice(message, error = false, network = false) {
  const notice = fields.notice;
  notice.hidden = !message;
  notice.classList.toggle("error", error);
  notice.textContent = message || "";
  view.networkNotice = Boolean(message && network);
}

function renderButton() {
  const active = isActive(view.test);
  const blocked = restoreFailed(view.test);
  fields.runButton.disabled = !view.connected || !view.monitorReady || view.submitting || active || blocked;
  fields.runButton.setAttribute("aria-busy", String(view.submitting || active));
  if (!view.connected) {
    setText(fields.runButtonLabel, "测试服务连接中");
    setText(fields.runHint, "连接恢复后即可运行测试。");
  } else if (view.submitting) {
    setText(fields.runButtonLabel, "正在创建测试任务…");
    setText(fields.runHint, "请勿重复提交。");
  } else if (active) {
    setText(fields.runButtonLabel, "测试正在运行…");
    setText(fields.runHint, "进度和结果会自动更新。");
  } else if (blocked) {
    setText(fields.runButtonLabel, "Golden 状态待检查");
    setText(fields.runHint, "恢复未获验证，请先检查板卡状态。");
  } else if (!view.monitorReady) {
    setText(fields.runButtonLabel, "安全检查未就绪");
    setText(fields.runHint, view.monitorMessage || "请确认温度监控与 FPGA 供电状态。");
  } else {
    setText(fields.runButtonLabel, "一键运行完整测试");
    setText(fields.runHint, "测试前请保持 FPGA 电源与 Linux 主机在线。");
  }
}

function renderTelemetry(status) {
  const temp = status.monitor;
  const tempObj = asObject(temp);
  const tempValue = typeof temp === "number" ? temp : tempObj.temperature;
  const temperature = tempValue == null ? NaN : Number(tempValue);
  const plausibleTemperature = Number.isFinite(temperature) && temperature > 0 && temperature < 125;
  setText(fields.temperatureValue, plausibleTemperature ? temperature.toFixed(1) : "--.-");
  const sampled = tempObj.sampledAt || tempObj.sampled_at;
  const temperatureDetail = tempObj.status === "unavailable"
    ? (tempObj.message || "温度监控暂不可用")
    : (!plausibleTemperature ? "传感器读数异常，当前测试已暂停" :
      (sampled ? `采样于 ${formatTime(sampled)}` : "等待温度数据…"));
  setText(fields.temperatureDetail, temperatureDetail);

  const power = tempObj.power;
  const powerObj = asObject(power);
  const powerState = stateOf(powerObj.state || powerObj.status || power);
  const powerLabels = {
    on: "已开启", ready: "已开启", online: "已开启", powered: "已开启",
    off: "已关闭", disabled: "已关闭", offline: "已关闭",
    error: "状态异常", failed: "状态异常", unknown: "状态未知"
  };
  setText(fields.powerValue, powerLabels[powerState] || powerObj.label || "状态未知");
  const powerDetails = {
    on: "FPGA 独立电源已开启", ready: "FPGA 独立电源已报告可用",
    off: "FPGA 独立电源已关闭", unknown: "等待插座状态…"
  };
  setText(fields.powerDetail, powerObj.message || powerDetails[powerState] || "请查看温度监控页面");

  const active = isActive(view.test);
  setText(fields.serviceValue, active ? "测试运行中" : view.monitorReady ? "已连接" : "暂不可运行");
  setText(fields.serviceDetail, active ? (STEP_LABELS[view.test.phase] || "正在运行硬件测试") : view.monitorReady ? "本机测试服务在线" : (view.monitorMessage || "等待安全检查"));
}

function statePresentation(test) {
  if (!test) return ["idle", "等待运行"];
  const state = stateOf(test.state);
  if (failureStates.has(state)) return ["failed", "测试失败"];
  if (successStates.has(state)) return ["passed", "测试完成"];
  return ["running", "运行中"];
}

function stepClass(status) {
  const state = stateOf(status);
  if (["done", "passed", "pass", "complete", "completed", "success", "succeeded", "ok"].includes(state)) return "done";
  if (["failed", "error"].includes(state)) return "failed";
  if (["running", "active", "in_progress"].includes(state)) return "running";
  if (["skipped", "skip"].includes(state)) return "skipped";
  return "pending";
}

function renderSteps(steps) {
  const list = fields.stepsList;
  const entries = Array.isArray(steps) && steps.length ? steps : [{ name: "等待测试", status: "pending", detail: "测试步骤将在运行时更新" }];
  const items = entries.map((step, index) => {
    const data = asObject(step);
    const status = stepClass(data.status);
    const item = document.createElement("li");
    item.className = `step ${status}`;
    const symbol = document.createElement("span");
    symbol.className = "step-icon";
    symbol.setAttribute("aria-hidden", "true");
    symbol.textContent = status === "done" ? "✓" : status === "failed" ? "!" : String(index + 1);
    const copy = document.createElement("div");
    const name = document.createElement("strong");
    name.textContent = STEP_LABELS[data.name] || String(data.name || `步骤 ${index + 1}`);
    const detail = document.createElement("small");
    const fullDetail = String(data.detail || "");
    const displayDetail = status === "failed"
      ? fullDetail || "执行失败"
      : `${STEP_DETAILS[data.name] || "测试步骤"} · ${{ done: "已完成", running: "正在执行", pending: "等待执行", skipped: "已跳过" }[status]}`;
    detail.textContent = displayDetail.replace(/\s+/g, " ").slice(0, 125) + (displayDetail.length > 125 ? "…" : "");
    if (fullDetail) detail.title = fullDetail;
    copy.append(name, detail);
    item.append(symbol, copy);
    return item;
  });
  list.replaceChildren(...items);
}

function restorationText(value) {
  if (value == null || value === "") return "Golden 恢复状态 —";
  const data = asObject(value);
  const status = stateOf(data.state || data.status || value);
  const labels = {
    restored: "已恢复 Golden", golden: "已恢复 Golden", passed: "已恢复 Golden",
    success: "已恢复 Golden", verified: "Golden 已验证",
    running: "正在恢复 Golden", restoring: "正在恢复 Golden",
    pending: "等待恢复 Golden", failed: "Golden 恢复失败",
    error: "Golden 恢复失败", skipped: "未执行 Golden 恢复",
    not_needed: "未触及硬件，无需恢复"
  };
  return `Golden 恢复状态 ${data.message || labels[status] || String(data.state || data.status || value)}`;
}

function renderTest(test, sampleReference) {
  view.test = test;
  const [style, label] = statePresentation(test);
  fields.runState.className = `state-pill ${style}`;
  setText(fields.runState.querySelector("span"), label);
  const failed = test && failureStates.has(stateOf(test.state));
  const phase = test && (failed ? "测试失败，请查看错误信息与 Golden 恢复状态" : (STEP_LABELS[test.phase] || label));
  setText(fields.phaseText, test ? phase : "点击“一键运行完整测试”后，进度会显示在这里。");
  renderSteps(test && test.steps);
  setText(fields.runStarted, `开始时间 ${formatTime(test && test.startedAt)}`);
  setText(fields.runFinished, `完成时间 ${formatTime(test && test.finishedAt)}`);
  setText(fields.restoreStatus, restorationText(test && test.restoreStatus));
  if (test && test.error && failed) {
    const error = typeof test.error === "string" ? test.error : (test.error.message || "请查看测试步骤");
    showNotice(`测试失败：${error}`, true);
  } else if (test && view.localRunId && String(test.id) === view.localRunId && successStates.has(stateOf(test.state))) {
    showNotice("本次 FPGA 测试已通过，Golden 已恢复并核对。", false);
  }
  renderReport(test?.report || sampleReference);
  renderButton();
}

function rawInteger(value) {
  if (typeof value === "bigint") return String(value);
  if (typeof value === "number") return Number.isSafeInteger(value) ? String(value) : null;
  if (typeof value === "string" && /^-?\d+$/.test(value.trim())) return value.trim();
  return null;
}

function sumValue(sums, name, index) {
  if (Array.isArray(sums)) return rawInteger(sums[index]);
  const data = asObject(sums);
  return rawInteger(data[name]);
}

function sameInteger(left, right) {
  if (left === null || right === null) return false;
  try { return BigInt(left) === BigInt(right); }
  catch { return false; }
}

function cell(row, value, className = "") {
  const item = document.createElement("td");
  item.textContent = value;
  if (className) item.className = className;
  row.append(item);
  return item;
}

function renderSums(cpuSums, fpgaSums, hasFpga) {
  let matching = true;
  const rows = SUMS.map(([key, label, unit], index) => {
    const cpu = sumValue(cpuSums, key, index);
    const fpga = sumValue(fpgaSums, key, index);
    const equal = hasFpga && sameInteger(cpu, fpga);
    matching = matching && equal;
    const row = document.createElement("tr");
    cell(row, `${label} · ${unit}`);
    cell(row, cpu ?? "数据缺失", "raw-number");
    cell(row, hasFpga ? (fpga ?? "数据缺失") : "等待实机", "raw-number");
    cell(row, hasFpga ? (equal ? "一致" : "不一致") : "待验证",
      hasFpga ? (equal ? "check-pass" : "check-fail") : "");
    return row;
  });
  fields.sumsRows.replaceChildren(...rows);
  return matching;
}

function formatQ20(value) {
  if (value == null) return "—";
  if (Array.isArray(value)) return `${value[0] ?? "—"} / ${value[1] ?? 0}`;
  if (typeof value === "object") return `${value.x ?? value[0] ?? "—"} / ${value.y ?? value[1] ?? 0}`;
  return `${value} / 0`;
}

function renderInputs(sample) {
  const closes = Array.isArray(sample.closes) ? sample.closes : [];
  const returns = Array.isArray(sample.returns) ? sample.returns : [];
  const q20 = Array.isArray(sample.q20) ? sample.q20 : [];
  const rows = closes.map((close, index) => {
    const row = document.createElement("tr");
    cell(row, String(index + 1).padStart(2, "0"));
    cell(row, String(close));
    cell(row, index === 0 ? "—" : formatDecimal(returns[index - 1], 10));
    cell(row, index === 0 ? "—" : formatQ20(q20[index - 1]));
    return row;
  });
  fields.inputRows.replaceChildren(...rows);
  drawCloses(closes);
}

function svgElement(name, attributes = {}) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, String(value));
  return element;
}

function drawCloses(closes) {
  const chart = fields.closesChart;
  const numbers = closes.map(Number);
  if (numbers.length < 2 || numbers.some((number) => !Number.isFinite(number))) {
    chart.replaceChildren();
    chart.setAttribute("aria-label", "没有可绘制的收盘价数据");
    return;
  }
  const minimum = Math.min(...numbers);
  const maximum = Math.max(...numbers);
  const span = maximum - minimum || 1;
  const points = numbers.map((value, index) => {
    const x = 12 + index * 776 / (numbers.length - 1);
    const y = 213 - (value - minimum) / span * 181;
    return [x, y];
  });
  const children = [];
  for (const y of [31, 91, 151, 211]) {
    children.push(svgElement("line", { x1: 0, y1: y, x2: 800, y2: y, stroke: "#274057", "stroke-width": 1, "stroke-dasharray": "3 7" }));
  }
  children.push(svgElement("polygon", {
    points: `12,231 ${points.map(([x, y]) => `${x},${y}`).join(" ")} 788,231`,
    fill: "rgba(56,232,198,.11)"
  }));
  children.push(svgElement("polyline", {
    points: points.map(([x, y]) => `${x},${y}`).join(" "),
    fill: "none", stroke: "#38e8c6", "stroke-width": 3,
    "stroke-linejoin": "round", "stroke-linecap": "round", "vector-effect": "non-scaling-stroke"
  }));
  for (const [x, y] of [points[0], points[points.length - 1]]) {
    children.push(svgElement("circle", { cx: x, cy: y, r: 5, fill: "#38e8c6", stroke: "#0b2830", "stroke-width": 3 }));
  }
  chart.replaceChildren(...children);
  chart.setAttribute("aria-label", `21 个收盘价走势图，起始 ${numbers[0]}，结束 ${numbers[numbers.length - 1]}`);
}

function renderReport(reportValue) {
  const fingerprint = reportValue
    ? `${view.test?.id || ""}:${view.localRunId || ""}:${JSON.stringify(reportValue)}`
    : null;
  if (fingerprint === view.reportFingerprint) return;
  view.reportFingerprint = fingerprint;
  const report = asObject(reportValue);
  const hasReport = Boolean(report.sample && report.cpu);
  const hasFpga = hasReport && report.mode === "fpga" && Boolean(report.fpga);
  fields.resultsEmpty.hidden = hasReport;
  fields.resultsBody.hidden = !hasReport;
  if (!hasReport) {
    setText(fields.resultTimestamp, "等待测试数据");
    return;
  }

  const cpu = asObject(report.cpu);
  const fpga = asObject(report.fpga);
  const error = asObject(report.error);
  const matchingRows = renderSums(cpu.sums, fpga.sums, hasFpga);
  const matching = hasFpga && matchingRows && fpga.exact_match === true;
  setText(fields.fpgaVol, hasFpga ? formatDecimal(fpga.vol20) : "待测试");
  setText(fields.cpuVol, formatDecimal(cpu.vol20_original));
  setText(fields.quantizedVol, formatDecimal(cpu.vol20_quantized));
  setText(fields.volError, hasFpga ? formatSmall(error.vol20_abs) : "—");
  setText(fields.returnError, hasFpga ? formatSmall(error.max_return_quantization) : "—");
  const exec = fpga.exec_us == null ? NaN : Number(fpga.exec_us);
  setText(fields.execTime, hasFpga && Number.isFinite(exec) ? `${exec.toFixed(3)} µs` : "—");
  setText(fields.fpgaMatch, hasFpga ?
    (matching ? "五项整数结果与 CPU 完全一致" : "整数结果不一致，请检查测试") :
    "CPU 参考值已显示；等待 FPGA 实机结果");
  fields.fpgaMatch.classList.toggle("failed", hasFpga && !matching);
  setText(fields.resultTimestamp, hasFpga ?
    `FPGA 实机测试于 ${formatTime(report.tested_at)} · ${view.localRunId && view.test && String(view.test.id) === view.localRunId ? "本次运行" : "最近一次运行"}` :
    "固定测试样本 · CPU 参考值（尚无本次 FPGA 返回）");
  renderInputs(asObject(report.sample));
}

async function requestJson(url, options = {}, timeoutMs = 12000) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { cache: "no-store", credentials: "same-origin", ...options, signal: controller.signal });
    let data;
    try { data = await response.json(); }
    catch { throw new Error("测试服务返回了无法识别的数据"); }
    if (!response.ok) throw new Error(data.error || data.message || `请求失败 (${response.status})`);
    return data;
  } catch (error) {
    if (error.name === "AbortError") throw new Error("测试服务响应超时");
    throw error;
  } finally {
    window.clearTimeout(timeout);
  }
}

async function loadStatus() {
  if (view.polling) return;
  view.polling = true;
  try {
    const status = await requestJson("/api/status");
    view.connected = true;
    view.sampleReference = status.sample || null;
    view.monitorReady = asObject(status.monitor).ready === true;
    view.monitorMessage = asObject(status.monitor).message || "";
    if (view.networkNotice) showNotice("");
    let test = status.test || null;
    if (!test && view.localRunId && Date.now() < view.pendingUntil) {
      test = { id: view.localRunId, state: "queued", phase: "测试任务已创建，等待启动…", steps: [] };
    }
    renderTest(test, view.sampleReference);
    renderTelemetry(status);
  } catch (error) {
    view.connected = false;
    view.monitorReady = false;
    setText(fields.serviceValue, "连接中断");
    setText(fields.serviceDetail, "正在重试本机测试服务");
    showNotice(`无法读取测试服务：${error.message}`, true, true);
    renderButton();
  } finally {
    view.polling = false;
  }
}

async function beginTest() {
  if (!view.connected || !view.monitorReady || view.submitting || isActive(view.test) || restoreFailed(view.test)) return;
  view.submitting = true;
  showNotice("");
  renderButton();
  try {
    const created = await requestJson("/api/test", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-WQ-Action": "run" },
      body: "{}"
    }, 15000);
    if (!created || !created.test || !created.test.id) throw new Error("测试服务没有返回任务编号");
    view.localRunId = String(created.test.id);
    view.pendingUntil = Date.now() + 15000;
    renderTest(created.test, view.sampleReference);
    showNotice("测试已启动，正在读取进度。", false);
    await loadStatus();
  } catch (error) {
    showNotice(`无法开始测试：${error.message}`, true);
  } finally {
    view.submitting = false;
    renderButton();
  }
}

async function pollLoop() {
  await loadStatus();
  window.setTimeout(pollLoop, isActive(view.test) || view.submitting ? 1200 : 5000);
}

fields.phaseText.setAttribute("aria-live", "polite");
fields.runButton.addEventListener("click", beginTest);
pollLoop();
