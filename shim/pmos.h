#pragma once
#include <stdint.h>

/*
 * postmarketOS bundle (tools/axon7-dualboot.py), carried in the boot image's
 * ramdisk slot. Little-endian header at offset 0, then the prepared DTB, the
 * initramfs and, last and 2 MiB aligned in the bundle, the raw arm64 Image.
 */
#define PMOS_MAGIC	"AX7PMOS1"
#define PMOS_VERSION	2u	/* 2 adds sum; 1 is still accepted */

struct pmos_hdr {
	char magic[8];
	uint32_t version;
	uint32_t hdr_size;
	uint64_t dtb_off, dtb_size;
	uint64_t initrd_off, initrd_size;
	uint64_t image_off, image_size;	/* Image file bytes */
	uint64_t image_mem;		/* Image header image_size: file + BSS */
	uint64_t total;			/* bundle bytes */
	char cmdline_note[64];		/* first bytes of the kernel cmdline, for the screen */
	uint64_t sum;			/* v2: sum of the 64-bit LE words after the header, to total */
};

/*
 * ZTE LK ignores the boot header's ramdisk address and puts the ramdisk
 * right after its DTB (~0x82600000), over the splash framebuffer the shim
 * draws on. Copy the bundle to dst before anything is drawn; pmos_boot()
 * then uses that copy. Returns 1 if a bundle was moved.
 */
int pmos_stash(uintptr_t lk_dtb, uintptr_t dst);

/* Read the bundle from the pmos_boot partition to dst (used by pmos_boot() then). */
int pmos_load_part(uintptr_t dst);

/* Boot Linux from the bundle the bootloader loaded as the ramdisk; returns only on error. */
const char *pmos_boot(uintptr_t lk_dtb);
