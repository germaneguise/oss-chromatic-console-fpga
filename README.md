# Chromatic FPGA
This repository houses the ModRetro Chromatic's FPGA design files.

For more information about the ModRetro Chromatic, please see visit [ModRetro.com](https://modretro.com/).

## Setup

### Repository

This project builds upon the open source work provided by the Game Boy `MiSTer` project. When checking out this repository, make sure to run the following command as this repository submodules the Game Boy `MiSTer` project.

```bash
git submodule update --init --recursive
```

### Gowin Development Environment

**The Gowin FPGA Designer v1.9.9.03 must be used.** Using Gowin IDE v1.9.10.X or newer is currently not supported by this build.

You will also need to apply for a local license with Gowin through their website:
https://www.gowinsemi.com/en/support/license

The license expires after one year and will require reactivation.

You will receive an email within a few minutes with a `.lic` file attached. Run the Gowin IDE and install the license when it prompts you. You'll need to close and re-open the GOWIN IDE if everything was successful.

## Building
Once in the IDE, load `evt1_x2.gprj` project and click on the green recycle-like button icon to run synthesis and PnR. This will take about 5-10 minutes to complete.

### Command-line build (gw_sh)
The same design builds headless with Gowin's `gw_sh`, which is how release images are produced:

```bash
git submodule update --init --recursive      # Gameboy_MiSTer
cd esp32t
gw_sh build_evt1_x2.tcl                      # ~25-30 min; outputs impl/pnr/evt1_x2_v07.fs and .bin
```

The script stamps the bitstream's 32-bit USERCODE with the short hash of the source commit (`git rev-parse --short=8 HEAD`), so a bitstream file, a flash dump, or a flash-booted board (`programmer_cli --run 0` reads it back) can be traced to the exact source. Build from a clean, committed tree, otherwise the script warns and the hash does not identify the bitstream exactly. The IDE flow keeps the static USERCODE from `impl/evt1_x2_process_config.json`.

### Packaging a release image (pack.py)
`esp32t/tools/pack.py` turns a bitstream into the 1 MiB config-flash image that carries its own provenance - a plaintext `CHRM` record in the last sector with the commit, build time, release tag, the bitstream's length / CRC-32 / sha256 and a source URL - plus a manifest for the release page:

```bash
python tools/pack.py pack --bitstream impl/pnr/evt1_x2_v07.bin --out chromatic-<tag>.flash --tag <tag>
python tools/pack.py verify --image chromatic-<tag>.flash        # also works on a flash dump
```

Use the `.flash` extension for the image; `.bin` is the MCU firmware. Always flash the whole image (see below) so the record and the bitstream stay in lockstep. On a board running the bridge firmware (`oss-chromatic-console-mcu`), `fpgaflash verify` over the USB console measures the bitstream in flash and compares it with the record; `fpgaflash blob` prints the record.

## Flashing
Flashing can be performed using the official [Gowin Programmer](https://www.gowinsemi.com/en/) software or the [`openFPGALoader`](https://github.com/trabucayre/openFPGALoader) utility through the Chromatic's USB interface. The Gowin Programmer requires the installation of the GWU2X device driver.

Note:
1. The Chromatic must be powered on for either tool to detect the FPGA. This means the power switch is in the **ON** position.
2. If using `openFPGALoader`, the tool must be compiled with support for the Gowin GWU2X cable.

### Example Using `openFPGALoader`
**Detect the Chromatic FPGA While Powered On**
```bash
openFPGALoader --detect --cable gwu2x
```

You will see an output similar to:
```
empty
User requested: 6000000 real frequency is 6000000
index 0:
        idcode 0x1281b
        manufacturer Gowin
        family GW5A
        model  GW5A-25
        irlength 8
```

**Flashing the Chromatic**

```bash
openFPGALoader --write-flash --cable gwu2x --reset <file>
```

Here, `<file>` refers to the generated bitstream file. This file can be found at `esp32t/impl/pnr/evt1_x2.fs`.

**Flashing a packed release image**

A `.flash` image from `pack.py` (see Building) is written as a whole, including its provenance record:

```bash
openFPGALoader -c gwu2x -f --external-flash --file-type bin chromatic-<tag>.flash
```

`--file-type bin` is needed because the loader guesses the format from the extension. Writing a bare `.fs` instead leaves whatever was in the record sector behind, and `fpgaflash verify` will then report a stale record - flash the whole image. JTAG flash writes erase the SRAM configuration; power-cycle (or `openFPGALoader -c gwu2x -r`) to boot the new image. For a test load that does not touch flash, load the `.fs` into SRAM without `-f`; note that an SRAM load carries neither the record nor the USERCODE.

## Custom Modifications

When modifying the RTL design, please also update the 14-bit FPGA version within [esp32t/src/rtl/BSP/system_monitor.sv] around line 384 (see `version`).

This will ensure you can always using the [ModRetro Update Tool](https://modretro.com/pages/downloads#mrupdater) to restore your Chromatic to the latest official release.

## Issues
Please submit all issues and bug reports through our [Contact Form](https://modretro.com/pages/contact).

## Attributions
- [GOWIN Semiconductor](https://www.gowinsemi.com/en/)
- [MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer)

## Special Thanks
- [rayjt9] For their palette improvements to the BootROM.
