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

extern char _end[];

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

	con_clear(0);
	con_str("SHIM", "axon7 (ailsa_ii) loader");
	con_skip();
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
