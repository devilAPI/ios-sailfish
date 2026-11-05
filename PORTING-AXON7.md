# Port to the ZTE Axon 7 (A2017G, `ailsa_ii`)

Status: bring-up, milestone 1 (probe shim). Nothing iOS boots on the Axon 7 yet.

Same SoC family as the Pixel 1 (MSM8996 v3 = Snapdragon 820, Pixel 1 is the 821
"pro" bin). Most of the Pixel port carries over. The table lists every
difference found in the Axon 7's live device tree (TWRP 3.3.0-0, downstream
3.18 kernel) and what the port has to change.

| Area | Pixel 1 (sailfish) | Axon 7 (ailsa_ii) | Change needed |
| --- | --- | --- | --- |
| Bootloader | LK, `fastboot boot`, Image.gz + appended DTB | ZTE LK, v0 header, page 4096, Image.gz + 1 appended DTB | probe: confirm `fastboot boot`, load address, DTB address |
| RAM (upper bank) | 0x1_00000000 + 0x7e550000 | 0x1_00000000 + 0x7e4c0000 | ADT `mem_size` |
| GIC | 0x9bc0000 / 0x9c00000, stride 0x40000 | same | none |
| UFS | 0x624000 | same | none |
| APSS watchdog | 0x9830000 | same | none |
| IMEM restart reason | 0x066bf65c | same | none |
| pstore | 1 MiB at 0x83500000, console zone at 0x83540000 | 4 MiB at 0xbfc00000: 1 MiB dump records, console 0xbfd00000, ftrace 0xbfe00000, pmsg 0xbff00000. **ZTE LK writes its own boot log into the console zone** | use the pmsg zone (or dump record 0); shim pstore.c, xnu sweet_early.c, panic-to-pstore |
| Display | 1080x1920 Samsung, single DSI0, command mode, VIG0 -> LM0 -> CTL0 -> INTF1 | 1440x2560 Samsung (`zte_samsung_5p5_wqhd_dualmipi_cmd`), **split DSI0 + DSI1**, command mode, source split | shim console, fbcon flip/blank (two halves / LMs), DCS brightness on both links, GPU scaler target 1440x2560 |
| Touch | Synaptics S3708 RMI4 @0x20, BLSP1 QUP3 (0x7577000), SDA/SCL 47/48, I2C mux GPIO 80 | Synaptics DSX RMI4 @0x20, **BLSP2 QUP6 (0x75ba000, blsp_i2c12), SDA/SCL 87/88**, no mux, reset 89, IRQ 125 (same) | QUP base, GCC branch/vote bits, pins, rails L14 1.8 V (vdd_ana) + L22 3.3 V (vcc_i2c), coordinates 1440x2560 |
| Home button | none (volume down = Home) | **capacitive keys on the touch IC** (`cap-button-codes` back/home/menu = RMI4 F1A) | F1A home key -> HID Home; keep volume down = Home as fallback |
| Volume keys | TLMM 126 / 121 | **PM8994 GPIO 2 (up) / 3 (down)**, active low | read PMIC GPIO STATUS1 over SPMI instead of TLMM |
| Power key | PM8994 PON KPDPWR | same | none |
| Wi-Fi | QCA6174 on PCIe RC0, PERST 35, bootstrap 46, wlan_en PM8994 GPIO 8, rome_vreg GPIO 9, S3/S4/L30 | same, plus antenna switch L18 | board data: Axon 7 ships bdwlan30.bin + .b01..b1c (pass the matching `WLAN-BDF-xx`) |
| Charger / gauge | PMI8994 internal charger | PMI8996 + **external SMB1351 on I2C 0x75b5000** | keep the Pixel charger setup off until checked |
| CPU | 821: 2 x 1.59 + 2 x 2.15 GHz | 820 v3: 2 x 1.59 + 2 x 2.15 GHz; different PLL/voltage bins | keep boost/turbo off; verify sweet_perf tables |
| GPU firmware | a530_pm4/pfp, zap .mdt/.b02 | same files, from `/vendor/firmware` (zap has .b00-.b02) | none |

## Firmware (from the phone, never committed)

`research/firmware/gpu/`: a530_pm4.fw, a530_pfp.fw, a530_zap.mdt, a530_zap.b00-.b02 (vendor partition)
`research/firmware/wlan/`: otp30.bin, qwlan30.bin, bdwlan30.bin, bdwlan30.b01-.b1c (modem partition `image/`)

## Build host

Linux. The shim builds with clang/lld (`shim/build-axon7.sh`). The kernel builds
on GitHub's macOS runners (`.github/workflows/xnu.yml`, fork devilAPI/ios-sailfish,
branch `axon7`). The iOS root uses `tools/mkiosroot.sh` (needs apfs-fuse, hfsprogs, root).

## Milestones

1. Probe shim: entry state, LK's split-DSI MDP setup, a working pstore zone, reset to recovery.
2. Loader shim + the unmodified Pixel kernel with an Axon 7 ADT: XNU early boot log in pstore.
3. Kernel: pstore, framebuffer (split DSI), UFS root -> launchd.
4. Touch, keys, battery -> SpringBoard usable.
5. GPU (sweetgl), Wi-Fi.
