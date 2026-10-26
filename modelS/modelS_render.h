/* Model S polygon renderer (modelS_render.cpp): the Stunt Car Racer track renderer */
#pragma once
#include "scr_platform.h"
#define SCR_ROWS        110            /* doubled rows */
#define SCR_FY16        2125           /* 45 degree vertical field of view, Q4 */
#define SCR_FX16        3994           /* 5-cycle pixel vs doubled row on 4:3 */
#define SCR_NEAR        2              /* pieces either side of the car in full detail */
#define SCR_SKY         226            /* background colour (Uzebox palette) */
#ifndef SCR_MAX_EDGES
#define SCR_MAX_EDGES   254            /* slot numbers are bytes (0 = end of list) */
#endif
#define SCR_MAX_REGIONS 128
#define SCR_NONE        0xFF
#define SCR_MAX_VIS     48             /* visible pieces drawn per frame (max seen: 49; the farthest beyond are dropped) */
#ifndef SCR_XRAM_OUT
extern uint8_t  scr_pool[(SCR_MAX_EDGES + 1) * 9];   /* Model S rasterizer slots: next y0 y1 X dX ida idb */
#endif
#if defined(SCR_XRAM_OUT) && defined(SCR_FAST_EDGES)
extern uint16_t scr_bucket[SCR_ROWS];                   /* first slot per start row (newest first) */
#else
extern uint8_t  scr_bucket[SCR_ROWS];                   /* first slot per start row, sorted by X */
#endif
extern uint16_t scr_nedges, scr_nregions, scr_merged;
#ifndef SCR_XRAM_OUT
extern uint8_t  scr_colours[SCR_MAX_REGIONS];
#endif
extern uint8_t  scr_overflow;
extern uint8_t  scr_draw_limit;
#define SCR_OPP_SIDE    0x05           /* opponent box colours (Uzebox palette) */
#define SCR_OPP_TOP     0x07
extern long scr_opp[8];   /* opponent x, y, z, heading relative to the view, piece (-1: none), x, y, z angles */
#define SCR_HUD_MAX 12
typedef struct { uint8_t x0, x1, y0, y1, colour; } scr_rect_t;   /* pixels 0..255, rows 0..109, inclusive */
extern scr_rect_t scr_hud[SCR_HUD_MAX];                 /* drawn in front of the scene (game build) */
extern uint8_t  scr_hud_n;                       /* at most this many pieces, the nearest */
void scr_set_camera(const int32_t eye[3], const int16_t R[9]);   /* v_cam = ((v-eye)>>2) @ R, R in Q14 */
void scr_camera_player(long px, long py, long pz, long xa, long ya, long za);  /* in-car view */
#ifdef SCR_XRAM_OUT
/* stream buffer layout in SPI RAM (modelS_rast.S reads it) */
#define SCR_STREAM_COLOURS 0                    /* SCR_MAX_REGIONS colours */
#define SCR_STREAM_MASK    SCR_MAX_REGIONS      /* 14 bytes: rows with new edges */
#define SCR_STREAM_RECORDS (SCR_MAX_REGIONS + 14)
void scr_render_frame(long cur_piece, uint32_t stream_base);   /* renders into that buffer */
#else
void scr_render_frame(long cur_piece);
#endif
