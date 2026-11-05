#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);
/* Overwrite an existing 8-byte /chosen property with v (big-endian). Returns 0 if absent or not 8 bytes. */
int fdt_chosen_set_u64(uintptr_t fdt, const char *prop, uint64_t v);
