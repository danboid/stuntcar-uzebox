/* Uzebox video mode 19: what a game uses */
#pragma once
#include <stdint.h>
extern volatile uint8_t m19_video_on;     /* set by the game once rows are being produced */
extern volatile uint16_t m19_frames, m19_late, m19_underruns;
extern uint8_t ring[256];                 /* run-length rows to play (filled by the game, e.g. from Model S) */
