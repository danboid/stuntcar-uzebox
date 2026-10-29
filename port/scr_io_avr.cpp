/* AVR side of scr_io.h: SPI RAM (23LC1024, chip select PA4, sequential mode) and the kernel's
 * sdBase for the SD card (chip select PD6). Both share the hardware SPI. */
#include <avr/io.h>
#include <string.h>
#include <avr/interrupt.h>
#include <avr/pgmspace.h>
#include "scr_io.h"
#include "scr_trackdata.h"   /* SCR_DATA_SIZE */
extern "C" {                       /* kernel sdBase (sdBase_scr.S: longer card power-up poll) */
uint8_t sdCardInitNoBuffer(void);
long sdCardFindFileFirstSectorFlash(const char *fileName);
uint8_t sdCardCueSectorAddress(uint32_t lba);
uint8_t sdCardGetChar(void);
uint8_t sdCardStopTransmission(void);
}
static inline uint8_t spi(uint8_t b) { SPDR = b; while (!(SPSR & (1 << SPIF))); return SPDR; }
/* SPI bus lock shared with the rasterizer's background task (game build: m19_mode.S and
 * scr_game.c; weak stand-ins for the test programs) */
extern "C" {
__attribute__((weak)) volatile uint8_t spi_lock;
__attribute__((weak)) void spi_unlock(void) { spi_lock = 0; }
}
static void xram_begin(uint8_t cmd, uint32_t addr)
{
	spi_lock = 1;
	SPCR = (1 << SPE) | (1 << MSTR); SPSR = (1 << SPI2X);
	PORTA &= ~(1 << PA4);
#ifdef SCR_SPIRAM_64K
	spi(cmd); spi(addr >> 8); spi(addr);                    /* 16-bit addresses */
#else
	spi(cmd); spi(addr >> 16); spi(addr >> 8); spi(addr);
#endif
}
static inline void xram_end(void) { PORTA |= (1 << PA4); spi_unlock(); }
#ifndef SCR_XRAM_ASM                     /* (the game build uses scr_xram.S) */
void xram_read(uint32_t addr, void *dst, uint16_t n)
{
	uint8_t *d = (uint8_t *)dst;
	xram_begin(0x03, addr);
	while (n--) *d++ = spi(0xFF);
	xram_end();
}
void xram_write(uint32_t addr, const void *src, uint16_t n)
{
	const uint8_t *s = (const uint8_t *)src;
	xram_begin(0x02, addr);
	while (n--) spi(*s++);
	xram_end();
}
#endif
/* the 512-byte load buffer: the renderer's edge pool when the renderer is linked (alias in
 * modelS_render.cpp), otherwise this */
extern "C++" { __attribute__((weak)) uint8_t scr_io_buffer[512]; }
static const char trkfile[] PROGMEM = "SCRTRK  BIN";
/* SCRTRK.BIN -> SPI RAM. sdBase reads whole sectors from the file's first sector on, so the
 * file must be contiguous on the card (normal for a file copied once onto a FAT card). */
/* Uzebox bootloader v5.0.06+ library (entry table at 0xF000, see kernel/bootlib.s): SD
 * init with SDHC support, FAT16/FAT32, fragmented files. Called directly (word addresses);
 * the same C calling convention as bootlib's FS_* functions. */
typedef struct { uint8_t flags; uint8_t *bufp; uint8_t csize; uint16_t fatp; uint32_t datap,
                 rootp, fclus, cclus; uint8_t csec; } bl_sds_t;
#define BL(addr, type) ((type)((addr) / 2))
typedef uint8_t  (*bl_fn_t)(bl_sds_t *);
typedef void     (*bl_vfn_t)(bl_sds_t *);
typedef uint32_t (*bl_clus_t)(bl_sds_t *, uint8_t *);
typedef void     (*bl_sel_t)(bl_sds_t *, uint32_t);
static uint8_t bl_present(void)                             /* signature B0 07 10 AD, >= 5.0.06 */
{
	return pgm_read_dword((const void *)0xF002) == 0xAD1007B0UL &&
	       (pgm_read_byte((const void *)0xF006) > 0x50 ||    /* version: 0xF006 major/minor (0x50 = 5.0), */
	        (pgm_read_byte((const void *)0xF006) == 0x50 && pgm_read_byte((const void *)0xF007) >= 0x06));   /* 0xF007 patch */
}
/* The track data -> SPI RAM: from the end of the game's own .uze (where `make uze` appends it: the
 * header, the program, padding to a whole sector, then the 41 sectors of SCRTRK.BIN). The
 * bootloader starts games from the root directory only, so the root is searched for a .UZE larger
 * than any game alone can be (the 512-byte header and the 61,440 bytes below the bootloader) and
 * a whole number of sectors - its data checked against SCR_DATA_SUM, the sum of its bytes
 * (another game's appended data, or a damaged copy - the end of a file not yet fully written
 * to the card, say: the next such file). (The sdBase path below, for
 * emulator tests without the bootloader, reads a SCRTRK.BIN.) */
__attribute__((noinline)) static uint8_t bl_next(bl_sds_t *s) { return BL(0xF024, bl_fn_t)(s); }   /* FAT_Next_Sector */
__attribute__((noinline)) static uint8_t bl_read(bl_sds_t *s) { return BL(0xF020, bl_fn_t)(s); }   /* FAT_Read_Sector */
/* search the root directory with *s and load: 1 if done */
__attribute__((noinline)) static uint8_t load_with(bl_sds_t *s)
{
	uint8_t *buf = s->bufp, *e, k, skip, rej = 0, c;     /* rej: candidates whose data was not ours */
#if XRAM_TRACKS != 0
#error "load_with assumes the track data at SPI RAM address 0"
#endif
again:
	c = rej;
	BL(0xF028, bl_vfn_t)(s);                                 /* FAT_Select_Root */
	for (uint8_t n = 0; ; n++) {                            /* root directory, 16 entries a sector */
		if (n == 64 || bl_read(s)) return 0;
		for (k = 0; k < 16; k++) {
			e = buf + 32 * k;
			uint16_t mid = *(uint16_t *)(e + 29);            /* file size bits 8..23 */
			if (!e[0]) return 0;                             /* the end of the directory */
			if (*(uint16_t *)(e + 8) == ('U' | 'Z' << 8) && !e[28] && !(mid & 1) && (mid >> 1) > 121) {   /* .UZ(E) */
				if (c) { c--; continue; }                    /* (already tried) */
				skip = (uint8_t)((mid >> 1) - SCR_DATA_SIZE / 512);   /* (the data: its last 41 sectors) */
				goto found;
			}
		}
		if (bl_next(s)) return 0;
	}
found:
	BL(0xF02A, bl_sel_t)(s, BL(0xF02C, bl_clus_t)(s, e));    /* FAT_Select_Cluster (its first) */
	for (; skip; skip--) if (bl_next(s)) return 0;
	uint16_t sum = 0;
	for (uint16_t a = 0; ; a += 512) {                      /* (XRAM_TRACKS is 0, the data < 64 KB) */
		if (bl_read(s)) return 0;
		for (uint16_t i = 0; i < 512; i++) sum += buf[i];
		xram_write(a, buf, 512);
		if (a == SCR_DATA_SIZE - 512) break;
		if (bl_next(s)) return 0;
	}
	if (sum == SCR_DATA_SUM) return 1;
	rej++;                                                   /* another game's data, or a damaged copy */
	goto again;
}
int scr_load_tracks(void)
{
	extern uint8_t scr_io_buffer[];   /* 512 bytes, only during loading: the renderer's workspace */
	PORTA |= (1 << PA4); DDRA |= (1 << PA4);
	DDRB |= (1 << PB7) | (1 << PB5) | (1 << PB4);
	if (bl_present()) {                                     /* SDHC, FAT32, fragmentation */
		bl_sds_t sds;
		sds.bufp = scr_io_buffer;
		return !BL(0xF01C, bl_fn_t)(&sds) && load_with(&sds);   /* FAT_Init */
	}
#ifdef SCR_SDBASE
	uint8_t k, *buf = scr_io_buffer;
	/* no (new) bootloader: sdBase - standard-capacity cards, FAT16, contiguous file */
	long sec;
	if (sdCardInitNoBuffer() != 0) return 0;
	sec = sdCardFindFileFirstSectorFlash(trkfile);
	if (sec == 0) return 0;
	for (k = 0; k < SCR_DATA_SIZE / 512; k++) {
		sdCardCueSectorAddress(sec + k);
		for (uint16_t i = 0; i < 512; i++) buf[i] = sdCardGetChar();
		sdCardStopTransmission();
		xram_write(XRAM_TRACKS + (uint32_t)k * 512, buf, 512);
	}
	return 1;
#else
	return 0;                                               /* needs the v5 bootloader */
#endif
}
