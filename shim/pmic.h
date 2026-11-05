#pragma once
#include <stdint.h>

/*
 * One PMIC register through the SPMI PMIC arbiter v2 observer channel
 * (MMU off: physical addresses). ppid = SID << 8 | peripheral.
 * Returns 0 on success.
 */
int pmic_read(uint16_t ppid, uint8_t addr, uint8_t *out);

/* Axon 7 volume down (PM8994 GPIO 3, active low): 1 pressed, 0 released, -1 unreadable. */
int pmic_voldown_pressed(void);
