/*
 * Host test of android.c + fdtw.c (no UFS, no jump):
 *   cc -O1 -Wall -Wextra -Werror -DANDROID_HOST_TEST -Ishim shim/host_android_test.c shim/android.c shim/fdtw.c -o /tmp/ta
 *   /tmp/ta IMAGE.img LK.dtb OUT.dtb      (IMAGE from tools/axon7-androidimg.py convert)
 * then inspect OUT.dtb (dtc -I dtb OUT.dtb): /memory reg from LK, /chosen
 * bootargs = one string: DTB's own + image cmdline + LK's extras without SAR tokens,
 * linux,initrd-start/end around the ramdisk in the staging buffer.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "android.h"
#include "fdtw.h"

void con_str(const char *l, const char *s) { printf("  [%s] %s\n", l, s); }
void con_hex2(const char *l, const char *a, uint32_t va, const char *b, uint32_t vb) { printf("  [%s] %s%#x %s%#x\n", l, a, va, b, vb); }
void con_flush(void) {}
void plog_str(const char *s) { fputs(s, stdout); }
void plog_hex(const char *l, uint64_t v) { printf("%s %#llx\n", l, (unsigned long long)v); }

static uint8_t *stage, *work;
static uintptr_t j_dst, j_src, j_ddst, j_dsrc, j_entry;
static uint64_t j_len, j_dlen;
uintptr_t android_host_stage(void) { return (uintptr_t)stage; }
uintptr_t android_host_dtbwork(void) { return (uintptr_t)work; }
const char *android_host_jump(uintptr_t dst, uintptr_t src, uint64_t len, uintptr_t dtb_dst, uintptr_t dtb_src,
			      uint64_t dtb_len, uintptr_t entry)
{
	j_dst = dst; j_src = src; j_len = len; j_ddst = dtb_dst; j_dsrc = dtb_src; j_dlen = dtb_len; j_entry = entry;
	return "JUMP";
}

static uint8_t *load(const char *p, size_t *n)
{
	FILE *f = fopen(p, "rb");
	if (!f) { perror(p); exit(2); }
	fseek(f, 0, SEEK_END); *n = (size_t)ftell(f); rewind(f);
	uint8_t *b = malloc(*n + 16);
	if (fread(b, 1, *n, f) != *n) exit(2);
	fclose(f);
	return b;
}

static int fail(const char *m) { printf("FAIL: %s\n", m); exit(1); }

int main(int argc, char **argv)
{
	if (argc < 4) return 2;
	size_t n, ln;
	uint8_t *img = load(argv[1], &n), *lk = load(argv[2], &ln);
	stage = calloc(1, 128u << 20); work = calloc(1, 4u << 20);
	memcpy(stage, img, n);
	android_note_lk((uintptr_t)lk);
	const char *r = android_boot((uintptr_t)lk);
	if (strcmp(r, "JUMP")) { printf("returned: %s\n", r); fail("did not reach the jump"); }
	uint32_t page = 4096, ks; memcpy(&ks, img + 8, 4);
	if (j_src != (uintptr_t)stage + page || j_len != ks) fail("kernel source/length");
	if (j_entry != 0x80080000u) fail("entry not 0x80000000 + text_offset 0x80000");
	if (j_ddst & 0x1fffff || j_ddst < j_entry) fail("DTB destination");
	if (!fdtw_ok((void *)j_dsrc)) fail("result is not an FDT");
	FILE *o = fopen(argv[3], "wb"); fwrite((void *)j_dsrc, 1, j_dlen, o); fclose(o);
	printf("ok: entry %#lx, dtb %#lx (%llu bytes) -> %s\n", (unsigned long)j_entry, (unsigned long)j_ddst,
	       (unsigned long long)j_dlen, argv[3]);
	return 0;
}
