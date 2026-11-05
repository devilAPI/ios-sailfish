/*
 * ZTE Axon 7 (ailsa_ii, MSM8996 v3) bring-up probe, milestone 1.
 *
 * Booted by `fastboot boot` like a Linux Image. It records what the ZTE LK
 * left behind for us and needs nothing else:
 *   - where LK put us (PC), the DTB pointer, CurrentEL, SCTLR, MIDR, MPIDR
 *   - the MDP / DSI register state of the continuous splash (WQHD panel on
 *     two DSI links, command mode, split display)
 * into three ramoops zones (live DT: pstore_mem 4 MiB at 0xbfc00000 =
 * 1 MiB of 32K dump records, 1 MiB console, 1 MiB ftrace, 1 MiB pmsg).
 * ZTE's bootloader writes its own log into the console zone, so the same
 * text also goes to the pmsg zone and to the first dump record. Then it draws
 * a test pattern into every active MDP source pipe, kicks a frame, sets the
 * IMEM restart reason to "recovery" and resets after 20 s. In TWRP:
 *   adb shell cat /sys/fs/pstore/pmsg-ramoops-0 (or dmesg-ramoops-0)
 * MMU off: every access is Device memory, so stay aligned.
 */
#include <stdint.h>
#include "font.h"

#define PSCI_SYSTEM_RESET	0x84000009UL
#define APSS_WDT		0x9830000UL
#define IMEM_RESTART_REASON	0x066bf65cUL
#define RESTART_RECOVERY	0x77665502U

#define PSTORE_BASE		0xbfc00000UL
#define PRZ_SIG			0x43474244U	/* "DBGC" */

#define MDSS			0x900000UL
#define DSI0			0x994000UL
#define DSI1			0x996000UL

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })

static inline uint32_t rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

/* ---- pstore text, mirrored into several zones ---- */
static const struct { uintptr_t base; uint32_t max; } zones[] = {
	{ PSTORE_BASE + 0x300000, 0x100000 - 12 },	/* pmsg */
	{ PSTORE_BASE + 0x100000, 0x100000 - 12 },	/* console */
	{ PSTORE_BASE + 0x000000, 0x8000 - 12 },	/* dump record 0 */
};
#define NZONES (sizeof(zones) / sizeof(zones[0]))
static uint32_t pos;

static void plog_init(void)
{
	pos = 0;
	for (unsigned z = 0; z < NZONES; z++) {
		wr32(zones[z].base + 4, 0);
		wr32(zones[z].base + 8, 0);
		wr32(zones[z].base, PRZ_SIG);
	}
}

static void plog_putc(char c)
{
	for (unsigned z = 0; z < NZONES; z++) {
		if (pos >= zones[z].max)
			continue;
		*(volatile uint8_t *)(zones[z].base + 12 + pos) = c;
		wr32(zones[z].base + 4, pos + 1);
		wr32(zones[z].base + 8, pos + 1);
	}
	pos++;
}

static void plog_str(const char *s)
{
	while (*s)
		plog_putc(*s++);
}

static void plog_hexn(uint64_t v, int digits)
{
	for (int sh = 4 * (digits - 1); sh >= 0; sh -= 4)
		plog_putc("0123456789abcdef"[(v >> sh) & 0xf]);
}

static void plog_hex(const char *label, uint64_t v)
{
	plog_str(label);
	plog_putc(' ');
	plog_hexn(v, v >> 32 ? 16 : 8);
	plog_putc('\n');
}

/* "name addr: w0 w1 ... w7" lines, all-zero lines skipped */
static void dump(const char *name, uintptr_t base, unsigned words)
{
	plog_str("== ");
	plog_str(name);
	plog_putc(' ');
	plog_hexn(base, 8);
	plog_putc('\n');
	for (unsigned i = 0; i < words; i += 8) {
		uint32_t w[8], any = 0;
		for (unsigned j = 0; j < 8; j++)
			any |= w[j] = rd32(base + 4 * (i + j));
		if (!any)
			continue;
		plog_hexn(base + 4 * i, 8);
		plog_putc(':');
		for (unsigned j = 0; j < 8; j++) {
			plog_putc(' ');
			plog_hexn(w[j], 8);
		}
		plog_putc('\n');
	}
}

/* ---- timing / reset ---- */
static void delay_ms(unsigned ms)
{
	uint64_t end = rsr("cntpct_el0") + rsr("cntfrq_el0") / 1000 * ms;
	while (rsr("cntpct_el0") < end)
		;
}

static void __attribute__((noreturn)) psci_reset(void)
{
	register uint64_t x0 __asm__("x0") = PSCI_SYSTEM_RESET;
	__asm__ volatile("dsb sy; smc #0" : "+r"(x0) : : "memory");
	for (;;)
		__asm__ volatile("wfe");
}

/* ---- drawing into a pipe's buffer ---- */
struct surf {
	uintptr_t base;
	uint32_t w, h, stride, bpp;
};

static void put_px(const struct surf *s, uint32_t x, uint32_t y, uint32_t rgb)
{
	if (x >= s->w || y >= s->h)
		return;
	volatile uint8_t *p = (volatile uint8_t *)(s->base + (uintptr_t)y * s->stride + x * s->bpp);
	/* byte order only matters for colour; text stays readable either way */
	p[0] = rgb;
	p[1] = rgb >> 8;
	p[2] = rgb >> 16;
	if (s->bpp == 4)
		p[3] = 0xff;
}

static void put_str(const struct surf *s, uint32_t x0, uint32_t y0, unsigned scale, const char *str, uint32_t fg)
{
	for (; *str; str++, x0 += 8 * scale) {
		char ch = *str < 0x20 || *str > 0x7e ? '?' : *str;
		const unsigned char *g = font8x16[ch - 0x20];
		for (unsigned gy = 0; gy < 16; gy++)
			for (unsigned gx = 0; gx < 8; gx++)
				if (g[gy] & (0x80 >> gx))
					for (unsigned sy = 0; sy < scale; sy++)
						for (unsigned sx = 0; sx < scale; sx++)
							put_px(s, x0 + gx * scale + sx, y0 + gy * scale + sy, fg);
	}
}

static void fill(const struct surf *s, uint32_t rgb)
{
	for (uint32_t y = 0; y < s->h; y++)
		for (uint32_t x = 0; x < s->w; x++)
			put_px(s, x, y, rgb);
}

static const uint32_t pipes[] = {
	0x5000, 0x7000, 0x9000, 0xb000,		/* VIG0-3 */
	0x15000, 0x17000, 0x19000, 0x1b000,	/* RGB0-3 */
	0x25000, 0x27000,			/* DMA0-1 */
};
static const char pipe_names[][6] = {
	"VIG0", "VIG1", "VIG2", "VIG3", "RGB0", "RGB1", "RGB2", "RGB3", "DMA0", "DMA1",
};

extern char _end[];

void shim_main(uint64_t dtb)
{
	uint64_t pc;
	__asm__ volatile("adr %0, ." : "=r"(pc));

	uint32_t wdt_en = rd32(APSS_WDT + 0x08), wdt_bite = rd32(APSS_WDT + 0x14);
	wr32(APSS_WDT + 0x08, 0);
	__asm__ volatile("dsb sy" ::: "memory");

	plog_init();
	plog_str("AXON7 PROBE v1\n");
	plog_hex("PC", pc);
	plog_hex("_end(rel)", (uintptr_t)_end);
	plog_hex("DTB", dtb);
	if (dtb && dtb < 0x200000000UL) {
		plog_hex("DTB magic", rd32(dtb));
		plog_hex("DTB size(be)", rd32(dtb + 4));
	}
	plog_hex("CurrentEL", rsr("CurrentEL"));
	plog_hex("SCTLR_EL1", rsr("sctlr_el1"));
	plog_hex("MIDR", rsr("midr_el1"));
	plog_hex("MPIDR", rsr("mpidr_el1"));
	plog_hex("CNTFRQ", rsr("cntfrq_el0"));
	plog_hex("WDT_EN was", wdt_en);
	plog_hex("WDT_BITE", wdt_bite);
	plog_hex("RESTART_REASON was", rd32(IMEM_RESTART_REASON));

	/* MDP state left by the continuous splash */
	plog_hex("MDSS_HW_VERSION", rd32(MDSS + 0x0));
	plog_hex("MDP_HW_VERSION", rd32(MDSS + 0x1000));
	dump("MDP_TOP", MDSS + 0x1000, 0x100);
	static const char ctl_names[][6] = { "CTL0", "CTL1", "CTL2", "CTL3", "CTL4" };
	for (unsigned i = 0; i < 5; i++)
		dump(ctl_names[i], MDSS + 0x2000 + 0x200 * i, 0x40);
	for (unsigned i = 0; i < 10; i++)
		dump(pipe_names[i], MDSS + pipes[i], 0x40);
	static const uint32_t lms[] = { 0x45000, 0x46000, 0x47000, 0x4a000 };
	static const char lm_names[][6] = { "LM0", "LM1", "LM2", "LM5" };
	for (unsigned i = 0; i < 4; i++)
		dump(lm_names[i], MDSS + lms[i], 0x40);
	static const char pp_names[][6] = { "PP0", "PP1", "PP2", "PP3" };
	for (unsigned i = 0; i < 4; i++)
		dump(pp_names[i], MDSS + 0x71000 + 0x800 * i, 0x40);
	static const char intf_names[][6] = { "INTF0", "INTF1", "INTF2", "INTF3" };
	for (unsigned i = 0; i < 3; i++)	/* INTF3 is HDMI: may be unclocked */
		dump(intf_names[i], MDSS + 0x6b000 + 0x800 * i, 0x80);
	dump("DSI0", DSI0, 0x100);
	dump("DSI1", DSI1, 0x100);
	plog_str("== end of dump\n");

	/* Test pattern into every pipe with a source buffer */
	unsigned drawn = 0;
	for (unsigned i = 0; i < 10; i++) {
		uintptr_t p = MDSS + pipes[i];
		uint32_t size = rd32(p + 0x00), addr = rd32(p + 0x14), ystride = rd32(p + 0x24) & 0xffff;
		uint32_t fmt = rd32(p + 0x30);
		if (!addr || !size || !ystride)
			continue;
		struct surf s = {
			.base = addr, .w = size & 0xffff, .h = size >> 16, .stride = ystride,
			.bpp = ((fmt >> 9) & 3) + 1,
		};
		plog_str("PIPE ");
		plog_str(pipe_names[i]);
		plog_hex(" addr", addr);
		plog_hex("  w", s.w);
		plog_hex("  h", s.h);
		plog_hex("  stride", s.stride);
		plog_hex("  bpp", s.bpp);
		if (s.bpp < 3 || s.w > 4096 || s.h > 4096)
			continue;
		fill(&s, drawn ? 0x400000 : 0x000040);
		put_str(&s, 40, 80, 4, "AXON7 PROBE", 0xffffff);
		put_str(&s, 40, 160, 3, pipe_names[i], 0xffff00);
		put_str(&s, 40, 220, 3, "rebooting to recovery", 0xffffff);
		put_str(&s, 40, 280, 3, "in 20 s", 0xffffff);
		drawn++;
	}
	plog_hex("pipes drawn", drawn);

	/* Command-mode panel: CTL START sends a frame (split: CTL0 drives both DSIs) */
	for (unsigned i = 0; i < 5; i++) {
		uintptr_t ctl = MDSS + 0x2000 + 0x200 * i;
		if (rd32(ctl + 0x14)) {		/* CTL_TOP: interface in use */
			wr32(ctl + 0x1c, 1);
			plog_hex("kicked CTL", i);
		}
	}
	__asm__ volatile("dsb sy" ::: "memory");

	wr32(IMEM_RESTART_REASON, RESTART_RECOVERY);
	__asm__ volatile("dsb sy" ::: "memory");
	plog_str("reset in 20 s\n");
	delay_ms(20000);
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
	wr32(IMEM_RESTART_REASON, RESTART_RECOVERY);
	delay_ms(5000);
	psci_reset();
}
