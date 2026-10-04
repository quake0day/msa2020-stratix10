#!/usr/bin/env python3
"""Emit one auditable WolfQuant moments test as JSON for the local dashboard.

Only --device performs a hardware test.  --self-test emits the input and CPU
reference without fabricating an FPGA result, so the dashboard cannot mistake
a software-only check for a passing board test.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import time

from moments_vol20_demo import (
    APP_ID,
    Q_SCALE,
    SAMPLE_CLOSES,
    cpu_integer_moments,
    encode_q20,
    returns_from_closes,
    run_hardware,
    verify_layout,
    vol20_from_moments,
    vol20_python,
)


SUM_NAMES = ("sum_x", "sum_y", "sum_x2", "sum_y2", "sum_xy")


def sums_as_strings(values: tuple[int, int, int, int, int]) -> dict[str, str]:
    """Keep signed 64-bit sums exact in a JavaScript client."""
    return {name: str(value) for name, value in zip(SUM_NAMES, values, strict=True)}


def build_report(device: str | None = None, hardware_call=run_hardware) -> dict:
    closes = list(SAMPLE_CLOSES)
    returns = returns_from_closes(closes)
    raw, payload = encode_q20(returns)
    expected = cpu_integer_moments(raw)
    quantized_returns = [value / Q_SCALE for value in raw]
    original_vol = vol20_python(returns)
    quantized_vol = vol20_python(quantized_returns)

    report = {
        "report_version": 1,
        "tested_at": datetime.now(timezone.utc).isoformat(),
        "mode": "fpga" if device else "cpu-self-test",
        "sample": {
            "label": "21 completed sample closes; 20 close-to-close returns",
            "closes": closes,
            "returns": returns,
            "q20": raw,
            "q20_y": 0,
            "pair_count": len(raw),
        },
        "cpu": {
            "sums": sums_as_strings(expected),
            "vol20_original": original_vol,
            "vol20_quantized": quantized_vol,
        },
        "fpga": None,
        "error": None,
        "metadata": {
            "app_id": f"0x{APP_ID:08x}",
            "kernel_version": "0x00010000",
            "format": "signed int32 Q20 x; signed int32 Q20 y=0; little-endian",
            "input_bytes": len(payload),
            "output_bytes": 40,
        },
    }

    if device is None:
        return report

    started = time.perf_counter_ns()
    actual = hardware_call(device, payload, len(raw))
    elapsed_us = (time.perf_counter_ns() - started) / 1000.0
    if len(actual) != len(SUM_NAMES):
        raise RuntimeError("FPGA returned the wrong number of moments")
    result_vol = vol20_from_moments(actual, len(raw))
    exact_match = actual == expected
    reconstruction_match = math.isclose(
        result_vol, quantized_vol, rel_tol=1e-12, abs_tol=1e-12
    )
    report["fpga"] = {
        "sums": sums_as_strings(actual),
        "vol20": result_vol,
        "exec_us": elapsed_us,
        "timing_scope": "device open + GET_CAPS + EXEC + close",
        "exact_match": exact_match,
        "reconstruction_match": reconstruction_match,
    }
    report["error"] = {
        "vol20_abs": abs(result_vol - original_vol),
        "max_return_quantization": max(
            abs(a - b) for a, b in zip(returns, quantized_returns, strict=True)
        ),
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--device", help="moments-v1 device, e.g. /dev/wqfpga0")
    mode.add_argument("--self-test", action="store_true", help="CPU-only JSON check")
    args = parser.parse_args()
    verify_layout()
    report = build_report(args.device)
    print(json.dumps(report, ensure_ascii=False, allow_nan=False, separators=(",", ":")))
    if args.device and not (
        report["fpga"]["exact_match"] and report["fpga"]["reconstruction_match"]
    ):
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(f"ERROR: {error}") from error
