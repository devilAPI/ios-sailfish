/*
 * ZTE Axon 7 (ailsa_ii, MSM8996 v3) loader shim, from pixel.c. Screen: the
 * ZTE LK splash (two VIG pipes over one 1440x2560 RGB888 buffer, split
 * command-mode DSI), see console.c. Progress goes to the pmsg ramoops zone;
 * every reset is sent to recovery (IMEM restart reason), so read it in TWRP:
 *   adb shell cat /sys/fs/pstore/pmsg-ramoops-0
 */
#include <stdint.h>
#include "console.h"
#include "loader.h"
#include "pstore.h"
#include "pmic.h"
#include "pmos.h"
#include "android.h"
#include "ufsr.h"

#define PSCI_SYSTEM_RESET	0x84000009UL
#define IMEM_RESTART_REASON	0x066bf65cUL
#define RESTART_RECOVERY	0x77665502U
#define APSS_WDT		0x9830000UL	/* qcom,wdt@9830000, 32768 Hz ticks */
#define WDT_RST			0x04
#define WDT_EN			0x08
#define WDT_BARK		0x10
#define WDT_BITE		0x14

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })

static inline uint32_t rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

static void __attribute__((noreturn)) psci_reset(void)
{
	/* any reset from here lands in TWRP, which shows the pmsg zone */
	*(volatile uint32_t *)IMEM_RESTART_REASON = RESTART_RECOVERY;
	register uint64_t x0 __asm__("x0") = PSCI_SYSTEM_RESET;
	__asm__ volatile("dsb sy; smc #0" : "+r"(x0) : : "memory");
	for (;;)
		__asm__ volatile("wfe");
}

static void delay_ms(unsigned ms)
{
	uint64_t end = rsr("cntpct_el0") + rsr("cntfrq_el0") / 1000 * ms;
	while (rsr("cntpct_el0") < end)
		;
}

/*
 * The payload (tools/mkpayload.py) is appended to this Image at _end by
 * build-axon7.sh: ZTE LK decompresses the kernel to 0x80080000 and puts the
 * DTB at 0x82400000 (probe 1), so the Image + payload must stay below ~35 MB.
 */
#define TAGS_ADDR	0x82400000UL	/* where ZTE LK puts the DTB (probe 1) */
/*
 * postmarketOS bundle copy: free RAM in mainline's msm8996 map (reserved
 * memory ends below 0x92000000, ramoops at 0xbfc00000), clear of the shim,
 * the XNU payload and LK's DTB; iOS reuses it as ordinary memory.
 */
#define PMOS_STASH	0xa0000000UL

extern char _end[];

/*
 * Dual boot menu: Vol+/Vol- move the highlight, Power starts the entry.
 * Keys count only after they were seen released, so the power-on press (or
 * a key still held from the ZTE logo) does nothing. With no key pressed iOS
 * starts after MENU_SECS. Entries: iOS (XNU payload), postmarketOS (bundle
 * in the ramdisk slot, pmos.c), LineageOS (Android boot image in the
 * los_boot partition, android.c). A failed start shows why and returns
 * to the menu. Holding Volume Down at power-on is not used: ZTE LK takes
 * that itself (FTM mode) before this code runs.
 */
#ifndef MENU_SECS
#define MENU_SECS	10
#endif
#define POLL_MS		20

enum { MENU_IOS, MENU_PMOS, MENU_LOS, MENU_N };
static const char menu_names[MENU_N][16] = { "iOS", "postmarketOS", "LineageOS" };	/* no pointers: no ABS64 relocs */

static void menu_draw(int top, int sel, const char *status)
{
	for (int i = 0; i < MENU_N; i++) {
		char line[24] = "  ";
		const char *n = menu_names[i];
		int j = 2;
		if (i == sel)
			line[0] = '>';
		while (*n && j < (int)sizeof(line) - 1)
			line[j++] = *n++;
		line[j] = 0;
		con_line(top + i, "", line, i == sel ? GREEN : WHITE);
	}
	con_line(top + MENU_N + 1, "", status, YELLOW);
	con_flush();
}

/*
 * Stored default (tools: axon7-bootmenu): the last 4 KiB block of `misc`
 * (LUN 0, writable from every OS; Android uses only its first 64 KiB):
 * "AX7BOOT1", u32 entry, u32 countdown seconds (0: MENU_SECS), u32 entry ^
 * 0xa5a5a5a5. Read-only here; without it the menu defaults to iOS.
 */
static uint8_t cfg_blk[4096] __attribute__((aligned(4096)));

static int boot_setting(int *secs)
{
	struct ufsr_part p;
	int entry = -1;
	if (ufsr_open() == 0 && ufsr_find("misc", &p) == 0 && p.blocks &&
	    ufsr_read(p.lun, p.first + p.blocks - 1, 1, (uintptr_t)cfg_blk) == 0) {
		static const char magic[8] = { 'A', 'X', '7', 'B', 'O', 'O', 'T', '1' };
		uint32_t e = 0, t = 0, c = 0;
		int ok = 1;
		for (int i = 0; i < 8; i++)
			ok &= cfg_blk[i] == (uint8_t)magic[i];
		for (int i = 3; i >= 0; i--) {
			e = e << 8 | cfg_blk[8 + i];
			t = t << 8 | cfg_blk[12 + i];
			c = c << 8 | cfg_blk[16 + i];
		}
		if (ok && e < MENU_N && c == (e ^ 0xa5a5a5a5u)) {
			entry = (int)e;
			*secs = t && t < 100 ? (int)t : MENU_SECS;
		}
	}
	ufsr_release();
	plog_hex("MENU default", (uint32_t)entry);
	return entry;
}

/*
 * Start entry sel. Returns 1 for iOS (the caller returns to shim_main, which
 * starts the XNU payload); otherwise the entry failed (shown under the menu)
 * and 0 is returned with *sel back on iOS. failed[] blocks a second try (the
 * postmarketOS Image may have been moved, LineageOS staging overwritten).
 */
static int start_entry(uint64_t dtb, int top, int *sel, int failed[MENU_N])
{
	if (*sel == MENU_IOS) {
		plog_str("MENU: iOS\n");
		return 1;
	}
	if (failed[*sel]) {
		menu_draw(top, *sel, "failed before, see below");
		return 0;
	}
	const char *why, *label;
	if (*sel == MENU_LOS) {
		plog_str("MENU: LineageOS\n");
		menu_draw(top, *sel, "starting LineageOS");
		label = "LOS";
		why = android_boot(dtb);
	} else {
		plog_str("MENU: postmarketOS\n");
		menu_draw(top, *sel, "starting postmarketOS");
		label = "PMOS";
		/* the pmos_boot partition first, else the copy LK loaded (pmos_stash) */
		plog_hex("PMOS from partition", (uint32_t)pmos_load_part(PMOS_STASH));
		why = pmos_boot(dtb);
	}
	plog_str(label);
	plog_str(": ");
	plog_str(why);
	plog_str("\n");
	con_line(top + MENU_N + 2, label, why, RED);
	failed[*sel] = 1;
	*sel = MENU_IOS;
	menu_draw(top, *sel, "failed, choose again");
	return 0;
}

static void boot_menu(uint64_t dtb)
{
	static const enum pmic_key keys[3] = { KEY_POWER, KEY_VOLUP, KEY_VOLDOWN };
	int armed[3] = { 0, 0, 0 }, failed[MENU_N] = { 0 }, sel = MENU_IOS, waiting = 1;
	int secs = MENU_SECS, def = boot_setting(&secs);
	if (def >= 0)
		sel = def;
	uint64_t f = rsr("cntfrq_el0"), deadline = rsr("cntpct_el0") + f * (uint64_t)secs;
	char status[40];

	if (pmic_key_pressed(KEY_POWER) < 0 || pmic_key_pressed(KEY_VOLUP) < 0 ||
	    pmic_key_pressed(KEY_VOLDOWN) < 0) {
		plog_str("MENU: keys unreadable, iOS\n");
		con_str("KEYS", "unreadable, booting iOS");
		return;
	}
	con_str("BOOT", "Vol+/Vol- choose, Power starts");
	con_skip();
	int top = con_row();
	for (int i = 0; i < MENU_N + 3; i++)	/* entries, gap, status, error line */
		con_skip();

	for (int last_s = -1;;) {
		uint64_t now = rsr("cntpct_el0");
		if (waiting) {
			int left = now >= deadline ? 0 : (int)((deadline - now + f - 1) / f);
			if (left == 0) {
				/* the default (stored or iOS), as if Power was pressed */
				plog_str("MENU: timeout\n");
				waiting = 0;
				if (start_entry(dtb, top, &sel, failed))
					return;
				continue;
			}
			if (left != last_s) {
				const char *a = sel == MENU_PMOS ? "postmarketOS in " : sel == MENU_LOS ? "LineageOS in " : "iOS in ";
				int j = 0;
				while (*a)
					status[j++] = *a++;
				if (left >= 10)
					status[j++] = (char)('0' + left / 10);
				status[j++] = (char)('0' + left % 10);
				status[j++] = 's';
				status[j] = 0;
				menu_draw(top, sel, status);
				last_s = left;
			}
		}
		for (int k = 0; k < 3; k++) {
			int p = pmic_key_pressed(keys[k]);
			if (p == 0) {
				armed[k] = 1;
				continue;
			}
			if (p != 1 || !armed[k])
				continue;
			armed[k] = 0;	/* one action per press */
			waiting = 0;
			if (keys[k] == KEY_VOLUP) {
				sel = (sel + MENU_N - 1) % MENU_N;
				menu_draw(top, sel, "");
			} else if (keys[k] == KEY_VOLDOWN) {
				sel = (sel + 1) % MENU_N;
				menu_draw(top, sel, "");
			} else if (start_entry(dtb, top, &sel, failed)) {
				return;
			}
		}
		delay_ms(POLL_MS);
	}
}

void shim_main(uint64_t dtb)
{
	/* The bootloader leaves the APSS watchdog running (bite 30 s after entry). */
	uint32_t wdt_en = rd32(APSS_WDT + WDT_EN), wdt_bite = rd32(APSS_WDT + WDT_BITE);
	wr32(APSS_WDT + WDT_EN, 0);
	__asm__ volatile("dsb sy" ::: "memory");

	plog_init();
	plog_str("AXON7 SHIM: loader\n");
	plog_hex("WDT_EN was", wdt_en);
	plog_hex("WDT_BITE", wdt_bite);
	plog_hex("DTB", dtb);
	plog_hex("PAYLOAD", (uintptr_t)_end);

	android_note_lk(dtb);	/* LK's appended bootargs, before anything moves */
	/* before the first pixel: the bundle lies on the framebuffer */
	plog_hex("PMOS stash", (uint32_t)pmos_stash(dtb, PMOS_STASH));

	con_clear(0);
	con_str("SHIM", "axon7 (ailsa_ii) loader");
	con_skip();

	boot_menu(dtb);

	/*
	 * Re-arm the watchdog for the kernel (bite WDT_SECS after this): a hang
	 * then ends in a warm reset that keeps RAM, so the kernel's early log
	 * in the pstore zone (xnu sweet_early.c) can be read from Android.
	 * WDT_SECS=0 (iOS root boots, log in the UFS ring): leave it off.
	 */
#if WDT_SECS
	plog_hex("watchdog re-armed, secs", WDT_SECS);
	wr32(APSS_WDT + WDT_BARK, WDT_SECS * 32768);
	wr32(APSS_WDT + WDT_BITE, WDT_SECS * 32768);
	wr32(APSS_WDT + WDT_RST, 1);
	wr32(APSS_WDT + WDT_EN, 1);
#endif
	const char *why = loader_boot_rd((uintptr_t)_end, TAGS_ADDR);
	plog_str("LOADER: ");
	plog_str(why);
	plog_str("\n");
	con_str("LOADER", why);
	con_str("RESET", "in 15s");
	con_flush();
	delay_ms(15000);
	psci_reset();
}

void secondary_main(uint64_t idx)
{
	(void)idx;
}

void exc_handler(uint64_t slot, uint64_t *regs)
{
	(void)regs;
	plog_hex("EXC slot", slot);
	plog_hex("ESR", rsr("esr_el1"));
	plog_hex("FAR", rsr("far_el1"));
	plog_hex("ELR", rsr("elr_el1"));
	psci_reset();
}
