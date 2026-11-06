#pragma once
#include <stdint.h>

/* Read-only UFS for the shim's Android path (ufsr.c); 4 KiB blocks. 0 = ok. */
struct ufsr_part {
	uint8_t lun;
	uint32_t first, blocks;
};

int ufsr_open(void);		/* take over the host LK left running */
void ufsr_release(void);	/* stop our request list again */
int ufsr_find(const char *name, struct ufsr_part *out);	/* GPT partition by name, any LUN */
int ufsr_read(uint8_t lun, uint32_t lba, uint32_t blocks, uintptr_t dst);
