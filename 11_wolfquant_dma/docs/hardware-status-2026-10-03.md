# Hardware status — 2026-10-03 (America/New_York)

The Linux host at `192.168.1.253` is online with its cooling fans running,
but no FPGA PCIe endpoint is enumerated. The independent FPGA outlet is on
(roughly 23–29 W). Windows `jtagconfig` still sees `Microsoft Catapult (64)
[USB-0]` and `1SG280HH`, yet both the moments SOF and the known Golden SOF
fail during Quartus programming with errors 18950 (“Device has stopped
receiving configuration data”), 18948 (“Device is in configuration state”),
and 209012. Golden has **not** been verified after these failures.

The temperature monitor sometimes reports `-8388607.99609375°C` after a
programming attempt. This is an invalid sensor reading, not an extremely cold
device. The web dashboard rejects it and disables the hardware test button.

Recovery attempts already made:

1. Rechecked the JTAG chain and known Golden SOF checksum; the device remains
   visible, and the SOF file matches its recorded hash.
2. Cycled only the FPGA outlet twice, including a 30-second off interval.
3. Turned the FPGA outlet off, rebooted the Linux host so PCIe slot power also
   cycled, waited for SSH to return, and turned the FPGA outlet back on. The
   temperature briefly returned to about 35°C. A new Golden programming
   attempt failed with the same Quartus errors, and the sensor became invalid
   again.

No exact FPGA result was generated on this date. The dashboard shows a
CPU-only reference and explicitly labels the separate 2026-10-02 FPGA replay
as historical. Do not treat a software self-test or the historical result as
a current hardware pass.

Next diagnostics should inspect the board's configuration status pins,
configuration and auxiliary power rails, and JTAG signal integrity before
repeating software programming. Intel's [Stratix 10 Configuration User
Guide](https://www.intel.com/programmable/technical-pdfs/683762.pdf) describes
the configuration-state signals and expected power/clock conditions.
