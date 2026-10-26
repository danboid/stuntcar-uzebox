/* PC side of scr_io.h: a 128 KB array stands in for the SPI RAM, SCRTRK.BIN is read from disk */
#include <stdio.h>
#include <string.h>
#include "scr_io.h"
#include "scr_trackdata.h"   /* SCR_DATA_SIZE */
static uint8_t xram[0x20000];
void xram_read(uint32_t addr, void *dst, uint16_t n) { memcpy(dst, &xram[addr], n); }
void xram_write(uint32_t addr, const void *src, uint16_t n) { memcpy(&xram[addr], src, n); }
int scr_load_tracks(void)
{
	FILE *f = fopen("SCRTRK.BIN", "rb");
	if (!f) return 0;
	size_t n = fread(&xram[XRAM_TRACKS], 1, SCR_DATA_SIZE, f);
	fclose(f);
	return n == SCR_DATA_SIZE;
}
