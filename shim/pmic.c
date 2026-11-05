/*
 * Minimal read-only SPMI access for the shim, the way xnu's sweet_keys.c
 * reads the Axon 7 volume keys (Linux spmi-pmic-arb v2): the APID of a
 * peripheral from the core's map (+0x800 + 4n: ppid in bits [19:8]),
 * preferring the one owned by EE 0 (cnfg +0x700 + 4n, bits [2:0]); then one
 * EXT_READL on that APID's observer page (cmd +0x00, status +0x08 with
 * done bit 0 and error bits 3:1, data +0x18).
 */
#include "pmic.h"

#define SPMI_CORE	0x0400f000UL
#define SPMI_CNFG	0x0400a000UL
#define SPMI_OBS	0x04c00000UL	/* observer pages, 0x8000 per APID */
#define SPMI_APIDS	256u
#define NO_APID		0xffffu

#define PM8994_GPIO3	0x0c2u		/* SID 0 GPIO n: peripheral 0xc0 + n - 1 */
#define GPIO_RT_STS	0x10u		/* bit 0: pin level */

static inline uint32_t rd32(uintptr_t a)
{
	uint32_t v = *(volatile uint32_t *)a;
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

static uint64_t cntpct(void)
{
	uint64_t v;
	__asm__ volatile("mrs %0, cntpct_el0" : "=r"(v));
	return v;
}

static uint64_t cntfrq(void)
{
	uint64_t v;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
	return v;
}

static uint16_t find_apid(uint16_t ppid)
{
	uint16_t found = NO_APID;
	for (uint32_t i = 0; i < SPMI_APIDS; i++) {
		uint32_t map = rd32(SPMI_CORE + 0x800u + 4u * i);
		if (map == 0 || ((map >> 8) & 0xfffu) != ppid)
			continue;
		uint32_t owner = rd32(SPMI_CNFG + 0x700u + 4u * i) & 7u;
		if (found == NO_APID || owner == 0)
			found = (uint16_t)i;
	}
	return found;
}

int pmic_read(uint16_t ppid, uint8_t addr, uint8_t *out)
{
	uint16_t apid = find_apid(ppid);
	if (apid == NO_APID)
		return -1;
	uintptr_t obs = SPMI_OBS + 0x8000UL * apid;
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)obs = (1u << 27) | ((uint32_t)addr << 4);	/* EXT_READL, 1 byte */
	__asm__ volatile("dsb osh" ::: "memory");
	uint64_t end = cntpct() + cntfrq() / 1000;	/* 1 ms */
	while (cntpct() < end) {
		uint32_t st = rd32(obs + 0x08u);
		if (st & 1u) {
			if (st & 0x0eu)
				return -2;
			*out = (uint8_t)rd32(obs + 0x18u);
			return 0;
		}
	}
	return -3;
}

int pmic_voldown_pressed(void)
{
	uint8_t v = 1;
	if (pmic_read(PM8994_GPIO3, GPIO_RT_STS, &v) != 0)
		return -1;
	return (v & 1u) ? 0 : 1;
}
