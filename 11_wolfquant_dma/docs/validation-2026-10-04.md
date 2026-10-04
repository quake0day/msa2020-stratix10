# Hardware validation — 2026-10-04 (America/New_York)

This is a fresh hardware result, separate from the 2026-10-02 synthetic replay
and the dashboard's interrupted 08:55 one-click job. The 08:55 JTAG command
reported successful configuration of `wolfquant_dma.sof`, but the Linux host
was restarted during that job, so its follow-up SSH command timed out. That
dashboard job correctly remained failed; it did not produce a probe report.

When the Linux host returned, it enumerated the FPGA as `1234:1001` at
`0000:01:00.0` with both 16 MiB BARs assigned under the parent bridge. The
256-byte and 4096-byte kernel-owned bidirectional DMA roundtrips passed.
`verify_moments.sh` then passed exact FPGA/CPU parity for 12 input sizes up to
1024 pairs and rejected invalid inputs.

The separate fixed 21-close hardware probe returned the five exact signed
integer sums `sum_x=42546`, `sum_y=0`, `sum_x2=652703916`, `sum_y2=0`, and
`sum_xy=0`. Each matched the CPU's Q20 reference. FPGA-reconstructed vol20
was `0.08026554550535098`; the original floating-point CPU value was
`0.08026658925908041`. The probe's device-open/capability-check/EXEC/close
scope took 285.853 microseconds. Its full JSON, including inputs and UTC
timestamp, is [validation-2026-10-04.json](validation-2026-10-04.json).

The 200-sample `EXEC` benchmark returned p50/p99 of 226.837/239.251
microseconds for 20 pairs and 243.641/251.992 microseconds for 1024 pairs.
These measurements validate correctness; the CPU reference remains much
faster for these small synchronous jobs.

After the probe, the application drivers were unloaded. At 09:00 local time,
`golden_reset.sh --challenge bar-fuzzing` configured the known Golden SOF and
verified BAR0 magic `0x42415246`; a separate `board_health.sh --challenge
bar-fuzzing` returned `GOLDEN`. The Linux host and fans remained running.

The earlier 18950/18948 JTAG failures were intermittent. Successful
configuration occurred before the temperature monitor was switched from
Quartus 26.1 to 23.3, so the version mismatch is not established as their
root cause.

## Complete browser one-click run

After a separate read-only `board_health.sh` check returned exactly `GOLDEN`,
the local dashboard's one-click test ran from 09:10:01 to 09:11:16 local time
(job `5a98e822-1a86-451b-baeb-42d26fcd2257`). All ten steps passed:
preflight, moments-image programming and PCIe enumeration, 256/4096-byte DMA,
12-size moments parity, probe copy and driver load, fixed-sample FPGA probe,
driver unload, Golden restoration, and Golden health verification. The page
displayed the five exact sums, FPGA `vol20=0.08026554550535098`, original CPU
`vol20=0.08026658925908041`, and a 278.942-microsecond probe call. The run
ended with `state=passed` and `restoreStatus=golden`. Its persisted job record
is archived as [dashboard-validation-2026-10-04.json](dashboard-validation-2026-10-04.json).

The monitor reported about 39°C, independent FPGA power ready, and Linux host
online after the run. Its high-temperature action now leaves the Linux host
and cooling fans on while retaining FPGA-only socket shutdown.
