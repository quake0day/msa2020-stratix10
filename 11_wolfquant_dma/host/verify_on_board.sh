#!/usr/bin/env bash
# Run only after programming wolfquant_dma.sof and re-enumerating the PCIe device.
set -euo pipefail

bdf=${WQ_DMA_BDF:-0000:01:00.0}
source_dir=${WQ_DMA_MODULE_DIR:-$HOME/corundum/modules}
dev=/sys/bus/pci/devices/$bdf

[[ -d $dev ]] || { echo "FPGA PCIe device $bdf is absent" >&2; exit 1; }
[[ $(<"$dev/vendor") == 0x1234 && $(<"$dev/device") == 0x1001 ]] || {
    echo "FPGA does not have the DMA firmware identity (1234:1001)" >&2
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
    if start == 0 or end < start:
        raise SystemExit(f"BAR{index} has no assigned PCIe address")
    if not any(base and base <= start <= end <= limit for base, limit, _ in bridge_resources):
        raise SystemExit(f"BAR{index} is outside the parent bridge window")
    print(f"BAR{index}: 0x{start:x}-0x{end:x} ({end-start+1} bytes)")
PY

for module in ptp i2c-algo-bit i2c-mux i2c-dev; do
    sudo -n modprobe "$module"
done
if ! grep -q '^mqnic ' /proc/modules; then
    sudo -n insmod "$source_dir/mqnic/mqnic.ko"
fi

aux_device=$(find /sys/bus/auxiliary/devices -maxdepth 1 -name 'mqnic.app_12348001*' -print -quit)
[[ -n $aux_device ]] || { echo "mqnic did not discover application 12348001" >&2; exit 1; }

for length in 256 4096; do
    before=$(sudo -n dmesg | grep -Fc "DMA roundtrip passed: $length bytes" || true)
    sudo -n insmod "$source_dir/mqnic_app_dma_smoketest/mqnic_app_dma_smoketest.ko" "test_len=$length"
    after=$(sudo -n dmesg | grep -Fc "DMA roundtrip passed: $length bytes" || true)
    if [[ $after -ne $((before + 1)) ]] || [[ ! -L $aux_device/driver ]]; then
        echo "DMA $length-byte test did not complete; inspect dmesg and reset the FPGA before retry" >&2
        exit 1
    fi
    echo "DMA roundtrip verified: $length bytes"
    sudo -n rmmod mqnic_app_dma_smoketest
done
