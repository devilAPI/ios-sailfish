/*
 * Small in-place FDT editor for the shim's Android path (android.c): find a
 * root child node, read a property, set a property (any new length) or add
 * one. The blob must have the usual dtc layout (memory reservation map, then
 * the structure block, then the strings block last) and `cap` bytes of room;
 * growing shifts the rest of the blob and updates the header. All accesses
 * are byte-wise (the shim runs with the MMU off: -mstrict-align).
 */
#include "fdtw.h"

#define FDT_BEGIN_NODE	1u
#define FDT_END_NODE	2u
#define FDT_PROP	3u
#define FDT_NOP		4u
#define FDT_END		9u

#define H_TOTALSIZE	4
#define H_OFF_STRUCT	8
#define H_OFF_STRINGS	12
#define H_SIZE_STRINGS	32
#define H_SIZE_STRUCT	36

static uint32_t rbe(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void wbe(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

static uint32_t pad4(uint32_t n)
{
	return (n + 3u) & ~3u;
}

static uint32_t slen(const char *s)
{
	uint32_t n = 0;
	while (s[n])
		n++;
	return n;
}

static void move(uint8_t *dst, const uint8_t *src, uint32_t n)
{
	if (dst > src) {
		while (n--)
			dst[n] = src[n];
	} else {
		for (uint32_t i = 0; i < n; i++)
			dst[i] = src[i];
	}
}

int fdtw_ok(const void *fdt)
{
	const uint8_t *b = fdt;
	return rbe(b) == 0xd00dfeedu && rbe(b + 20) >= 16 && rbe(b + H_OFF_STRUCT) < rbe(b + H_TOTALSIZE);
}

uint32_t fdtw_size(const void *fdt)
{
	return rbe((const uint8_t *)fdt + H_TOTALSIZE);
}

/* offset of the token after a BEGIN_NODE at off */
static uint32_t after_name(const uint8_t *b, uint32_t off)
{
	return off + 4 + pad4(slen((const char *)b + off + 4) + 1);
}

/* offset of the token after the one at off (properties and NOPs only) */
static uint32_t next_tok(const uint8_t *b, uint32_t off)
{
	uint32_t t = rbe(b + off);
	if (t == FDT_PROP)
		return off + 12 + pad4(rbe(b + off + 4));
	if (t == FDT_BEGIN_NODE)
		return after_name(b, off);
	return off + 4;
}

static int name_is(const char *node, const char *want)
{
	uint32_t i = 0;
	for (; want[i]; i++)
		if (node[i] != want[i])
			return 0;
	return node[i] == 0 || node[i] == '@';
}

int fdtw_node(const void *fdt, const char *name)
{
	const uint8_t *b = fdt;
	uint32_t s = rbe(b + H_OFF_STRUCT), end = s + rbe(b + H_SIZE_STRUCT), off = s;
	int depth = 0;
	while (off + 4 <= end) {
		uint32_t t = rbe(b + off);
		if (t == FDT_BEGIN_NODE) {
			if (depth == 0 && !name[0])
				return (int)off;	/* root */
			if (depth == 1 && name_is((const char *)b + off + 4, name))
				return (int)off;
			depth++;
			off = after_name(b, off);
		} else if (t == FDT_END_NODE) {
			if (--depth < 0)
				return -1;
			off += 4;
		} else if (t == FDT_PROP || t == FDT_NOP) {
			off = next_tok(b, off);
		} else {
			return -1;
		}
	}
	return -1;
}

static int find_prop(const uint8_t *b, int node, const char *name)
{
	uint32_t strs = rbe(b + H_OFF_STRINGS), off = after_name(b, (uint32_t)node);
	for (;;) {
		uint32_t t = rbe(b + off);
		if (t == FDT_NOP) {
			off += 4;
			continue;
		}
		if (t != FDT_PROP)
			return -1;	/* first child or END_NODE: not there */
		const char *pn = (const char *)b + strs + rbe(b + off + 8);
		uint32_t i = 0;
		while (name[i] && pn[i] == name[i])
			i++;
		if (!name[i] && !pn[i])
			return (int)off;
		off = next_tok(b, off);
	}
}

const void *fdtw_getprop(const void *fdt, int node, const char *name, uint32_t *len)
{
	const uint8_t *b = fdt;
	if (node < 0)
		return 0;
	int p = find_prop(b, node, name);
	if (p < 0)
		return 0;
	*len = rbe(b + p + 4);
	return b + p + 12;
}

/* Grow or shrink the blob by delta bytes at off (inside the structure block). */
static int shift(uint8_t *b, uint32_t cap, uint32_t off, int32_t delta)
{
	uint32_t total = rbe(b + H_TOTALSIZE);
	if (delta > 0 && total + (uint32_t)delta > cap)
		return 0;
	move(b + off + delta, b + off, total - off);
	wbe(b + H_TOTALSIZE, total + (uint32_t)delta);
	wbe(b + H_SIZE_STRUCT, rbe(b + H_SIZE_STRUCT) + (uint32_t)delta);
	wbe(b + H_OFF_STRINGS, rbe(b + H_OFF_STRINGS) + (uint32_t)delta);
	return 1;
}

static int string_off(uint8_t *b, uint32_t cap, const char *name)
{
	uint32_t strs = rbe(b + H_OFF_STRINGS), n = rbe(b + H_SIZE_STRINGS), l = slen(name);
	for (uint32_t o = 0; o + l < n; o++) {
		uint32_t i = 0;
		while (i <= l && b[strs + o + i] == (uint8_t)name[i])
			i++;
		if (i > l)
			return (int)o;
	}
	uint32_t total = rbe(b + H_TOTALSIZE);
	if (strs + n != total || total + l + 1 > cap)
		return -1;	/* strings block not last, or no room */
	for (uint32_t i = 0; i <= l; i++)
		b[total + i] = (uint8_t)name[i];
	wbe(b + H_SIZE_STRINGS, n + l + 1);
	wbe(b + H_TOTALSIZE, total + l + 1);
	return (int)n;
}

int fdtw_setprop(void *fdt, uint32_t cap, int node, const char *name, const void *val, uint32_t len)
{
	uint8_t *b = fdt;
	const uint8_t *v = val;
	if (node < 0)
		return 0;
	int p = find_prop(b, node, name);
	if (p < 0) {
		int so = string_off(b, cap, name);
		if (so < 0)
			return 0;
		p = (int)after_name(b, (uint32_t)node);
		if (!shift(b, cap, (uint32_t)p, (int32_t)(12 + pad4(len))))
			return 0;
		wbe(b + p, FDT_PROP);
		wbe(b + p + 8, (uint32_t)so);
	} else {
		int32_t delta = (int32_t)pad4(len) - (int32_t)pad4(rbe(b + p + 4));
		if (delta && !shift(b, cap, (uint32_t)p + 12, delta))
			return 0;
	}
	wbe(b + p + 4, len);
	for (uint32_t i = 0; i < len; i++)
		b[p + 12 + i] = v[i];
	for (uint32_t i = len; i < pad4(len); i++)
		b[p + 12 + i] = 0;
	return 1;
}
