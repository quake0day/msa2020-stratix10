# Moments v1 RTL simulation

Run `powershell -File sim/run_questa.ps1` from the project root.  The script
uses Questa FSE and the Corundum `dma_psdpram` source at the paths shown in
its parameters; override those parameters if either installation moved.

The self-checking bench drives the same 2 × 256-bit segmented RAM interface
used by the application DMA.  It tests 1, 9, 20, and 1024 input pairs, signed
edge values, all five exact 64-bit sums, maximum-capacity row traversal,
staggered segment responses, input range and count errors, DMA-busy rejection,
descriptor/completion handoff, and BAR register status clearing.  A final
`ALL MOMENTS TESTS PASSED` line is required for success.

This is a module simulation.  It does not replace Quartus timing analysis or
an on-board DMA-to-compute comparison with the Linux driver.
