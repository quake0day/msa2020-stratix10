# WolfQuant DMA scratch interface

`wqfpga_dma.ko` binds to Corundum application ID `0x12348001` and exposes
`/dev/wqfpga0`. `pread` copies bytes from the FPGA application's scratch RAM
to a userspace buffer; `pwrite` copies in the other direction. The file offset
is a byte offset in card RAM. A shared 8 KiB coherent staging buffer and mutex
make every request bounded and serialized; larger requests are split into 8 KiB
DMA descriptors. Userspace never supplies a DMA address.

The upstream `dma_bench.v` instantiates **16 KiB** of RAM. This prototype only
exposes its low **8 KiB**, pending full-range board validation. Reads stop at
end of window; writes past it return a short count or `ENOSPC`. This module is
also the host interface for the optional moments v1 computation kernel.

## Moments v1 compute call

With a firmware image that exposes the `WQM1` kernel at application register
offset `0x500`, the same device supports the versioned `GET_CAPS` and `EXEC`
ioctls declared in `wqfpga_uapi.h`. `GET_CAPS` reports the application ID,
ABI version, `WQFPGA_FEAT_MOMENTS_V1`, format limits, and kernel version. On
the DMA-only image it reports no moments feature; `EXEC` returns
`EOPNOTSUPP`. Scratch `pread`/`pwrite` keep working on either image.

The `WQFPGA_OP_MOMENTS`/format-v1 input contains 1..1024 consecutive pairs of
little-endian signed 32-bit Q20 values `(x, y)`. Each raw integer must be in
`[-8388608, 8388607]`. The 40-byte output contains five little-endian signed
64-bit raw sums: `sum_x`, `sum_y`, `sum_x2`, `sum_y2`, `sum_xy`. Linear sums
are Q20; squared and cross sums are Q40. No rounding, division, square root,
or saturation is performed in the FPGA. All valid v1 sums fit in signed 64
bits. The user pointers in `struct wqfpga_exec` are never DMA addresses: the
driver copies and validates all input, stages at most 8 KiB per DMA descriptor,
holds its mutex from first host-to-card transfer through kernel completion and
result collection, then copies the result to userspace. The calculation uses
the low 8 KiB of the same card RAM as the scratch interface, so scratch
accesses by other processes are serialized during an `EXEC` call.

Run `./wqfpga-moments-test --self-test` without hardware to check the CPU
reference and byte order. With the moments firmware loaded, run
`./wqfpga-moments-test /dev/wqfpga0`; it compares all five outputs exactly for
1, 2, 3, 8, 9, 63, 64, 65, 257, 511, 512 and 1024 pairs, including signed
range extrema and 64-byte RAM-row crossings. It also checks invalid counts,
lengths, capacity, out-of-range values, unsupported operation/versions and
nonzero reserved fields. Exit code 77 means `GET_CAPS` found the DMA-only
firmware. This is a synchronous
single-job ABI; later queue work can retain the opcode/format and add job IDs,
per-client limits and driver-owned buffer handles.

`./wqfpga-moments-test --benchmark /dev/wqfpga0` is a separate measurement
mode. After five warmups, it makes 200 `EXEC` calls each for 20 pairs (160
input bytes, one DMA descriptor) and 1024 pairs (8192 bytes, one descriptor),
checking exact output on every call. It reports p50/p99 microseconds measured
around the whole ioctl, including input/output copies, DMA and kernel wait.
It also reports p50/p99 for the same integer arithmetic on the CPU, amortized
over 1000 or 100 repetitions per sample respectively. That CPU number covers
arithmetic only, so the two rows are context rather than a speedup claim.

`python3 moments_vol20_demo.py --self-test` connects this first kernel to
WolfQuant's current `vol20` definition without hardware or third-party Python
packages. The real call is `python3 moments_vol20_demo.py --device
/dev/wqfpga0`; optionally add `--closes-json closes.json`, where the file is
a JSON array of exactly 21 positive, finite **completed** closes ordered
oldest first. The script computes `np.diff(closes)/closes[:-1]` and the
population standard deviation (`ddof=0`) times `sqrt(252)` using equivalent
standard-library Python arithmetic. It Q20-encodes the 20 returns as `(x, 0)`
pairs, checks all five integer moments exactly, reconstructs vol20 from
`sum_x`/`sum_x2`, and prints the original value, quantized value, and absolute
error. Its `ctypes` request structures assert the 64/96-byte UAPI layout. The
example does not select a strategy or change a trade: near a filter threshold,
the original CPU calculation remains the final decision input.

## Build (Ubuntu host with matching kernel headers)

Place this directory beside the patched `mqnic/` module source and build both
for the **running** kernel. `../mqnic/Module.symvers` is required by Kbuild.

```sh
cd ~/corundum/modules/mqnic && make
cd ../wqfpga_dma && make
modinfo ./wqfpga_dma.ko | grep vermagic
make test  # software-only tag and moments reference tests
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
the entire FPGA function, rejects further I/O, and quarantines its 8 KiB DMA
buffer and mapping instead of freeing memory that the card might still access.
This also stops mqnic networking on that function. Power-cycle or reset the
FPGA before rebooting the Linux host. A failed run is never a successful DMA
test, even if an earlier chunk completed.
