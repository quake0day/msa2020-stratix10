# WolfQuant FPGA local dashboard

This small Node service shows the fixed 21-close WolfQuant sample, CPU reference,
and **actual** moments returned by the FPGA. It serves only
`http://127.0.0.1:4174/` on the Windows JTAG machine. No account, arbitrary
shell command, host, dataset, path, or power-control input is accepted from the
browser. A successful test means the exact five integer sums matched the CPU
reference **and** the board was restored to CTF Golden afterward.
The page shows the fixed input closes, returns, Q20 codes, and CPU reference
immediately. FPGA output remains marked “waiting for hardware” until a real
probe result arrives; a failed run never substitutes CPU data for FPGA data.
The separate dated history card copies the previous synthetic FPGA replay
report from WolfQuant. It is labeled as historical and uses a different sample.

From a PowerShell terminal on that machine:

```powershell
cd H:\msa2020-dma\11_wolfquant_dma\dashboard
npm test
npm start
```

To leave it running in the background on Windows, use
`./start-dashboard.ps1`; add `-OpenBrowser` to open the page. Re-running the
script checks the existing service and does not start a duplicate.

The button executes one job at a time. Preflight checks a fresh plausible
temperature below 75°C, the independent FPGA power and Linux host interlocks,
the known-tested SOF hash, SSH key/sudo access, and driver/kernel compatibility.
The PCIe endpoint may be absent before programming; `program_dma.sh` uses JTAG
and a targeted PCIe rescan to bring it back. The pipeline then verifies bounded
DMA, the existing 12-size exact moments test, and a separate JSON probe of the
fixed sample. The probe runs against `/dev/wqfpga0`; CPU-only fallback is never
reported as an FPGA pass. Each command has a timeout and bounded output.

Once programming starts, completion, failure, or an ordinary server stop all
trigger driver unloading, `golden_reset.sh --challenge bar-fuzzing`, and
`board_health.sh --challenge bar-fuzzing`. The test is marked passed only if
Golden verification succeeds. If the process is interrupted, the persisted
job state triggers restoration when the service next starts. A failed Golden
restoration is shown separately and must be resolved before assuming the card
is safe. The service does not reboot or shut down the Linux host, control the
FPGA power socket, or turn off its fans.

`GET /api/status` returns `{test,monitor,sample}`. The `sample` is a checked-in
CPU-only reference generated with `dashboard_probe.py --self-test`.
`POST /api/test` accepts only `{}`
with same-origin `Origin`, JSON content type, and `X-WQ-Action: run`; it returns
HTTP 202 with a new test or HTTP 409 while another test or recovery is active.
The test object includes `id`, `state`, `phase`, timestamped lifecycle fields,
`steps`, `error`, `restoreStatus`, and `report`. The report has `sample`, `cpu`,
`fpga`, and `error` sections. The latest status is saved in ignored
`dashboard/runtime/status.json` so a refresh or restart retains the result.
