/* Storage for the Stunt Car Racer port: SPI RAM (23LC1024) and the SD card on the Uzebox;
 * an array and a file on the PC. Same interface, same results. */
#pragma once
#include <stdint.h>
#define XRAM_TRACKS 0x00000UL                 /* 8 track slots of SCR_TRACK_SLOT bytes */
#ifdef SCR_SPIRAM_64K                         /* a 64 KB SPI RAM (23LC512: 16-bit addresses) */
#define XRAM_LOG    0x0F000UL                 /* (test harness log: none in the game) */
#define XRAM_SLOTS  0x06000UL                 /* renderer: edge slots while building (9 B each) */
#define XRAM_STREAM0 0x08000UL                /* the rasterizer's stream buffers (double buffered) */
#define XRAM_STREAM1 0x0C000UL
#else                                         /* 128 KB (23LC1024: 24-bit addresses) */
#define XRAM_LOG    0x10000UL                 /* test harness log */
#define XRAM_SLOTS  0x14000UL                 /* renderer: edge slots while building (9 B each) */
#define XRAM_STREAM0 0x18000UL                /* the rasterizer's stream buffers (double buffered) */
#define XRAM_STREAM1 0x1C000UL
#endif
#ifdef __cplusplus
extern "C" {
#endif
void xram_read(uint32_t addr, void *dst, uint16_t n);
void xram_write(uint32_t addr, const void *src, uint16_t n);
#ifdef __cplusplus
}
#endif
int scr_load_tracks(void);                     /* SCRTRK.BIN from the SD card -> SPI RAM */
static inline int16_t xram_rd16(uint32_t addr) { int16_t v; xram_read(addr, &v, 2); return v; }  /* little-endian */
static inline uint16_t xram_rdu16(uint32_t addr) { uint16_t v; xram_read(addr, &v, 2); return v; }
