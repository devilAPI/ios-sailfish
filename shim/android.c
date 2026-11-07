/*
 * Boot menu entry LineageOS: start an Android boot image from the los_boot
 * partition the way ZTE LK would start it from `boot`.
 *
 * Image format (tools/axon7-androidimg.py): boot image header v2 with a raw
 * arm64 Image (no gunzip with the MMU off) and the DTBs in the dtb section.
 *
 * What LK does and this repeats:
 *  - pick the DTB matching this board (qcom,msm-id / qcom,board-id of the DTB
 *    LK chose for the shim's own boot image: same phone, same ids);
 *  - /memory reg from LK's DTB (LK fills it from the SMEM RAM table);
 *  - /chosen bootargs: one string, the DTB's own bootargs, then the image's
 *    command line plus what LK appended for this boot
 *    (serial number, panel, baseband, ...): the last string of LK's bootargs,
 *    minus the system-as-root arguments LK adds for its own boot image;
 *  - linux,initrd-start/end for the ramdisk, which stays where it was read;
 *  - the kernel at 0x80000000 + text_offset (3.18/4.4 kernels cannot run
 *    anywhere else), the DTB 2 MiB aligned after its image_size.
 * The shim itself runs at 0x80080000, so the last copy and the jump run from
 * a trampoline (start.S tramp_begin) copied to high memory.
 *
 * Memory: staging 0xa4000000..0xac000000 (image), DTB work copy at
 * 0xac000000, trampoline at 0xa3f00000: all free in the downstream msm8996
 * map (reserved: 0x83400000-0x85800000 splash, 0x85800000-0x91700000,
 * 0x92900000, 0x9ff00000) and clear of the postmarketOS stash at 0xa0000000.
 */
#include "android.h"
#include "console.h"
#include "fdtw.h"
#include "pstore.h"
#include "ufsr.h"

#define STAGE		0xa4000000UL
#define STAGE_MAX	(128UL << 20)
#define DTB_WORK	0xac000000UL
#define DTB_ROOM	(64u << 10)
#define TRAMP		0xa3f00000UL
#define KBASE		0x80000000UL
#define KLIMIT		0x83400000UL	/* splash reserved from here */
#define SZ_2M		0x200000UL
#define BLOCK		4096u

#ifndef LOS_PART
#define LOS_PART	"los_boot"
#endif

#ifdef ANDROID_HOST_TEST
uintptr_t android_host_stage(void);
uintptr_t android_host_dtbwork(void);
const char *android_host_jump(uintptr_t dst, uintptr_t src, uint64_t len, uintptr_t dtb_dst, uintptr_t dtb_src,
			      uint64_t dtb_len, uintptr_t entry);
#undef STAGE
#undef DTB_WORK
#define STAGE		android_host_stage()
#define DTB_WORK	android_host_dtbwork()
#else
extern char tramp_begin[], tramp_end[];
typedef void (*tramp_t)(uintptr_t dst, uintptr_t src, uint64_t len, uintptr_t dtb_dst, uintptr_t dtb_src,
			uint64_t dtb_len, uintptr_t entry);
#endif

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const uint8_t *p)
{
	return le32(p) | (uint64_t)le32(p + 4) << 32;
}

static uint32_t be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint64_t up(uint64_t n, uint64_t a)
{
	return (n + a - 1) / a * a;
}

static void copy(void *d, const void *s, uint32_t n)
{
	uint8_t *dd = d;
	const uint8_t *ss = s;
	for (uint32_t i = 0; i < n; i++)
		dd[i] = ss[i];
}

/* every (a,b) cell pair of LK's property appears in the candidate's list */
static int ids_match(const void *lk, const void *dtb, const char *prop, uint32_t cells)
{
	uint32_t ll, cl;
	const uint8_t *lv = fdtw_getprop(lk, fdtw_node(lk, ""), prop, &ll);
	const uint8_t *cv = fdtw_getprop(dtb, fdtw_node(dtb, ""), prop, &cl);
	if (!lv)
		return 1;	/* LK's DTB says nothing: anything goes */
	if (!cv)
		return 0;
	uint32_t step = cells * 4;
	for (uint32_t i = 0; i + step <= ll; i += step) {
		int found = 0;
		for (uint32_t j = 0; !found && j + step <= cl; j += step) {
			found = 1;
			for (uint32_t k = 0; k < step; k++)
				if (lv[i + k] != cv[j + k])
					found = 0;
		}
		if (!found)
			return 0;
	}
	return 1;
}

/* LK's tokens that belong to its own system-as-root boot image, not to ours */
static int drop_token(const char *t, uint32_t n)
{
	/* char arrays, not pointers: no ABS64 relocations in the shim */
	static const char exact[4][16] = { "skip_initramfs", "rootwait", "ro", "init=/init" };
	static const char prefix[3][16] = { "root=", "dm=", "veritykeyid=" };
	for (unsigned i = 0; i < sizeof(exact) / sizeof(exact[0]); i++) {
		uint32_t k = 0;
		while (k < n && exact[i][k] && exact[i][k] == t[k])
			k++;
		if (k == n && !exact[i][k])
			return 1;
	}
	for (unsigned i = 0; i < sizeof(prefix) / sizeof(prefix[0]); i++) {
		uint32_t k = 0;
		while (prefix[i][k] && k < n && prefix[i][k] == t[k])
			k++;
		if (!prefix[i][k])
			return 1;
	}
	return 0;
}

/* append the tokens of s[0..n) to out (space separated), dropping LK's SAR ones if asked */
static uint32_t add_tokens(char *out, uint32_t o, uint32_t cap, const char *s, uint32_t n, int filter)
{
	uint32_t i = 0;
	while (i < n) {
		while (i < n && (s[i] == ' ' || s[i] == 0))
			i++;
		uint32_t b = i;
		int q = 0;	/* a "quoted value" with spaces is one token (dm="...") */
		while (i < n && s[i] != 0 && (q || s[i] != ' ')) {
			if (s[i] == '"')
				q = !q;
			i++;
		}
		if (i == b || (filter && drop_token(s + b, i - b)))
			continue;
		if (o + (i - b) + 2 > cap)
			return o;
		if (o)
			out[o++] = ' ';
		copy(out + o, s + b, i - b);
		o += i - b;
	}
	return o;
}

static char lk_extra[1024];

void android_note_lk(uintptr_t lk_dtb)
{
	/* LK's own bootargs, for the log: this is what it appended for the shim's boot */
	uint32_t len;
	const char *v = fdtw_ok((const void *)lk_dtb) ?
		fdtw_getprop((const void *)lk_dtb, fdtw_node((const void *)lk_dtb, "chosen"), "bootargs", &len) : 0;
	if (!v)
		return;
	uint32_t last = 0;	/* start of the last string */
	for (uint32_t i = 0; i + 1 < len; i++)
		if (!v[i])
			last = i + 1;
	uint32_t n = len - last;
	if (n > sizeof(lk_extra) - 1)
		n = sizeof(lk_extra) - 1;
	copy(lk_extra, v + last, n);
	lk_extra[n] = 0;
	plog_str("LK bootargs: ");
	for (uint32_t i = 0; i < len; i++) {
		char c[2] = { v[i] ? v[i] : '|', 0 };
		plog_str(c);
	}
	plog_str("\n");
}

const char *android_boot(uintptr_t lk_dtb)
{
	const void *lk = (const void *)lk_dtb;
	if (!fdtw_ok(lk))
		return "LK's DTB is not an FDT";

	/* 1. the image */
	struct ufsr_part p;
#ifndef ANDROID_HOST_TEST
	if (ufsr_open())
		return "UFS host not ready";
	if (ufsr_find(LOS_PART, &p))
		return "no " LOS_PART " partition";
	if (ufsr_read(p.lun, p.first, 1, STAGE))
		return "UFS read of the header failed";
#else
	p.lun = 0;
	p.blocks = STAGE_MAX / BLOCK;
#endif
	const uint8_t *h = (const uint8_t *)STAGE;
	if (h[0] != 'A' || h[1] != 'N' || h[2] != 'D' || h[3] != 'R' || h[4] != 'O' || h[5] != 'I' ||
	    h[6] != 'D' || h[7] != '!')
		return LOS_PART " has no Android boot image";
	uint32_t ks = le32(h + 8), rs = le32(h + 16), ss = le32(h + 24), page = le32(h + 36), hv = le32(h + 40);
	if (hv != 2)
		return "boot image is not header v2 (tools/axon7-androidimg.py convert)";
	if (page != 2048 && page != 4096)
		return "boot image page size not 2K/4K";
	uint32_t dtbo = le32(h + 1632), ds = le32(h + 1648);
	uint64_t ko = page, ro = ko + up(ks, page), so = ro + up(rs, page), dto = so + up(ss, page);
	uint64_t dbo = dto + up(dtbo, page), total = dbo + up(ds, page);
	if (!ds)
		return "boot image has no DTB section";
	if (total > STAGE_MAX || total > (uint64_t)p.blocks * BLOCK)
		return "boot image larger than the partition or staging area";
	con_hex2("LOS", "size=", (uint32_t)total, "lun=", p.lun);
	con_flush();
#ifndef ANDROID_HOST_TEST
	if (ufsr_read(p.lun, p.first, (uint32_t)up(total, BLOCK) / BLOCK, STAGE))
		return "UFS read of the image failed";
#endif

	/* 2. kernel */
	uintptr_t kimg = STAGE + ko;
	const uint8_t *k = (const uint8_t *)kimg;
	if (ks < 64 || k[56] != 'A' || k[57] != 'R' || k[58] != 'M' || k[59] != 0x64)
		return "kernel is not a raw arm64 Image (gzip? convert it)";
	uint64_t text_off = le64(k + 8), isize = le64(k + 16);
	if (!isize || isize < ks)
		return "Image header has no image_size";
	uintptr_t entry = KBASE + text_off, kend = entry + isize;
	uintptr_t dtb_dst = up(kend, SZ_2M);
	if (dtb_dst + SZ_2M > KLIMIT)
		return "Image too big below the splash memory";

	/* 3. DTB: the one for this board */
	const uint8_t *dtbs = (const uint8_t *)(STAGE + dbo), *pick = 0;
	for (uint32_t o = 0; o + 40 <= ds;) {
		const uint8_t *d = dtbs + o;
		uint32_t n = be32(d + 4);
		if (be32(d) != 0xd00dfeedu || n < 40 || o + n > ds)
			return "bad DTB in the dtb section";
		if (!pick && ids_match(lk, d, "qcom,msm-id", 2) && ids_match(lk, d, "qcom,board-id", 2))
			pick = d;
		o += n;
	}
	if (!pick)
		return "no DTB for this board (qcom,msm-id/board-id)";
	uint32_t dn = be32(pick + 4), cap = dn + DTB_ROOM;
	if (cap > SZ_2M)
		return "DTB too big";
	uint8_t *w = (uint8_t *)DTB_WORK;
	copy(w, pick, dn);

	/* 4. LK's fixups */
	uint32_t ml;
	const void *mem = fdtw_getprop(lk, fdtw_node(lk, "memory"), "reg", &ml);
	if (!mem || !ml)
		return "LK's DTB has no /memory reg";
	int mnode = fdtw_node(w, "memory");
	if (mnode < 0)
		return "image DTB has no /memory node";
	if (!fdtw_setprop(w, cap, mnode, "reg", mem, ml))
		return "cannot set /memory reg";

	/*
	 * One string: the kernel reads bootargs up to the first NUL. LK's
	 * fdt_appendprop_string is Qualcomm's, which turns the old NUL into a
	 * space; a plain string list ("own\0image ...\0") left 4.4 kernels
	 * (whose msm8996 DTB has bootargs of its own) with only the DTB's part:
	 * no androidboot.*, no panel.
	 */
	static char args[2048];
	uint32_t ol;
	int chosen = fdtw_node(w, "chosen");
	if (chosen < 0)
		return "image DTB has no /chosen node";
	const char *own = fdtw_getprop(w, chosen, "bootargs", &ol);
	if (own && ol > 1024)
		return "image DTB bootargs too long";
	char *app = args;
	uint32_t an = 0;
	if (own && ol)
		an = add_tokens(app, an, (uint32_t)sizeof(args), own, ol, 0);
	an = add_tokens(app, an, (uint32_t)sizeof(args), (const char *)h + 64, 512, 0);
	an = add_tokens(app, an, (uint32_t)sizeof(args), (const char *)h + 608, 1024, 0);
	uint32_t xl = 0;
	while (lk_extra[xl])
		xl++;
	an = add_tokens(app, an, (uint32_t)sizeof(args), lk_extra, xl, 1);
	app[an++] = 0;
	if (!fdtw_setprop(w, cap, chosen, "bootargs", args, an))
		return "cannot set /chosen bootargs";
	chosen = fdtw_node(w, "chosen");	/* offsets moved */

	uint64_t is = STAGE + ro, ie = is + rs;
	uint8_t v[8];
	for (int i = 0; i < 8; i++)
		v[i] = (uint8_t)(is >> (56 - 8 * i));
	if (!fdtw_setprop(w, cap, chosen, "linux,initrd-start", v, 8))
		return "cannot set initrd-start";
	chosen = fdtw_node(w, "chosen");
	for (int i = 0; i < 8; i++)
		v[i] = (uint8_t)(ie >> (56 - 8 * i));
	if (!fdtw_setprop(w, cap, chosen, "linux,initrd-end", v, 8))
		return "cannot set initrd-end";
	uint32_t nd = fdtw_size(w);

	plog_str("LOS cmdline: ");
	plog_str(app);
	plog_str("\n");
	plog_hex("LOS entry", entry);
	plog_hex("LOS dtb", dtb_dst);
	con_hex2("LINUX", "entry=", (uint32_t)entry, "dtb=", (uint32_t)dtb_dst);
	con_str("BOOT", "LineageOS");
	con_flush();

	/* 5. copy and jump from the trampoline */
#ifdef ANDROID_HOST_TEST
	return android_host_jump(entry, kimg, ks, dtb_dst, (uintptr_t)w, nd, entry);
#else
	ufsr_release();
	uint32_t tn = (uint32_t)(tramp_end - tramp_begin);
	copy((void *)TRAMP, tramp_begin, tn);
	__asm__ volatile("msr daifset, #0xf; dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((tramp_t)TRAMP)(entry, kimg, ks, dtb_dst, (uintptr_t)w, nd, entry);
	return "trampoline returned";
#endif
}
