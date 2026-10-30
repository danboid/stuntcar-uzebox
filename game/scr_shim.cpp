/* C entry points into the C++ game logic and renderer (for scr_game.c) */
#include "dxstdafx.h"
#include "StuntCarRacer.h"
#include "scr_track.h"
#include "scr_io.h"
#include "modelS_render.h"
extern long player1_x, player1_y, player1_z, player1_x_angle, player1_y_angle, player1_z_angle;
extern long player_current_piece;
int race_start(long track);
void race_tick(DWORD input);
DWORD race_autopilot(void);
extern "C" {
__attribute__((noinline)) int game_init(long track) { return scr_load_tracks() && race_start(track); }
__attribute__((noinline)) void game_tick(unsigned int input) { scr_input = (uint8_t)input; race_tick(input); }
__attribute__((noinline)) int game_start(long track)
{	/* one tick without input places the car and camera on the start line (menu view) */
	int ok = race_start(track);
	race_tick(0);
	return ok;
}
__attribute__((noinline)) void game_render(uint32_t stream)
{
	extern long opponent_x, opponent_y, opponent_z, opponent_x_angle, opponent_y_angle, opponent_z_angle, opponents_current_piece;
	scr_opp[0] = opponent_x; scr_opp[1] = opponent_y; scr_opp[2] = opponent_z;
	extern long player1_y_angle;
	scr_opp[3] = opponent_y_angle - player1_y_angle; scr_opp[4] = opponents_current_piece;
	scr_opp[5] = opponent_x_angle; scr_opp[6] = opponent_y_angle; scr_opp[7] = opponent_z_angle;   /* (the car model) */
	CalcYXZTrigCoefficients(player1_x_angle, player1_y_angle, player1_z_angle);   /* (the camera reuses it) */
	scr_camera_player(player1_x, player1_y, player1_z, player1_x_angle, player1_y_angle, player1_z_angle);
	scr_render_frame(player_current_piece, stream);
}
__attribute__((noinline)) unsigned int game_autopilot(void) { return (unsigned int)race_autopilot(); }
}

/* sound effects: the remake plays its effect buffers (harness.cpp: scr_sfx_obj[0..5]) */
extern IDirectSoundBuffer8 scr_sfx_obj[6];
extern "C" void sfx_ask(uint8_t q);
void scr_sfx_play(const IDirectSoundBuffer8 *b)
{
	uint16_t i = (uint16_t)(b - scr_sfx_obj);
	if (i < 6) sfx_ask((uint8_t)(i + 1));
}
