#!/usr/bin/env bash
# Use `prepare` before JTAG programming and `finish` after it. The child bus
# must be empty at finish so Linux can resize the parent bridge for both BARs.
# Run only while no FPGA DMA driver or transfer is active.
set -euo pipefail

phase=${1:-}
bdf=${WQ_DMA_BDF:-0000:01:00.0}
dev=/sys/bus/pci/devices/$bdf
bus=/sys/class/pci_bus/${bdf%:*}/rescan

[[ $phase == prepare || $phase == finish ]] || {
    echo "Usage: $0 prepare|finish" >&2
    exit 2
}
[[ -e $bus ]] || { echo "PCIe bus-specific rescan is unavailable: $bus" >&2; exit 1; }
if grep -Eq '^(mqnic|mqnic_app_dma_smoketest|mqnic_app_dma|wqfpga_dma) ' /proc/modules; then
    echo "Unload the FPGA DMA drivers before re-enumeration" >&2
    exit 1
fi
if [[ $phase == prepare ]]; then
    if [[ -d $dev ]]; then
        printf '1\n' | sudo -n tee "$dev/remove" >/dev/null
    fi
    [[ ! -d $dev ]] || { echo "The FPGA PCIe device was not removed" >&2; exit 1; }
    echo "FPGA endpoint removed; program the .sof via JTAG, then run $0 finish"
    exit 0
fi

[[ ! -d $dev ]] || { echo "FPGA endpoint is still registered; run prepare first" >&2; exit 1; }

# Rescanning an empty child bus requests bridge-resource resizing in Linux.
sleep 2  # allow the PCIe link to retrain after FPGA reconfiguration
for attempt in {1..10}; do
    printf '1\n' | sudo -n tee "$bus" >/dev/null
    [[ -d $dev ]] && break
    sleep 1
done
[[ -d $dev ]] || { echo "FPGA did not return at $bdf; restore Golden by JTAG" >&2; exit 1; }

printf 'PCIe identity: %s:%s\n' "$(<"$dev/vendor")" "$(<"$dev/device")"
[[ $(<"$dev/vendor") == 0x1234 && $(<"$dev/device") == 0x1001 ]] || {
    echo "Expected the DMA firmware identity 1234:1001" >&2
    exit 1
}
python3 - "$dev" <<'PY'
import sys
from pathlib import Path

endpoint = Path(sys.argv[1]).resolve()
resources = [tuple(int(x, 16) for x in line.split()) for line in open(endpoint / 'resource')]
bridge_resources = [tuple(int(x, 16) for x in line.split()) for line in open(endpoint.parent / 'resource')]
for index in (0, 2):
    start, end, _ = resources[index]
    if not start or end < start:
        raise SystemExit(f"BAR{index} was not assigned")
    if not any(base and base <= start <= end <= limit for base, limit, _ in bridge_resources):
        raise SystemExit(f"BAR{index} is outside the parent bridge window")
    print(f"BAR{index}: 0x{start:x}-0x{end:x}")
PY
