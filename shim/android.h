#pragma once
#include <stdint.h>

/* Keep LK's appended bootargs (and log them); call before anything else uses LK's DTB area. */
void android_note_lk(uintptr_t lk_dtb);
/* Boot the Android image in the los_boot partition (android.c); returns only on error. */
const char *android_boot(uintptr_t lk_dtb);
