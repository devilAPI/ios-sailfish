#pragma once
#include <stdint.h>

/* In-place FDT editing for the Android path (fdtw.c). Offsets are into the blob. */
int fdtw_ok(const void *fdt);
uint32_t fdtw_size(const void *fdt);
/* "" = root, otherwise a root child by name ("chosen", "memory" also matches "memory@..."). -1 if none. */
int fdtw_node(const void *fdt, const char *name);
const void *fdtw_getprop(const void *fdt, int node, const char *name, uint32_t *len);
/* Set (or add) a property; the blob may grow up to cap bytes. 1 on success. */
int fdtw_setprop(void *fdt, uint32_t cap, int node, const char *name, const void *val, uint32_t len);
