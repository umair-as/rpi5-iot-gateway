# U-Boot TPM Enablement (RPi5 + SLB9672)

## Status: Parked (2026-04-01)

U-Boot TPM on RPi5 is **not viable with current upstream**.
TPM operations are deferred to Linux (`tpm_tis_spi` + `tpm-ops` CLI).

## Goal
- U-Boot detects and binds TPM on SPI via PCIe → RP1 → SPI path.
- `tpm2` commands work in U-Boot shell (`init`, `startup`, `get_capability`).
- FIT measured-boot can build on a working TPM device path.

## Implementation in This Repo
- Kconfig fragment: `meta-iot-gateway/recipes-bsp/u-boot/files/iotgw-uboot-tpm.cfg`
- Conditional wiring: `meta-iot-gateway/recipes-bsp/u-boot/u-boot_%.bbappend`
- Gate variable: `IOTGW_ENABLE_TPM_SLB9672 = "1"` (via `kas/tpm.yml`)

## Kconfig Symbols
```
CONFIG_PCI_INIT_R=n          # Crashes on BCM2712 — see findings below
CONFIG_USB_XHCI_PCI=n        # Also triggers PCIe probe crash
CONFIG_SPI=y
CONFIG_DM_SPI=y
CONFIG_DESIGNWARE_SPI=y
CONFIG_TPM=y / CONFIG_TPM_V2=y
CONFIG_CMD_TPM=y / CONFIG_CMD_TPM_V2=y
CONFIG_TPM2_TIS_SPI=y
```

`CONFIG_PCI=y` and `CONFIG_PCI_BRCMSTB=y` come from `rpi_arm64_defconfig`.

## Build & Deploy
```bash
kas shell kas/local.yml:kas/tpm.yml -c "bitbake u-boot"
# Verify
grep -E 'PCI_INIT_R|USB_XHCI_PCI|TPM2_TIS_SPI' \
  build/tmp-glibc/work/raspberrypi5-oe-linux/u-boot/2025.04/build/.config
```

## Findings

### DT Confirmed Correct
Both control FDT (`fdtcontroladdr`) and firmware FDT (`fdt_addr`) contain:
```
/axi/pcie@1000120000             compatible = "brcm,bcm2712-pcie"
  /rp1_nexus                     compatible = "pci1de4,1"
    /pci-ep-bus@1                compatible = "simple-bus"
      /spi@40050000              compatible = "snps,dw-apb-ssi"  status = "okay"
        /tpm@1                   compatible = "infineon,slb9670", "tcg,tpm_tis-spi"
                                 reg = <1>  spi-max-frequency = 32MHz  status = "okay"
```

### DM Never Reaches TPM
- `axi` simple_bus: bound but **not probed** — zero children in `dm tree`
- `pcie_brcm`, `dw_spi`, `tpm_tis_spi` drivers compiled in but 0 devices bound
- `pci enum` at U-Boot prompt has no effect
- `tpm2 init` → `Couldn't set TPM 0 (rc = 1)`

### CONFIG_PCI_INIT_R Crash
Enabling auto PCI init causes SError abort during boot:
```
"Error" handler, esr 0xbe000011    # asynchronous external abort
```
`CONFIG_USB_XHCI_PCI=y` triggers the same crash via USB init probing PCI.

### Root Cause: Missing U-Boot Driver Chain
`pcie_brcmstb` already has `brcm,bcm2712-pcie` compatible (upstream 2025.04,
line 559), but treats BCM2712 identically to BCM2711.  BCM2712 requires:

| Missing Piece | Detail |
|---------------|--------|
| BCM2712 PCIe init | PHY PLL for 54MHz xosc, BCM7712 register offsets, PERST# 7278-variant, RESCAL quirk |
| RP1 MFD driver | No U-Boot driver for `pci1de4,1` (RP1 PCI endpoint) |
| RP1 SPI driver | No driver to expose DesignWare SPI behind RP1 BAR |

## Upstream Patch Status
- **EPAM / xen-troops** (Oleksii Moisieiev, Feb 2025): 20-patch RFC —
  PCIe + RP1 MFD + GPIO + clocks + Ethernet.  BAR ordering HACK.
  No SPI.  Not merged.  Fork: `xen-troops/u-boot` branch `2024.04-xt`.
  https://lists.denx.de/pipermail/u-boot/2025-February/579540.html
- **SUSE** (Torsten Duwe, Oct 2025): 3-part series, only Part 1 (fixes)
  posted.  Parts 2-3 (PCIe + RP1) not yet submitted.  No SPI.
  https://lore.kernel.org/u-boot/20251010161442.410C4227AAE@verein.lst.de/
- **Neither series includes an RP1 SPI driver.**

## Recommended Alternative
1. **Linux TPM** — kernel `tpm_tis_spi` + `tpm-ops` CLI works today.
2. **BCM2712 OTP secure boot** — closes EEPROM → U-Boot trust gap
   via signed `boot.img` verified by silicon BootROM.
3. **Initramfs TPM** — PCR extend, LUKS unseal, attestation from initramfs.

## When to Revisit
- SUSE parts 2+3 merged upstream (PCIe + RP1)
- Any U-Boot fork gains RP1 SPI support
- Monitor `lore.kernel.org/u-boot` for `bcm2712` or `rp1`
