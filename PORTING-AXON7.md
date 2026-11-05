# Port to the ZTE Axon 7 (A2017G, `ailsa_ii`)

Status (2026-11-05): **iOS 16.7.16 boots to the lock screen and home screen
on the Axon 7, GPU-accelerated, unlocks with Volume Down (Home), touch works,
rootless jailbreak with Sileo pre-installed.** Wi-Fi joins WPA2-PSK
networks; internet worked once (0191, until a firmware crash) and not
with 0192 (no DHCP address); 0193 is under test (see To do).

| Area | State on the Axon 7 |
| --- | --- |
| Boot | ZTE LK -> shim (boot partition, written from TWRP; no `fastboot boot`) -> XNU, ~10 s to launchd |
| Display | split-DSI panel driven as one 1440x2560 surface, GPU scaling from the iPhone 8 750x1334 canvas |
| GPU | Adreno 530 via Mesa freedreno (`sweetgl.dylib`, built by `.github/workflows/sweetgl.yml`), 400 MHz default (600 tested, warm) |
| Clocks | DDR 1804 MHz, CPU 1228/1363 MHz (`sweetddr=1804`, `sweetclk` on) |
| Storage | iOS root = journaled HFS+ in `userdata`, read-write |
| Touch / keys | Synaptics RMI4 F12 (1439x2559, IRQ), Power, Volume Up, Volume Down = Home |
| Wi-Fi | QCA6174 with the phone's own firmware (HTT 3.28): scan, WPA2-PSK join (4/4 on the management path), DHCP + Safari once (0191, firmware crash under load), no DHCP with 0192, 0193 testing |
| Jailbreak | Procursus rootless bootstrap (`/var/jb`, CF 1900) + Sileo 2.5.1, set up on first boot by a launchd job |
| Shutdown | power off / restart through PSCI with PMIC PS_HOLD config (patch 0190) |

Hardware reference for the phone: https://github.com/devilAPI/zte-axon7 (`docs/`).

Same SoC family as the Pixel 1 (MSM8996 v3 = Snapdragon 820, Pixel 1 is the 821
"pro" bin). Most of the Pixel port carries over. The table lists every
difference found in the Axon 7's live device tree (TWRP 3.3.0-0, downstream
3.18 kernel) and what the port has to change.

| Area | Pixel 1 (sailfish) | Axon 7 (ailsa_ii) | Change needed |
| --- | --- | --- | --- |
| Bootloader | LK, `fastboot boot`, Image.gz + appended DTB | ZTE LK, v0 header, page 4096, Image.gz + 1 appended DTB, kernel at 0x80080000, DTB at 0x82400000, EL1. **No `fastboot boot`** | test images go to the `boot` partition from TWRP (`tools/axon7-cycle.sh`); shims reset to recovery via IMEM |
| APSS watchdog | 0x9830000, left running by LK | same address, left **disabled** by LK | none |
| RAM (upper bank) | 0x1_00000000 + 0x7e550000 | 0x1_00000000 + 0x7e4c0000 | ADT `mem_size` |
| GIC | 0x9bc0000 / 0x9c00000, stride 0x40000 | same | none |
| UFS | 0x624000 | same | none |
| IMEM restart reason | 0x066bf65c | same | none |
| pstore | 1 MiB at 0x83500000, console zone at 0x83540000 | 4 MiB at 0xbfc00000: 1 MiB dump records, console 0xbfd00000, ftrace 0xbfe00000, pmsg 0xbff00000. **ZTE LK writes its own boot log into the console zone** | use the pmsg zone (or dump record 0); shim pstore.c, xnu sweet_early.c, panic-to-pstore |
| Display | 1080x1920 Samsung, single DSI0, command mode, VIG0 -> LM0 -> CTL0 -> INTF1 | 1440x2560 Samsung (`zte_samsung_5p5_wqhd_dualmipi_cmd`), **split DSI0 + DSI1**, command mode: one RGB888 buffer at 0x83401000, VIG0 (left) + VIG1 (right) on CTL0/CTL1; CTL0 START sends both halves | shim console, fbcon flip/blank for VIG1/CTL1 (patch 0185), GPU panel buffers 16 MiB (0186) |
| Touch | Synaptics S3708 RMI4 @0x20, BLSP1 QUP3 (0x7577000), SDA/SCL 47/48, I2C mux GPIO 80 | Synaptics DSX RMI4 @0x20, **BLSP2 QUP6 (0x75ba000, blsp_i2c12), SDA/SCL 87/88**, no mux, reset 89, IRQ 125 (same) | QUP base, GCC branch/vote bits, pins, rails L14 1.8 V (vdd_ana) + L22 3.3 V (vcc_i2c), coordinates 1440x2560 |
| Home button | none (volume down = Home) | **capacitive keys on the touch IC** (`cap-button-codes` back/home/menu = RMI4 F1A) | F1A home key -> HID Home; keep volume down = Home as fallback |
| Volume keys | TLMM 126 / 121 | **PM8994 GPIO 2 (up) / 3 (down)**, active low | read the PMIC GPIO RT_STS (+0x10) over SPMI instead of TLMM (patch 0188) |
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

## Axon 7 kernel patches

| Patch | What |
| --- | --- |
| 0184 | early log in the pmsg ramoops zone (0xbff00000) |
| 0185 | split display: VIG1/CTL1 flush, LM1 blank, wait for PP0 + PP1 |
| 0186 | GPU panel buffers 16 MiB at 0xc1000000 / 0xc2000000 |
| 0187 | touch on BLSP2 QUP6, rails L14/L22, 1440x2560 |
| 0188 | volume keys on PM8994 GPIO 2/3 |
| 0189 | Wi-Fi: answer a repeated EAPOL 3/4 before installing keys |
| 0190 | power off / restart: UFS cache flush, PM8994 PS_HOLD type, PSCI SYSTEM_OFF/RESET |
| 0191 | Wi-Fi: EAPOL 4/4 resent on the management path when the data path stalls (the AP takes it: connects) |
| 0192 | Wi-Fi: tx msdu ids tracked per slot (never reuse one the firmware holds), rx ring refilled by buffer address (out-of-order release), 4/4 only on the management path, firmware crash dump (`hi_failure_state`): 4/4 taken on the first try and no crash in 20 min, but DHCP never finished |
| 0193 | Wi-Fi: 4/4 on the data path again before the management-path copy (0191 order); diagnostics: tx completion status counts, rx to us vs group, DHCP packets (testing) |

Boot-args in use (`research/axon7/bootargs-*.txt`, 418 of 608 bytes):

```
debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress sweetusb=0 rd=ufsroot0
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1
rootrw=1 launchd_unsecure_cache=1 wdt=-1 cs_enforcement_disable=1
sweetnull=backboardd sweetcharge=0 sweetprof=- sweetsample=- sweetfb_noconsole=1
sweetgpu=8 sweetenv=backboardd:DYLD_INSERT_LIBRARIES=/usr/lib/sweetgl.dylib
sweetddr=1804 sweetgpuclk=400 sailfishwlan=1
```

## Tools (Linux host)

| Tool | What |
| --- | --- |
| `shim/build-axon7.sh` | shim with clang/lld (probe or loader) |
| `tools/axon7-cycle.sh KERNEL NAME ARGS` | ADT + payload (GPU and Wi-Fi blobs) + shim, write `boot` from TWRP, reboot, wait for TWRP, save pstore |
| `tools/axon7-mkroot.sh` | iOS root image from the IPSW (`mkiosroot.sh` + `sweet-root-tweaks.py` + stock apps) |
| `tools/axon7-flashroot.sh` | write the root to `userdata`: compressed full write, or only changed 1 MiB chunks |
| `tools/axon7-pullroot.sh` | bring the local image up to date with the phone (4 MiB chunk hashes), `--allow-dirty` |
| `tools/hfs-journal-replay.py` | replay an HFS+ journal like XNU (Linux fsck does not) |
| `tools/hfs-btree-fix.py` | fix B-tree extents XNU refuses (Linux hfsplus leaves odd ones) |
| `tools/axon7-root-add.sh` | install files into the root (sudo loop mount) |
| `tools/axon7-jailbreak.sh` | Procursus bootstrap + Sileo + first-boot launchd job (`axon7-jbinit.sh`) |
| `tools/sweet-log-pull.sh` | kernel log ring from the end of `userdata` |

Root editing cycle: `axon7-pullroot.sh` (phone in TWRP) -> edit with
`axon7-root-add.sh` / `axon7-jailbreak.sh` -> `axon7-flashroot.sh` (delta, seconds).
Shut iOS down with "slide to power off" when possible; after a forced reset
pull with `--allow-dirty` and replay the journal first.

## To do

- **Wi-Fi**: firmware (own `qwlan30.bin`, HTT 3.28, OTP board id 0 -> `bdwlan30.bin`), PCIe INTA (SPI 244), scan, auth, assoc, 4-way handshake and traffic work. EAPOL 4/4 on the data path never completes and the AP never takes it (50 tries); the same frame on the management path (ext tid 17) it takes (0191, 0192). With 0191 the firmware crashed (`fw_ind` 0x3, CE 4 stuck) after ~850 tx / 1300 rx frames; 0192 fixes two host bugs that can do that (msdu id reuse, rx ring buffers handed back while the firmware still held them) and prints the firmware's crash dump if it happens again. With 0192 (4/4 only on the management path) the link stayed up 20 min without a crash and broadcasts arrived, but iOS never got a DHCP address; 0191 (data-path 4/4 first, held by the firmware until the keys were in) had a working data path, so 0193 restores that order and logs the data path. Open: restart the firmware and rejoin after a crash instead of staying offline.
- **Logs**: the log ring restarts at offset 0 every boot; bytes past the current boot's `total` in `*-ring.txt.bin` are the tail of the previous, longer boot (the 0191 Wi-Fi result was found there).
- **Dual boot with postmarketOS**: pmOS rootfs on microSD; a shim boot menu (volume key) to start either XNU or Linux.
- **Dynamic GPU clock**: 600 MHz only while animating (600 fixed runs warm; the driver has 300/400/600 only, 510/560 need mmpll9).
- **Brightness**: the DCS 0x51 write over DSI0 never completes on the split-DSI panel ("panel level ... FAILED"); likely needs the broadcast setup of both DSI controllers.
- **Capacitive keys**: Back/Home/Menu under the screen (downstream `gen-vkeys` / `cap-button-codes`); the RMI4 scan finds only F01/F12/F34, so they are probably virtual keys below the 2560-pixel area. Map the Home key.
- **Battery**: `SWEET BATTERY: PMIC read failed at step 1` at boot (PMI8996 fuel gauge differs from the Pixel's PMI8994); charging via the external SMB1351 is untouched (`sweetcharge=0`).
- **Performance**: raise CPU clocks (820 speed bins vs the Pixel's 821 tables), DDR 1804 MHz, GPU 400/600 MHz; tame the first-boot widget-extension storm.

## Milestones

1. ~~Probe shim: entry state, LK's split-DSI MDP setup, a working pstore zone, reset to recovery.~~ Done.
2. ~~Loader shim + kernel with an Axon 7 ADT: XNU early boot log in pstore.~~ Done (panic in libfirehose, fixed).
3. ~~Kernel: pstore, framebuffer (split DSI), UFS root -> launchd.~~ Done.
4. ~~Touch, keys -> SpringBoard usable.~~ Done: lock screen, unlock with Volume Down (Home), touch works. Battery open.
5. GPU (sweetgl): ~~running~~ (Mesa freedreno, GPU present; sweetgl built by `.github/workflows/sweetgl.yml`). Performance and Wi-Fi open.
