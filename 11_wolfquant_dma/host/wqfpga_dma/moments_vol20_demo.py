#!/usr/bin/env python3
"""Compare WolfQuant vol20 with a moments-v1 FPGA result for 21 completed closes.

This research-only example does not make or change a trading decision.  The
hardware receives the 20 close-to-close returns as signed Q20 x values; y is
zero.  The CPU still performs division and square root on the returned sums.
"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import json
import math
import os
import struct
from pathlib import Path


ABI_VERSION = 1
APP_ID = 0x12348001
FEATURE_MOMENTS_V1 = 1
OP_MOMENTS = 1
FORMAT_VERSION = 1
Q_SCALE = 1 << 20
INPUT_MIN = -(1 << 23)
INPUT_MAX = (1 << 23) - 1
OUTPUT_BYTES = 40

# Demonstration data only, oldest completed close first.  A real research
# replay must supply point-in-time adjusted closes from its own dataset.
SAMPLE_CLOSES = (
    100.00, 100.42, 99.87, 100.31, 101.12, 100.92, 101.33,
    100.74, 101.26, 102.14, 101.88, 102.57, 102.21, 101.95,
    102.73, 103.44, 103.17, 103.68, 103.02, 103.57, 104.11,
)


class Caps(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("features", ctypes.c_uint32),
        ("app_id", ctypes.c_uint32),
        ("moments_kernel_version", ctypes.c_uint32),
        ("moments_max_pairs", ctypes.c_uint32),
        ("moments_q_frac_bits", ctypes.c_uint32),
        ("moments_input_min", ctypes.c_int32),
        ("moments_input_max", ctypes.c_int32),
        ("reserved", ctypes.c_uint32 * 7),
    ]


class Exec(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("opcode", ctypes.c_uint32),
        ("format_version", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("pair_count", ctypes.c_uint32),
        ("input_bytes", ctypes.c_uint32),
        ("output_capacity", ctypes.c_uint32),
        ("input_ptr", ctypes.c_uint64),
        ("output_ptr", ctypes.c_uint64),
        ("user_cookie", ctypes.c_uint64),
        ("result_bytes", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("reserved", ctypes.c_uint64 * 4),
    ]


def verify_layout() -> None:
    if (ctypes.sizeof(Caps), ctypes.sizeof(Exec)) != (64, 96):
        raise RuntimeError("Python ioctl layout does not match the 64/96-byte C ABI")
    if (Exec.input_ptr.offset, Exec.output_ptr.offset) != (32, 40):
        raise RuntimeError("Python ioctl pointer offsets do not match the C ABI")


def iowr(number: int, size: int) -> int:
    # Linux _IOWR on the x86-64 FPGA host: direction 3, type 'W'.
    return (3 << 30) | (size << 16) | (ord("W") << 8) | number


IOCTL_GET_CAPS = iowr(0, ctypes.sizeof(Caps))
IOCTL_EXEC = iowr(1, ctypes.sizeof(Exec))


def as_bytes(value: ctypes.Structure) -> bytearray:
    return bytearray(ctypes.string_at(ctypes.addressof(value), ctypes.sizeof(value)))


def load_closes(path: Path | None) -> list[float]:
    values = json.loads(path.read_text(encoding="utf-8")) if path else SAMPLE_CLOSES
    if not isinstance(values, (list, tuple)) or len(values) != 21:
        raise ValueError("provide exactly 21 completed closes in chronological order")
    closes = []
    for value in values:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("each close must be a finite positive number")
        close = float(value)
        if not math.isfinite(close) or close <= 0:
            raise ValueError("each close must be a finite positive number")
        closes.append(close)
    return closes


def returns_from_closes(closes: list[float]) -> list[float]:
    # Same operation as np.diff(closes) / closes[:-1] in research/engine.py.
    return [(closes[i + 1] - closes[i]) / closes[i] for i in range(20)]


def vol20_python(returns: list[float]) -> float:
    mean = sum(returns) / len(returns)
    variance = sum((value - mean) ** 2 for value in returns) / len(returns)
    return math.sqrt(variance) * math.sqrt(252.0)


def encode_q20(returns: list[float]) -> tuple[list[int], bytes]:
    raw = [round(value * Q_SCALE) for value in returns]
    if any(value < INPUT_MIN or value > INPUT_MAX for value in raw):
        raise ValueError("a Q20 return exceeds the signed-24-bit moments range")
    return raw, b"".join(struct.pack("<ii", value, 0) for value in raw)


def cpu_integer_moments(raw: list[int]) -> tuple[int, int, int, int, int]:
    return (sum(raw), 0, sum(value * value for value in raw), 0, 0)


def vol20_from_moments(moments: tuple[int, int, int, int, int], n: int) -> float:
    sum_x, _, sum_x2, _, _ = moments
    variance_q40 = sum_x2 / n - (sum_x / n) ** 2
    return math.sqrt(max(0.0, variance_q40)) / Q_SCALE * math.sqrt(252.0)


def run_hardware(device: str, payload: bytes, pairs: int) -> tuple[int, int, int, int, int]:
    fd = os.open(device, os.O_RDWR | os.O_CLOEXEC)
    try:
        caps = Caps()
        caps.struct_size = ctypes.sizeof(Caps)
        caps.abi_version = ABI_VERSION
        caps_buffer = as_bytes(caps)
        fcntl.ioctl(fd, IOCTL_GET_CAPS, caps_buffer, True)
        caps = Caps.from_buffer_copy(caps_buffer)
        if caps.abi_version != ABI_VERSION or caps.app_id != APP_ID:
            raise RuntimeError("unexpected FPGA application or host ABI")
        if not caps.features & FEATURE_MOMENTS_V1:
            raise RuntimeError("moments v1 kernel is absent from this FPGA image")
        if (caps.moments_kernel_version != 0x00010000 or
                caps.moments_max_pairs < pairs or caps.moments_q_frac_bits != 20 or
                caps.moments_input_min != INPUT_MIN or
                caps.moments_input_max != INPUT_MAX):
            raise RuntimeError("unexpected moments v1 firmware capabilities")

        input_buffer = (ctypes.c_ubyte * len(payload)).from_buffer_copy(payload)
        output_buffer = (ctypes.c_ubyte * OUTPUT_BYTES)()
        job = Exec()
        job.struct_size = ctypes.sizeof(Exec)
        job.abi_version = ABI_VERSION
        job.opcode = OP_MOMENTS
        job.format_version = FORMAT_VERSION
        job.pair_count = pairs
        job.input_bytes = len(payload)
        job.output_capacity = OUTPUT_BYTES
        job.input_ptr = ctypes.addressof(input_buffer)
        job.output_ptr = ctypes.addressof(output_buffer)
        job_buffer = as_bytes(job)
        fcntl.ioctl(fd, IOCTL_EXEC, job_buffer, True)
        completed = Exec.from_buffer_copy(job_buffer)
        if completed.result_bytes != OUTPUT_BYTES:
            raise RuntimeError("incomplete moments result")
        return struct.unpack("<5q", bytes(output_buffer))
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--self-test", action="store_true", help="run without FPGA")
    mode.add_argument("--device", help="moments device, e.g. /dev/wqfpga0")
    parser.add_argument("--closes-json", type=Path,
                        help="JSON array of 21 completed closes, oldest first")
    args = parser.parse_args()

    verify_layout()
    closes = load_closes(args.closes_json)
    returns = returns_from_closes(closes)
    raw, payload = encode_q20(returns)
    expected = cpu_integer_moments(raw)
    quantized_returns = [value / Q_SCALE for value in raw]
    quantized_vol = vol20_python(quantized_returns)
    original_vol = vol20_python(returns)

    if args.self_test:
        actual = struct.unpack("<5q", struct.pack("<5q", *expected))
        source = "CPU-emulated moments"
    else:
        actual = run_hardware(args.device, payload, len(raw))
        source = "FPGA moments"
    if actual != expected:
        raise RuntimeError(f"moments mismatch: CPU {expected}, {source} {actual}")
    result_vol = vol20_from_moments(actual, len(raw))
    if not math.isclose(result_vol, quantized_vol, rel_tol=1e-12, abs_tol=1e-12):
        raise RuntimeError("moments reconstruction differs from quantized CPU reference")

    print(f"Input: 21 completed closes, {len(raw)} returns, Q20 x and zero y")
    print(f"CPU original vol20 (np.std ddof=0 equivalent, annualized): {original_vol:.12f}")
    print(f"CPU quantized-return vol20: {quantized_vol:.12f}")
    print(f"{source} reconstructed vol20: {result_vol:.12f}")
    print(f"Maximum absolute return quantization error: "
          f"{max(abs(a - b) for a, b in zip(returns, quantized_returns)):.12g}")
    print(f"Absolute vol20 difference from original: {abs(result_vol - original_vol):.12g}")
    print("PASS: all five raw integer moments matched the CPU reference")
    print("Near a strategy threshold, use the original CPU vol20 for the final decision.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(f"ERROR: {error}") from error
