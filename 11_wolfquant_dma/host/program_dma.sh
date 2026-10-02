#!/usr/bin/env bash
# Run from Git Bash on the Windows JTAG host after the SOF has been built.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ctf_root=${MSA_CTF_ROOT:-/h/msa2020-ctf}
remote_script=${WQ_DMA_REMOTE_REENUMERATE:-/home/quake0day/corundum/wq-dma/reenumerate_dma.sh}
sof=$project_root/output_files/wolfquant_dma.sof

[[ $# -eq 0 ]] || { echo "Usage: $0 (DMA image only; restore Golden with infra/golden_reset.sh)" >&2; exit 2; }

source "$ctf_root/infra/lib/common.sh"
source "$ctf_root/infra/lib/jtag.sh"
msa_load_config
[[ -f $sof ]] || die "SOF does not exist: $sof"
msa_host_reachable || die "Linux host is unreachable"

msa_pause_temperature_monitor
jtag_chain_ok || die "FPGA JTAG chain is unavailable"
msa_target_ssh "bash $remote_script prepare"
jtag_program "$sof"
msa_target_ssh "bash $remote_script finish"
