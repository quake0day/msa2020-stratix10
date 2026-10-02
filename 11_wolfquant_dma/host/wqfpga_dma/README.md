# WolfQuant DMA scratch interface

`wqfpga_dma.ko` binds to Corundum application ID `0x12348001` and exposes
`/dev/wqfpga0`. `pread` copies bytes from the FPGA application's scratch RAM
to a userspace buffer; `pwrite` copies in the other direction. The file offset
is a byte offset in card RAM. A shared 4 KiB coherent staging buffer and mutex
make every request bounded and serialized; larger requests are split into 4 KiB
DMA descriptors. Userspace never supplies a DMA address.

The upstream `dma_bench.v` instantiates **16 KiB** of RAM. This prototype only
exposes its low **8 KiB**, pending full-range board validation. Reads stop at
end of window; writes past it return a short count or `ENOSPC`. This module is
only a transport/scratch-memory interface, not a WolfQuant algorithm yet.

## Build (Ubuntu host with matching kernel headers)

Place this directory beside the patched `mqnic/` module source and build both
for the **running** kernel. `../mqnic/Module.symvers` is required by Kbuild.

```sh
cd ~/corundum/modules/mqnic && make
cd ../wqfpga_dma && make
modinfo ./wqfpga_dma.ko | grep vermagic
make test  # software-only tag wraparound test
```

This project must be loaded only after the matching WolfQuant DMA FPGA image
enumerates as `1234:1001`, the parent `mqnic.ko` is loaded, and the application
BAR and register block are visible. It is mutually exclusive with the separate
`mqnic_app_dma_smoketest` driver because both bind the same auxiliary device.

```sh
sudo insmod ./wqfpga_dma.ko
./wqfpga-loopback /dev/wqfpga0 1048576
sudo rmmod wqfpga_dma
```

The loopback tool writes pseudorandom chunks, reads them back, and compares
every byte. Its cases cover 1-byte, 257-byte, 4095/4096-byte, 4 KiB boundary
crossing, and last-byte transfers. It deliberately reuses the 8 KiB card
window, so the command can test more than 8 KiB of host data. Run it as the
only client: separate processes can change the same shared card RAM between
its write and read system calls.
The application DMA tag is limited to 13 bits by the Corundum interface mux;
the driver cycles through tags 1..8191 without producing a truncated tag.

On a DMA timeout or bad completion, the driver disables PCI bus mastering for
the entire FPGA function, rejects further I/O, and quarantines its 4 KiB DMA
buffer and mapping instead of freeing memory that the card might still access.
This also stops mqnic networking on that function. Power-cycle or reset the
FPGA before rebooting the Linux host. A failed run is never a successful DMA
test, even if an earlier chunk completed.
