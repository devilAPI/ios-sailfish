/*
 * Boot menu entry postmarketOS (axon7.c): Linux instead of iOS. ZTE LK loads the boot
 * image's ramdisk (the bundle) at the header's ramdisk address and records
 * it in /chosen linux,initrd-start/end of the DTB it patched (x0, 0x82400000).
 * The bundle's own DTB is mainline's msm8996-zte-axon7 with memory, bootargs
 * and 8-byte initrd placeholders already set (tools/axon7-dualboot.py), so
 * only the initramfs location is filled in here. Then Linux is entered as
 * Documentation/arch/arm64/booting.rst asks: Image at a 2 MiB aligned base
 * (text_offset 0, header flag "anywhere"), BSS zeroed, MMU and D-cache off
 * (as LK left them), stale I-cache lines dropped, DAIF masked, x0 = DTB,
 * x1-x3 = 0, secondary CPUs still off (PSCI brings them up).
 */
#include "pmos.h"
#include "console.h"
#include "fdt.h"
#ifndef PMOS_HOST_TEST
#include "ufsr.h"
#endif

#define SZ_2M		0x200000UL
#define FDT_MAGIC_BE	0xedfe0dd0u	/* d00dfeed read little-endian */

typedef void (*linux_entry_t)(uint64_t dtb, uint64_t x1, uint64_t x2, uint64_t x3);
#ifdef PMOS_HOST_TEST
const char *pmos_host_jump(uintptr_t base, uintptr_t dtb);	/* host_pmos_test.c */
#endif

static int magic_ok(const char *m)
{
	static const char want[] = PMOS_MAGIC;
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

/* 8-byte words; dst > src overlaps are copied from the end. */
static void move64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	n = (n + 7) & ~7UL;
	if (dst > src) {
		for (uint64_t i = n; i; i -= 8)
			*(volatile uint64_t *)(dst + i - 8) = *(volatile uint64_t *)(src + i - 8);
	} else {
		for (uint64_t i = 0; i < n; i += 8)
			*(volatile uint64_t *)(dst + i) = *(volatile uint64_t *)(src + i);
	}
}

static void zero64(uintptr_t dst, uint64_t n)
{
	for (uint64_t i = 0; i + 8 <= n; i += 8)
		*(volatile uint64_t *)(dst + i) = 0;
}

static uint64_t stash_rs, stash_re;	/* the bundle copy pmos_stash() made */

int pmos_stash(uintptr_t lk_dtb, uintptr_t dst)
{
	uint64_t rs, re;
	if (!fdt_chosen_u64(lk_dtb, "linux,initrd-start", &rs) || !fdt_chosen_u64(lk_dtb, "linux,initrd-end", &re))
		return 0;
	if ((rs & 7) || re <= rs || !magic_ok((const char *)rs))
		return 0;
	if (rs != dst)
		move64(dst, rs, re - rs);
	stash_rs = dst;
	stash_re = dst + (re - rs);
	return 1;
}

#ifndef PMOS_HOST_TEST
/*
 * The bundle's own partition on LUN 0 (pmos_boot): LUNs 1-4, with `boot`,
 * are write protected while the phone runs normally, so postmarketOS keeps
 * its bundle here (axon7-dualboot-update). Preferred over the copy in the
 * boot image's ramdisk slot. 1 if a bundle was read to dst.
 */
static uint8_t part_hdr[4096] __attribute__((aligned(4096)));

int pmos_load_part(uintptr_t dst)
{
	struct ufsr_part p;
	/* header to a scratch block first: dst may hold the copy LK loaded (the fallback) */
	if (ufsr_open() || ufsr_find("pmos_boot", &p) || ufsr_read(p.lun, p.first, 1, (uintptr_t)part_hdr))
		return 0;
	const struct pmos_hdr *h = (const struct pmos_hdr *)part_hdr;
	if (!magic_ok(h->magic) || h->total < sizeof(*h) || h->total > (uint64_t)p.blocks * 4096u)
		return 0;
	if (ufsr_read(p.lun, p.first, (uint32_t)((h->total + 4095) / 4096), dst))
		return 0;
	stash_rs = dst;
	stash_re = dst + ((const struct pmos_hdr *)dst)->total;
	return 1;
}
#endif

static uint64_t sum64(uintptr_t p, uint64_t n)
{
	uint64_t s = 0, i;
	for (i = 0; i + 8 <= n; i += 8)
		s += *(volatile uint64_t *)(p + i);
	if (i < n) {	/* zero-padded tail */
		uint64_t w = 0;
		for (uint64_t j = 0; i + j < n; j++)
			w |= (uint64_t)*(volatile uint8_t *)(p + i + j) << (8 * j);
		s += w;
	}
	return s;
}

const char *pmos_boot(uintptr_t lk_dtb)
{
	uint64_t rs, re;
	if (stash_re) {
		rs = stash_rs;
		re = stash_re;
	} else if (!fdt_chosen_u64(lk_dtb, "linux,initrd-start", &rs) || !fdt_chosen_u64(lk_dtb, "linux,initrd-end", &re))
		return "no ramdisk in /chosen";
	con_hex2("PMOS", "lo=", rs, "hi=", re);
	const struct pmos_hdr *h = (const struct pmos_hdr *)rs;
	if ((rs & 7) || re <= rs || !magic_ok(h->magic))
		return "no postmarketOS bundle in the ramdisk";
	uint64_t len = re - rs;
	if ((h->version != 1 && h->version != PMOS_VERSION) ||
	    h->hdr_size < (h->version == 1 ? sizeof(*h) - sizeof(h->sum) : sizeof(*h)) || h->total > len ||
	    h->dtb_off + h->dtb_size > h->total || h->initrd_off + h->initrd_size > h->total ||
	    h->image_off + h->image_size > h->total || (h->dtb_off & 7) || (h->image_off & 7) ||
	    h->image_mem < h->image_size || h->image_size < 64)
		return "bad postmarketOS bundle header";
	if (h->version >= 2 && sum64(rs + h->hdr_size, h->total - h->hdr_size) != h->sum)
		return "bundle checksum wrong (damaged in memory)";
	uintptr_t dtb = rs + h->dtb_off, img = rs + h->image_off;
	if (*(volatile uint32_t *)dtb != FDT_MAGIC_BE)
		return "bundle DTB has no FDT magic";
	if (*(volatile uint32_t *)(img + 56) != 0x644d5241u)	/* "ARM\x64" */
		return "bundle Image is not an arm64 Image";
	if (*(volatile uint64_t *)(img + 8) != 0)
		return "Image text_offset is not 0";

	/* The Image is last in the bundle: moving it up stays clear of the DTB and initramfs. */
	uintptr_t base = (img + SZ_2M - 1) & ~(SZ_2M - 1);
	if (base != img) {
		con_hex2("IMAGE", "from=", img, "to=", base);
		move64(base, img, h->image_size);
	}
	zero64(base + ((h->image_size + 7) & ~7UL), h->image_mem - ((h->image_size + 7) & ~7UL));

	uint64_t is = rs + h->initrd_off, ie = is + h->initrd_size;
	if (!fdt_chosen_set_u64(dtb, "linux,initrd-start", is) || !fdt_chosen_set_u64(dtb, "linux,initrd-end", ie))
		return "bundle DTB lacks the initrd placeholders";
	con_hex2("INITRD", "lo=", is, "hi=", ie);
	con_hex2("LINUX", "base=", base, "dtb=", dtb);
	con_str("BOOT", "postmarketOS");
	con_flush();

#ifdef PMOS_HOST_TEST
	(void)(linux_entry_t)0;
	return pmos_host_jump(base, dtb);
#else
	__asm__ volatile("msr daifset, #0xf; dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((linux_entry_t)base)(dtb, 0, 0, 0);
	return "Linux returned";
#endif
}
