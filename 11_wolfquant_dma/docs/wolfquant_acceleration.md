# WolfQuant hybrid accelerator path

The first FPGA compute block is a **versioned integer moments primitive**, not a replacement for WolfQuant's existing floating-point research engine. It accepts up to 1,024 pairs of signed Q20 values and returns exact integer sums of `x`, `y`, `x*x`, `y*y`, and `x*y`. The Linux driver owns the DMA address and serializes the input transfer and computation. Software handles divisions, square roots, annualization, and trading-rule comparisons.

## Why this kernel first

`research/engine.py` currently derives `return5`, `vol20`, and `volumeRatio` from the preceding completed sessions inside the backtest loop. Rolling moments can support volatility, covariance, correlation, and anomaly features without making the FPGA responsible for floating-point thresholds. A 20-return window can be quantized, reduced on the FPGA, then finalized by the CPU. At any threshold boundary the existing CPU result remains authoritative. The input record format is deliberately independent of a particular market feed so that a later high-rate event pipeline can reuse the same arithmetic contract.

The available automatic data source processes only small batches of daily bars. For that workload, copying, DMA submission, polling, and result reads may cost more than the CPU calculation. The first release must be judged by **correctness and measured end-to-end latency**, not by a claimed speedup. A useful benchmark compares full feature extraction with the existing NumPy path, including quantization and driver overhead, at several batch sizes. It must report p50/p99 latency and per-record throughput, and preserve the original CPU path as a fallback.

On the MSA-2020 card, expanding the coherent staging buffer from 4 KiB to 8 KiB reduced the 1,024-pair input from two DMA descriptors to one. Same-host 200-sample p50/p99 `EXEC` latency fell from 354/359 µs to 243/248 µs for that case; the 20-pair case stayed near 230/238 µs. Exact parity and 1 MiB/32 MiB DMA loopbacks passed after the change. A same-input optimized C integer reduction is still much faster, so the synchronous path remains a correctness prototype. The separate `moments_vol20_demo.py` verifies a real WolfQuant feature formula: 21 completed closes yielded an original `vol20` of 0.080266589259 and a Q20-reconstructed value of 0.080265545505. Batch submission and an event feed are prerequisites for a useful throughput comparison with the production Python path.

Heston option pricing is a different workload: its complex characteristic-function integration and parameter sweeps are better candidates for a future GPU batch service. The TypeSafe Jev API can supply event/text features to the research service, but it should not be placed in the FPGA's synchronous data path. A research result should record the source data version, Jev response/version, FPGA firmware version, quantization format, and the CPU/GPU/FPGA implementation used.

## Moments v1 arithmetic contract

Each little-endian input record is `(int32 x, int32 y)`, representing real values `(x / 2^20, y / 2^20)`. Only integers in `[-2^23, 2^23-1]` are accepted. A job contains 1 to 1,024 records in the first 8 KiB of application scratch RAM. The output has a count and five signed 64-bit integers in this order:

1. `sum_x = Σx`
2. `sum_y = Σy`
3. `sum_x2 = Σx²`
4. `sum_y2 = Σy²`
5. `sum_xy = Σxy`

The magnitude restriction bounds every product sum below `2^56`, so signed 64-bit outputs are exact. The CPU can derive population variance as `sum_x2 / (n * 2^40) - (sum_x / (n * 2^20))²`; covariance uses `sum_xy` similarly. Software clamps a tiny negative variance caused by its own floating-point subtraction to zero. Quantization changes the result relative to NumPy floating point, so parity checks must compare both exact integer sums and the final feature with an explicit tolerance. Trading decisions at or near a threshold should use the original CPU calculation.

## Next interfaces

The diagnostic `/dev/wqfpga0` `pread`/`pwrite` scratch interface remains useful for DMA bring-up, but applications should use a versioned `GET_CAPS`/`EXEC` job interface. The driver validates the firmware identity, copies user input into a kernel-owned coherent buffer, submits bounded transfers, waits for completion, and returns results without accepting a user-supplied physical address. The next performance step is a driver-owned submission/completion queue with pinned buffers and batched windows. A service on the Linux host can then expose authenticated, bounded requests to WolfQuant over the LAN while keeping the device protocol private.

Before integrating feature results into backtests, replay identical dated datasets through CPU and FPGA paths, compare every window, test time-prefix invariance (no future bar changes an earlier result), and record both numerical differences and decision differences. Only enable acceleration for a workload whose end-to-end benchmark shows a benefit.
