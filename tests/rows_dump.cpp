/* every row (0 .. ns) of every piece of every track: scr_piece_rows -> a dump.
 * AVR: into SPI RAM from XRAM_LOG (16 bytes per corner: x, y, z, tag); PC: to stdout */
#include "scr_track.h"
#include "scr_io.h"
#include <stdint.h>
#include <stdio.h>
bool bSuperLeague = false;
long player_current_piece, opponents_current_piece;
extern "C" int scr_rand(void) { return 0; }
#ifdef __AVR__
volatile uint8_t done;
#endif
int main(void)
{
	if (!scr_load_tracks()) return 1;
	uint32_t w = 0;
	for (long t = TRK; t <= TRK; t++) {   /* (TRK: one track per run - the log fits 64 KB) */
		ConvertAmigaTrack(t);
		for (long p = 0; p < NumTrackPieces; p++) {
			long ns = Track[p].numSegments;
			for (long r = 0; r <= ns; r++) {
				uint8_t row = (uint8_t)r;
				COORD_3D c[1][4];
				scr_piece_rows(p, &row, 1, c);
				for (int k = 0; k < 4; k++) {
					long rec[4] = {c[0][k].x, c[0][k].y, c[0][k].z, (t << 24) | (p << 8) | (r << 2) | k};
#ifdef __AVR__
					xram_write(XRAM_LOG + w, rec, 16);
#else
					printf("%ld %ld %ld %ld\n", rec[0], rec[1], rec[2], rec[3]);
#endif
					w += 16;
				}
			}
		}
	}
#ifdef __AVR__
	{ uint32_t n = w; xram_write(XRAM_LOG - 4, &n, 4); }
	done = 0xA5;
	for (;;) ;
#endif
	return 0;
}
