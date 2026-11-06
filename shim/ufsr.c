/*
 * Read-only UFS access for the shim's Android path (android.c), the way
 * xnu's bsd/dev/sweet_ufs.c (patch 0028) does it on the Axon 7: take over
 * the UFS host ZTE LK left running (ufshc@624000) by pointing its transfer
 * request list at ours, then polled READ(10)s with the data DMAed straight
 * to the destination (MMU off: memory is coherent, no cache maintenance).
 * There is no SCSI WRITE here. Partitions are found by GPT name on any LUN.
 * Linux (ufs-qcom) resets the host when it starts, so leaving it taken over
 * is fine; ufsr_release() stops our list before the jump anyway.
 */
#include "ufsr.h"

#define UFS_BASE	0x00624000UL
#define REG_IS		0x20
#define REG_IE		0x24
#define REG_HCS		0x30
#define REG_HCE		0x34
#define REG_UTRLBA	0x50
#define REG_UTRLBAU	0x54
#define REG_UTRLDBR	0x58
#define REG_UTRLCLR	0x5c
#define REG_UTRLRSR	0x60
#define HCS_DP		(1u << 0)
#define HCS_UTRLRDY	(1u << 1)

#define BLOCK		4096u
#define PRDT_CHUNK	(256u << 10)		/* byte count field: 18 bits */
#define PRDT_N		8u			/* up to 2 MiB per command */
#define CMD_BYTES	(PRDT_CHUNK * PRDT_N)

static inline uint32_t rd(uint32_t off)
{
	uint32_t v = *(volatile uint32_t *)(UFS_BASE + off);
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

static inline void wr(uint32_t off, uint32_t v)
{
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)(UFS_BASE + off) = v;
}

struct utrd {
	uint32_t dw0, dw1, dw2, dw3, ucdba, ucdbau, resp, prdt;
};

struct ucd {
	uint8_t cmd[512];
	uint8_t resp[512];
	struct {
		uint32_t addr_lo, addr_hi, rsvd, dbc;
	} prdt[PRDT_N];
};

static struct utrd utrl[32] __attribute__((aligned(1024)));
static struct ucd ucd __attribute__((aligned(128)));
static uint8_t blk[2 * BLOCK] __attribute__((aligned(4096)));
static uint8_t tag;
static int taken;

static uint64_t cnt(void)
{
	uint64_t v;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(v));
	return v;
}

static uint64_t frq(void)
{
	uint64_t v;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
	return v;
}

static void zero(void *p, uint32_t n)
{
	volatile uint8_t *b = p;
	for (uint32_t i = 0; i < n; i++)
		b[i] = 0;
}

/* One SCSI command, data in (len bytes to buf, 4-byte aligned) or none. 0 = ok. */
static int scsi(uint8_t lun, const uint8_t *cdb, uint32_t cdb_len, uintptr_t buf, uint32_t len)
{
	zero(&utrl[0], sizeof(utrl[0]));
	zero(&ucd, sizeof(ucd));
	ucd.cmd[0] = 0x01;			/* COMMAND UPIU */
	ucd.cmd[1] = len ? 0x40 : 0x00;		/* R: data in */
	ucd.cmd[2] = lun;
	ucd.cmd[3] = ++tag;
	ucd.cmd[12] = (uint8_t)(len >> 24);
	ucd.cmd[13] = (uint8_t)(len >> 16);
	ucd.cmd[14] = (uint8_t)(len >> 8);
	ucd.cmd[15] = (uint8_t)len;
	for (uint32_t i = 0; i < cdb_len; i++)
		ucd.cmd[16 + i] = cdb[i];
	uintptr_t ucd_pa = (uintptr_t)&ucd;
	utrl[0].dw0 = (1u << 28) | ((len ? 2u : 0u) << 25) | (1u << 24);
	utrl[0].dw2 = 0x0f;
	utrl[0].ucdba = (uint32_t)ucd_pa;
	utrl[0].ucdbau = (uint32_t)(ucd_pa >> 32);
	utrl[0].resp = (512u / 4) << 16 | (512u / 4);
	if (len) {
		uint32_t n = 0;
		for (uint32_t done = 0; done < len; done += PRDT_CHUNK, n++) {
			uint32_t c = len - done < PRDT_CHUNK ? len - done : PRDT_CHUNK;
			ucd.prdt[n].addr_lo = (uint32_t)(buf + done);
			ucd.prdt[n].addr_hi = (uint32_t)((buf + done) >> 32);
			ucd.prdt[n].dbc = c - 1;
		}
		utrl[0].prdt = (1024u / 4) << 16 | n;
	}
	__asm__ volatile("dsb sy" ::: "memory");
	wr(REG_UTRLDBR, 1);
	uint64_t end = cnt() + frq() * 2;	/* 2 s */
	while (rd(REG_UTRLDBR) & 1) {
		if (cnt() > end) {
			wr(REG_UTRLCLR, ~1u);
			return -1;
		}
	}
	__asm__ volatile("dsb sy" ::: "memory");
	wr(REG_IS, rd(REG_IS));
	if ((utrl[0].dw2 & 0xff) || ucd.resp[0] != 0x21 || ucd.resp[6] || ucd.resp[7])
		return -2;
	return 0;
}

int ufsr_open(void)
{
	if (taken)
		return 0;
	uint32_t hce = rd(REG_HCE), hcs = rd(REG_HCS);
	if (!(hce & 1) || !(hcs & HCS_DP) || !(hcs & HCS_UTRLRDY))
		return -1;
	if (rd(REG_UTRLDBR))
		return -2;
	wr(REG_IE, 0);
	wr(REG_IS, rd(REG_IS));
	wr(REG_UTRLRSR, 0);
	uintptr_t list = (uintptr_t)utrl;
	wr(REG_UTRLBA, (uint32_t)list);
	wr(REG_UTRLBAU, (uint32_t)(list >> 32));
	wr(REG_UTRLRSR, 1);
	if (rd(REG_UTRLBA) != (uint32_t)list || rd(REG_UTRLBAU) != (uint32_t)(list >> 32) || !(rd(REG_UTRLRSR) & 1))
		return -3;
	taken = 1;
	return 0;
}

void ufsr_release(void)
{
	if (taken)
		wr(REG_UTRLRSR, 0);
	taken = 0;
}

static int ready(uint8_t lun)
{
	static const uint8_t tur[6] = { 0 };
	for (int i = 0; i < 3; i++)	/* first command may report a unit attention */
		if (scsi(lun, tur, sizeof(tur), 0, 0) == 0)
			return 1;
	return 0;
}

int ufsr_read(uint8_t lun, uint32_t lba, uint32_t blocks, uintptr_t dst)
{
	while (blocks) {
		uint32_t n = blocks < CMD_BYTES / BLOCK ? blocks : CMD_BYTES / BLOCK;
		uint8_t cdb[10] = { 0x28, 0, (uint8_t)(lba >> 24), (uint8_t)(lba >> 16), (uint8_t)(lba >> 8),
				    (uint8_t)lba, 0, (uint8_t)(n >> 8), (uint8_t)n, 0 };
		if (scsi(lun, cdb, sizeof(cdb), dst, n * BLOCK))
			return -1;
		lba += n;
		blocks -= n;
		dst += (uintptr_t)n * BLOCK;
	}
	return 0;
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int name_eq(const uint8_t *utf16, const char *want)
{
	uint32_t i = 0;
	for (; want[i]; i++)
		if (utf16[2 * i] != (uint8_t)want[i] || utf16[2 * i + 1])
			return 0;
	return i < 36 ? (utf16[2 * i] == 0 && utf16[2 * i + 1] == 0) : 1;
}

int ufsr_find(const char *name, struct ufsr_part *out)
{
	for (uint8_t lun = 0; lun < 8; lun++) {
		if (!ready(lun) || ufsr_read(lun, 1, 1, (uintptr_t)blk))
			continue;
		if (blk[0] != 'E' || blk[1] != 'F' || blk[2] != 'I' || blk[3] != ' ' ||
		    blk[4] != 'P' || blk[5] != 'A' || blk[6] != 'R' || blk[7] != 'T')
			continue;
		uint32_t elba = le32(blk + 72), nent = le32(blk + 80), esz = le32(blk + 84);
		if (esz < 128 || esz > BLOCK || nent > 256)
			continue;
		uint32_t per = BLOCK / esz;
		for (uint32_t i = 0; i < nent; i++) {
			if (i % per == 0 && ufsr_read(lun, elba + i / per, 1, (uintptr_t)blk))
				break;
			const uint8_t *e = blk + (i % per) * esz;
			if (!name_eq(e + 56, name))
				continue;
			uint32_t first = le32(e + 32), last = le32(e + 40);
			if (le32(e + 36) || le32(e + 44) || last < first)
				return -2;	/* beyond 32-bit LBAs: not expected on this phone */
			out->lun = lun;
			out->first = first;
			out->blocks = last - first + 1;
			return 0;
		}
	}
	return -1;
}
