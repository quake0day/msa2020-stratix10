#!/usr/bin/env bash
# Run after programming the moments-capable DMA image and building both modules.
set -euo pipefail

module_dir=${WQ_DMA_MODULE_DIR:-$HOME/corundum/modules}
device=${WQ_DMA_DEVICE:-/dev/wqfpga0}
tool=$module_dir/wqfpga_dma/wqfpga-moments-test

[[ -e /dev/mqnic0 ]] || { echo "Load mqnic.ko first" >&2; exit 1; }
[[ -x $tool ]] || { echo "Build $tool first" >&2; exit 1; }
if grep -Eq '^(mqnic_app_dma_smoketest|wqfpga_dma) ' /proc/modules; then
    echo "Unload the existing application DMA driver first" >&2
    exit 1
fi

"$tool" --self-test
sudo -n insmod "$module_dir/wqfpga_dma/wqfpga_dma.ko"
trap 'sudo -n rmmod wqfpga_dma 2>/dev/null || true' EXIT
[[ -c $device ]] || { echo "$device was not created; inspect dmesg" >&2; exit 1; }
sudo -n "$tool" "$device"
sudo -n python3 "$module_dir/wqfpga_dma/moments_vol20_demo.py" --device "$device"
sudo -n "$tool" --benchmark "$device"
