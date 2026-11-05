/*
 * Host test of pmos.c + fdt.c against a real postmarketOS bundle (no jump):
 *   cc -O1 -Wall -Wextra -Werror -DPMOS_HOST_TEST -Ishim shim/host_pmos_test.c shim/pmos.c shim/fdt.c -o /tmp/t
 *   printf '/dts-v1/; / { chosen { linux,initrd-start = <0 0>; linux,initrd-end = <0 0>; }; };' > /tmp/lk.dts && dtc -O dtb -o /tmp/lk.dtb /tmp/lk.dts
 *   /tmp/t BUNDLE /tmp/lk.dtb
 * (BUNDLE from tools/axon7-dualboot.py bundle)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "pmos.h"
#include "fdt.h"
void con_str(const char *l, const char *s) { printf("  [%s] %s\n", l, s); }
void con_hex(const char *l, uint64_t v) { printf("  [%s] %#llx\n", l, (unsigned long long)v); }
void con_hex2(const char *l, const char *a, uint32_t va, const char *b, uint32_t vb) { printf("  [%s] %s%#x %s%#x\n", l, a, va, b, vb); }
void con_flush(void) {}
static uintptr_t got_base, got_dtb;
const char *pmos_host_jump(uintptr_t base, uintptr_t dtb) { got_base = base; got_dtb = dtb; return "JUMP"; }
static unsigned char *load(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); *n = ftell(f); rewind(f); unsigned char *b = malloc(*n); fread(b, 1, *n, f); fclose(f); return b; }
static int fail(const char *m) { printf("FAIL: %s\n", m); exit(1); }
static void run(const unsigned char *bundle, size_t n, const unsigned char *lkd, size_t lkn, size_t misalign) {
	size_t room = n + (64u << 20);
	unsigned char *mem; if (posix_memalign((void **)&mem, 2u << 20, room)) fail("alloc");
	memset(mem, 0xa5, room);                      /* garbage where BSS goes */
	unsigned char *rd = mem + misalign; memcpy(rd, bundle, n);
	unsigned char lk[4096]; memcpy(lk, lkd, lkn);
	if (!fdt_chosen_set_u64((uintptr_t)lk, "linux,initrd-start", (uintptr_t)rd) ||
	    !fdt_chosen_set_u64((uintptr_t)lk, "linux,initrd-end", (uintptr_t)rd + n)) fail("lk dtb setup");
	const struct pmos_hdr *h = (const struct pmos_hdr *)bundle;
	printf("misalign %#zx:\n", misalign);
	const char *r = pmos_boot((uintptr_t)lk);
	if (strcmp(r, "JUMP")) { printf("  returned: %s\n", r); fail("did not reach the jump"); }
	if (got_base & ((2u << 20) - 1)) fail("Image base not 2 MiB aligned");
	if (memcmp((void *)got_base, bundle + h->image_off, h->image_size)) fail("Image not intact at base");
	for (uint64_t i = (h->image_size + 7) & ~7ul; i < h->image_mem; i++) if (((unsigned char *)got_base)[i]) fail("BSS not zeroed");
	uint64_t is, ie;
	if (!fdt_chosen_u64(got_dtb, "linux,initrd-start", &is) || !fdt_chosen_u64(got_dtb, "linux,initrd-end", &ie)) fail("initrd props unreadable");
	if (is != (uintptr_t)rd + h->initrd_off || ie - is != h->initrd_size) fail("initrd props wrong");
	if (memcmp((void *)(uintptr_t)is, bundle + h->initrd_off, h->initrd_size)) fail("initramfs damaged (by the Image move?)");
	if (got_dtb != (uintptr_t)rd + h->dtb_off) fail("dtb pointer wrong");
	printf("  ok: base %s, initrd and DTB intact\n", got_base == (uintptr_t)rd + h->image_off ? "in place" : "moved");
	free(mem);
}
static void expect_err(unsigned char *bundle, size_t n, const unsigned char *lkd, size_t lkn, const char *what) {
	unsigned char *mem; if (posix_memalign((void **)&mem, 2u << 20, n + (64u << 20))) fail("alloc");
	memcpy(mem, bundle, n); unsigned char lk[4096]; memcpy(lk, lkd, lkn);
	fdt_chosen_set_u64((uintptr_t)lk, "linux,initrd-start", (uintptr_t)mem);
	fdt_chosen_set_u64((uintptr_t)lk, "linux,initrd-end", (uintptr_t)mem + n);
	got_base = 0; const char *r = pmos_boot((uintptr_t)lk);
	if (!strcmp(r, "JUMP")) fail(what);
	printf("%s -> rejected: %s\n", what, r); free(mem);
}
int main(int argc, char **argv) { if (argc < 3) return 2;
	size_t n, lkn; unsigned char *b = load(argv[1], &n), *lk = load(argv[2], &lkn);
	run(b, n, lk, lkn, 0);
	run(b, n, lk, lkn, 0x1000);
	run(b, n, lk, lkn, 0x123458);
	unsigned char *c = malloc(n);
	memcpy(c, b, n); c[0] ^= 1; expect_err(c, n, lk, lkn, "bad magic");
	memcpy(c, b, n); ((struct pmos_hdr *)c)->total = n * 2; expect_err(c, n, lk, lkn, "total beyond ramdisk");
	memcpy(c, b, n); c[((struct pmos_hdr *)c)->image_off + 56] = 0; expect_err(c, n, lk, lkn, "Image magic damaged");
	memcpy(c, b, n); c[((struct pmos_hdr *)c)->dtb_off] = 0; expect_err(c, n, lk, lkn, "DTB magic damaged");
	printf("all host tests passed\n");
	return 0;
}
