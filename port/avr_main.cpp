/* AVR (Uzebox) entry point of the headless logic test: runs the same scripted race as the
 * PC build and writes the per-tick state into the SPI RAM at XRAM_LOG: 14 x int32 per tick
 * (13 state values + the CPU cycles of that tick). Track data comes from the SD card. */
#include <avr/io.h>
#include <avr/interrupt.h>
#include <stdint.h>
#ifndef TRACK
#define TRACK 0
#endif
#ifndef TICKS
#define TICKS 600
#endif
extern long log_state[16];
extern int run_race(long track, long ticks);
volatile uint8_t done;

static volatile uint16_t t1_ovf;
ISR(TIMER1_OVF_vect) { t1_ovf++; }
static uint32_t now(void)
{
	uint16_t hi, lo;
	cli();
	lo = TCNT1; hi = t1_ovf;
	if ((TIFR1 & (1 << TOV1)) && lo < 0x8000) hi++;   /* overflow pending, not yet counted */
	sei();
	return ((uint32_t)hi << 16) | lo;
}

#include "scr_io.h"

static uint32_t last;
#ifdef COMBO
#include "modelS_render.h"
extern long player1_x, player1_y, player1_z, player1_x_angle, player1_y_angle, player1_z_angle, player_current_piece;
#endif
void log_tick(long tick)
{
#ifdef COMBO
	scr_camera_player(player1_x, player1_y, player1_z, player1_x_angle, player1_y_angle, player1_z_angle);
	scr_render_frame(player_current_piece);
#endif
	uint32_t c = now();
	log_state[13] = (long)(c - last);
	(void)tick;
#ifdef LOG_HASH
	{ long e[2]; e[0] = log_state[14]; e[1] = log_state[13];      /* state hash, cycles */
	  xram_write(XRAM_LOG + (uint32_t)tick * 8, e, 8); }
#else
	xram_write(XRAM_LOG + (uint32_t)tick * 56, log_state, 56);   /* 14 x int32, little-endian */
#endif
	last = now();
}

int main(void)
{
	TCCR1A = 0; TCCR1B = 1; TIMSK1 = 1 << TOIE1;      /* cycle counter */
	sei();
	last = now();
	run_race(TRACK, TICKS);
	done = 0xA5;
	for (;;) ;
}
