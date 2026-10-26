#include <stdlib.h>
#include <stdio.h>
/* Headless Stunt Car Racer (Remake) logic harness.
 * Starts a race on a given track exactly as StuntCarRacer.cpp does, drives it with a
 * scripted input, and logs the integer game state after every game tick.
 * The same file builds for the PC (32-bit, reference) and the AVR (port under test). */
#include "dxstdafx.h"
#include "StuntCarRacer.h"
#include "Car_Behaviour.h"
#include "Opponent_Behaviour.h"
#include "Track.h"
#include "3D_Engine.h"
extern long player_current_piece;

/* globals normally defined in StuntCarRacer.cpp */
long bNewGame = FALSE, bSuperLeague = FALSE, engineSoundPlaying = FALSE;
static long player1_x, player1_y, player1_z, player1_x_angle, player1_y_angle, player1_z_angle;
static long opponent_x, opponent_y, opponent_z;
static float opponent_x_angle, opponent_y_angle, opponent_z_angle;
extern long boostReserve, road_cushion_value, engine_power, boost_unit_value, opp_engine_power, boostUnit;
extern long lapNumber[];
extern long StandardBoost;

/* renderer hooks: nothing to do headless */
IDirect3DDevice9 *DXUTGetD3DDevice(void) { return 0; }
long UpdatePieceInVB(IDirect3DDevice9 *, long) { return 0; }
void RemoveShadowTriangles(void) {}
void StoreShadowTriangle(D3DXVECTOR3, D3DXVECTOR3, D3DXVECTOR3, long) {}

static unsigned long rng = 12345;
extern "C" int scr_rand(void) { rng = rng * 1103515245UL + 12345UL; return (int)((rng >> 16) & 0x7fff); }

/* scripted controls: always accelerate; steering pattern changes every 24 ticks */
static DWORD script_input(long tick)
{
	{	/* SCR_STEER=a,b: accelerate, steer right during ticks a..b (to leave the track) */
		static long sa = -2, sb;
		if (sa == -2) { const char *e = getenv("SCR_STEER"); sa = -1; if (e) sscanf(e, "%ld,%ld", &sa, &sb); }
		if (sa >= 0) return KEY_P1_ACCEL | ((tick >= sa && tick <= sb) ? KEY_P1_RIGHT : 0);
	}
	static const unsigned char pat[8] = {0, 0, KEY_P1_LEFT, 0, KEY_P1_RIGHT, 0, KEY_P1_LEFT, KEY_P1_RIGHT};
	DWORD in = KEY_P1_ACCEL | pat[(tick / 24) & 7];
	if ((tick % 97) == 50) in |= KEY_P1_BOOST;
	return in;
}

#define FRAME_GAP 6
void log_tick(long tick);                      /* platform specific (stdout / SPI RAM) */
long log_state[16];

int run_race(long track, long ticks)
{
	static IDirectSoundBuffer8 snd[16];
	static IDirectSoundBuffer8 *sndp[16];
	long t, g;
	for (g = 0; g < 16; g++) sndp[g] = &snd[g];
	CreateSinCosTable();
	if (!ConvertAmigaTrack(track)) return 0;
	bNewGame = TRUE;  ResetPlayer();           /* track preview */
	bNewGame = TRUE;                           /* start game */
	ResetLapData(OPPONENT); ResetLapData(PLAYER);
	boostReserve = StandardBoost; road_cushion_value = 0; engine_power = 240;
	boost_unit_value = 16; opp_engine_power = 236; boostUnit = 0;
	if (getenv("SCR_ROADAT")) {            /* road height at one point */
		extern long dbg_road_height(long x, long z);
		long x, z; sscanf(getenv("SCR_ROADAT"), "%ld,%ld", &x, &z);
		printf("%ld\n", dbg_road_height(x, z));
		return 1;
	}
	if (getenv("SCR_ROADGRID")) {          /* road heights on a grid over the whole map */
		extern long dbg_road_height(long x, long z);
		long step = atol(getenv("SCR_ROADGRID"));
		for (long gz = 0; gz < (16L << 26); gz += step)
			for (long gx = 0; gx < (16L << 26); gx += step)
				printf("%ld %ld %ld\n", gx, gz, dbg_road_height(gx, gz));
		return 1;
	}
	long reset_piece = getenv("SCR_RESET") ? atol(getenv("SCR_RESET")) : -1;
	extern void dbg_force_reset(long piece);
	for (t = 0; t < ticks; t++) {
		if (t == 1 && reset_piece >= 0) dbg_force_reset(reset_piece);
		for (g = 0; g < FRAME_GAP; g++) FramesWheelsEngine(sndp);
		MoveDrawBridge();
		CarBehaviour(script_input(t), &player1_x, &player1_y, &player1_z,
		             &player1_x_angle, &player1_y_angle, &player1_z_angle);
		if (!getenv("SCR_NOOPP")) OpponentBehaviour(&opponent_x, &opponent_y, &opponent_z,
		                  &opponent_x_angle, &opponent_y_angle, &opponent_z_angle, FALSE);
		LimitViewpointY(&player1_y);
		UpdateDamage();
		UpdateLapData();
		log_state[0] = player1_x; log_state[1] = player1_y; log_state[2] = player1_z;
		log_state[3] = player1_x_angle; log_state[4] = player1_y_angle; log_state[5] = player1_z_angle;
		log_state[6] = opponent_x; log_state[7] = opponent_y; log_state[8] = opponent_z;
		log_state[9] = lapNumber[0]; log_state[10] = lapNumber[1];
		log_state[11] = player_current_piece; log_state[12] = boostReserve;
		if (getenv("SCR_WHEELS")) { extern void dbg_wheels(long *); long w[10]; dbg_wheels(w);
			printf("W"); for (int i = 0; i < 10; i++) printf(" %ld", w[i]); printf("\n"); }
		log_tick(t);
	}
	return 1;
}
