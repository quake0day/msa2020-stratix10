#!/usr/bin/env bash
# Run after verify_on_board.sh: validate the userspace DMA transport.
set -euo pipefail

module_dir=${WQ_DMA_MODULE_DIR:-$HOME/corundum/modules}
device=${WQ_DMA_DEVICE:-/dev/wqfpga0}

[[ -e /dev/mqnic0 ]] || { echo "Load mqnic.ko first" >&2; exit 1; }
if grep -Eq '^(mqnic_app_dma_smoketest|wqfpga_dma) ' /proc/modules; then
    echo "Unload the existing application DMA driver first" >&2
    exit 1
fi

sudo -n insmod "$module_dir/wqfpga_dma/wqfpga_dma.ko"
trap 'sudo -n rmmod wqfpga_dma 2>/dev/null || true' EXIT
[[ -c $device ]] || { echo "$device was not created; inspect dmesg" >&2; exit 1; }

sudo -n "$module_dir/wqfpga_dma/wqfpga-loopback" "$device" 1048576
sudo -n "$module_dir/wqfpga_dma/wqfpga-loopback" "$device" 33554432
