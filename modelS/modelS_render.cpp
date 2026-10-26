/* Model S polygon renderer - the Stunt Car Racer track renderer for Uzebox video mode 19
 * (portable integer C: PC + AVR). Named in tribute to Sega's Model series (Virtua Racing,
 * Model 1). Its edge lists go to the Model S rasterizer (modelS_rast.S).
 *
 * Produces Model S edge records (rows y0..y1, X 8.8 at y0, dX 8.8 per row, one or two region
 * ids) for the rasterizer, plus a colour per region. Higher region id = nearer.
 *
 * Design (validated against a z-buffered Python prototype during development, variant B):
 *  - pieces in painter's order, far first (sorted by distance of their middle row)
 *  - level of detail: pieces within SCR_NEAR pieces of the car along the track use every
 *    segment, the others only their first and last rows (one quad per face)
 *  - per piece, regions in this order: left side wall, right side wall, road runs (consecutive
 *    segments of one colour, far run first). Each region is one polygon outline.
 *  - shared edges are emitted once, toggling both regions: road run / side wall along the
 *    road edge, road run / road run along the row between them. A region that needs clipping
 *    (near plane, screen sides) emits its own clipped outline instead, and its neighbours
 *    emit their halves of the shared edges themselves.
 */
#include "modelS_render.h"
#include <string.h>
#include <stddef.h>
#define NOINL __attribute__((noinline))   /* separate frames: inlining merges all locals (stack) */
#include <stdio.h>
#include "scr_track.h"
#include "StuntCarRacer.h"     /* SCR_BASE_COLOUR */

#define CX16    (128 * 16)
#define CY16    (SCR_ROWS * 8)
#define XMAX16  (4088)                 /* 255.5 px */
#define ZNEARQ  2
#define YMIN16  (-64)                 /* clip limits for y (rows clamp, but keep values small) */
#define YMAX16  (SCR_ROWS * 16 + 64)
#define YSANE   30000                  /* |sy| above this: the region goes through clipping */                      /* near plane, quarter world units (8 world units) */
#define MAXROWS 8                      /* rows per chunk: near pieces are drawn in two chunks */
#define CHUNK   7                      /* a piece with more rows is split (seam row shared) */
#ifndef SCR_THIN_WALL
#define SCR_THIN_WALL 24               /* far pieces' walls lower than this on screen (Q4: 1.5 rows) are skipped */
#endif

/* exact C-style (truncating) division by 2^k without a library call (-Os calls __divmodsi4) */
static inline int32_t tdiv2k(int32_t v, uint8_t k) { return v >= 0 ? (v >> k) : -((-v) >> k); }

/* ---- 32/16 division: truncating, saturated to +-32767 (AVR: sdiv32_16 in fastmath.S) */
#ifdef __AVR__
extern "C" int16_t sdiv32_16(int32_t n, uint16_t d);
extern "C" int32_t sdiv32_16_32(int32_t n, uint16_t d);
#define scr_sdiv(n, d) sdiv32_16((n), (d))
#define scr_sdiv32(n, d) sdiv32_16_32((n), (d))
#else
static int32_t scr_sdiv32(int32_t n, uint16_t d)        /* truncating, 32-bit quotient */
{
	uint32_t an = n < 0 ? (uint32_t)(-n) : (uint32_t)n, q = an / d;
	return n < 0 ? -(int32_t)q : (int32_t)q;
}
static int16_t scr_sdiv(int32_t n, uint16_t d)
{
	uint32_t an = n < 0 ? (uint32_t)(-n) : (uint32_t)n, q;
	if ((an >> 16) >= d) return n < 0 ? -32767 : 32767;
	q = an / d;
	if (q > 32767) return n < 0 ? -32767 : 32767;
	return n < 0 ? -(int16_t)q : (int16_t)q;
}
#endif

/* ---- output, in the rasterizer's format (modelS_rast.S): 9-byte slots
 *   [next, y0, y1, X lo, X hi, dX lo, dX hi, id a, id b], slot 0 unused (next 0 = end),
 *   per-row bucket lists sorted by X >> 8. Duplicate edges (piece joins) are merged on
 *   insertion into one record toggling both regions. */
#ifdef SCR_XRAM_OUT
/* edges built in SPI RAM: slot s (1..SCR_MAX_EDGES) at XRAM_SLOTS + 9 s; only the per-row list
 * heads are internal. scr_render_finish() turns the lists into the rasterizer's stream. */
#include "scr_io.h"
static uint32_t out_base;                       /* stream buffer being written */
#else
uint8_t    scr_pool[(SCR_MAX_EDGES + 1) * 9];
extern uint8_t scr_io_buffer[] __attribute__((alias("scr_pool")));
#endif
#ifndef SCR_WS_EXTERN                          /* (the game: scr_bufs.S, after the rasterizer's pool) */
#if defined(SCR_XRAM_OUT) && defined(SCR_FAST_EDGES)
uint16_t   scr_bucket[SCR_ROWS];                   /* SPI RAM path: 16-bit slot numbers */
#else
uint8_t    scr_bucket[SCR_ROWS];
#endif
#endif
scr_rect_t scr_hud[SCR_HUD_MAX];                /* HUD rectangles, drawn in front of the scene */
uint8_t    scr_hud_n;
uint8_t    scr_draw_limit = SCR_MAX_VIS;      /* pieces drawn (the game lowers it when the rasterizer falls behind) */
uint16_t   scr_nedges;
#ifndef SCR_XRAM_MAX_EDGES
#define SCR_XRAM_MAX_EDGES 440                  /* SPI RAM path: slots 1..440 x 9 bytes (XRAM_SLOTS .. +4 KB) */
#endif
uint16_t   scr_merged;
#ifndef SCR_XRAM_OUT
uint8_t    scr_colours[SCR_MAX_REGIONS];
#endif
uint16_t   scr_nregions;
uint8_t    scr_overflow;

/* ---- camera: v_cam = ((v - eye) >> 2) @ R, R in Q14 */
int32_t scr_eye[3];                         /* the eye (global: modelS_transform.S) */
#define eye scr_eye
int16_t scr_Rm[9];                      /* (global: scr_cam3.S) */
#define Rm scr_Rm

void scr_set_camera(const int32_t e[3], const int16_t R[9])
{
	for (int i = 0; i < 3; i++) eye[i] = e[i];
	for (int i = 0; i < 9; i++) Rm[i] = R[i];
}

/* the in-car camera, as the remake builds it: eye 100 units above the player, rotations Y, X, Z
 * by the negated angles (row vectors: v_cam = v @ RY @ RX @ RZ), Q14 */
__attribute__((noinline)) static int16_t mul14(int16_t a, int16_t b) { return (int16_t)(((int32_t)a * b) >> 14); }

#ifdef SCR_CAM_TRIG
/* game build: the physics' own rotation (CalcYXZTrigCoefficients with the player's angles, just
 * computed by the caller) is this camera's transposed, with signs: R[i] = +-T[(i % 3) * 3 + i / 3],
 * negative at i = 1, 3, 5, 7. (Rounding: truncating divisions instead of shifts, <= 1/16384.) */
extern short Trig_Coeffs[];
NOINL void scr_camera_player(long px, long py, long pz, long xa, long ya, long za)
{
	(void)xa; (void)ya; (void)za;
	long vy = py - (100L << 14);
	for (uint8_t i = 0; i < 9; i++) {
		int16_t t = Trig_Coeffs[(i % 3) * 3 + i / 3];
		Rm[i] = ((0xAA >> i) & 1) ? -t : t;
	}
	eye[0] = px >> 14; eye[1] = -(vy >> 14); eye[2] = pz >> 14;
}
#else
NOINL void scr_camera_player(long px, long py, long pz, long xa, long ya, long za)
{
	long vy = py - (100L << 14);
	int16_t sy = (int16_t)scr_sin(-ya), cy = (int16_t)scr_sin(-ya + 16384), sx = (int16_t)scr_sin(-xa), cx = (int16_t)scr_sin(-xa + 16384);
	int16_t sz = (int16_t)scr_sin(-za), cz = (int16_t)scr_sin(-za + 16384);
	/* T = RY * RX (row vectors) = [cy, sy sx, -sy cx; 0, cx, sx; sy, -cy sx, cy cx] */
	int16_t T[9] = {cy, mul14(sy, sx), (int16_t)-mul14(sy, cx), 0, cx, sx, sy, (int16_t)-mul14(cy, sx), mul14(cy, cx)};
	int16_t R[9];
	for (uint8_t i = 0; i < 9; i += 3) {                    /* R = T * RZ */
		R[i]     = mul14(T[i], cz) - mul14(T[i + 1], sz);
		R[i + 1] = mul14(T[i], sz) + mul14(T[i + 1], cz);
		R[i + 2] = T[i + 2];
	}
	eye[0] = px >> 14; eye[1] = -(vy >> 14); eye[2] = pz >> 14;
	for (uint8_t i = 0; i < 9; i++) Rm[i] = R[i];
}
#endif

#ifdef DBG_CAMERA
void scr_dbg_camera(void) { printf("%ld %ld %ld", (long)eye[0], (long)eye[1], (long)eye[2]); for (int i = 0; i < 9; i++) printf(" %d", Rm[i]); printf("\n"); }
#endif
/* one transformed corner */
typedef struct { int16_t sx, sy, cx, cy, cz; uint8_t fl; } scr_vtx;   /* fl: 1 behind, 2 left, 4 right, 8 extreme y;
                                                     sx, sy exact only when fl == 0 (else saturated) */

/* camera space: c = d @ R >> 14, d in quarter units (int16) */
#ifdef SCR_CAM3_ASM
extern "C" void scr_cam3(int16_t d0, int16_t d1, int16_t d2, int32_t *c);
#define cam3 scr_cam3
#else
NOINL static void cam3(int16_t d0, int16_t d1, int16_t d2, int32_t *c)
{
	for (uint8_t j = 0; j < 3; j++)
		c[j] = ((int32_t)d0 * Rm[j] + (int32_t)d1 * Rm[3 + j] + (int32_t)d2 * Rm[6 + j]) >> 14;
}
#endif

#ifdef SCR_TRANSFORM_ASM
/* in assembly (modelS_transform.S), bit-identical to the C below */
extern "C" void scr_transform(int32_t wx, int32_t wy, int32_t wz, scr_vtx *v);
#define transform scr_transform
static_assert(CX16 == 2048 && CY16 == 880 && XMAX16 == 4088 && ZNEARQ == 2 && YSANE == 30000 &&
              SCR_FX16 == 3994 && SCR_FY16 == 2125, "modelS_transform.S has these constants built in");
static_assert(offsetof(scr_vtx, sx) == 0 && offsetof(scr_vtx, sy) == 2 && offsetof(scr_vtx, cx) == 4 &&
              offsetof(scr_vtx, cy) == 6 && offsetof(scr_vtx, cz) == 8 && offsetof(scr_vtx, fl) == 10,
              "modelS_transform.S expects this scr_vtx layout");
#ifdef __AVR__
static_assert(sizeof(scr_vtx) == 11, "modelS_loadrows.S and modelS_car.S step through arrays of 11-byte scr_vtx");
#endif
#else
static void transform(int32_t wx, int32_t wy, int32_t wz, scr_vtx *v)
{
	int32_t c[3];
	cam3((int16_t)((wx - eye[0]) >> 2), (int16_t)((wy - eye[1]) >> 2), (int16_t)((wz - eye[2]) >> 2), c);
	v->cx = (int16_t)c[0]; v->cy = (int16_t)c[1]; v->cz = (int16_t)c[2];
	v->fl = 0;
	if (v->cz < ZNEARQ) { v->fl = 1; v->sx = v->sy = 0; return; }
	int32_t sx = (int32_t)CX16 + scr_sdiv((int32_t)SCR_FX16 * v->cx, (uint16_t)v->cz);   /* 32-bit sums: int is */
	int32_t sy = (int32_t)CY16 - scr_sdiv((int32_t)SCR_FY16 * v->cy, (uint16_t)v->cz);   /* 16 bits on the AVR */
	if (sx < 0) v->fl |= 2;
	if (sx > XMAX16) v->fl |= 4;
	if (sy > YSANE || sy < -YSANE) v->fl |= 8;            /* extreme y: clip */
	v->sx = (int16_t)(sx > 32000 ? 32000 : sx < -32000 ? -32000 : sx);
	v->sy = (int16_t)(sy > 32000 ? 32000 : sy < -32000 ? -32000 : sy);
}
#endif

#ifdef VIS_STATIC
void scr_dbg_transform(int32_t wx, int32_t wy, int32_t wz, int16_t *o) { scr_vtx v; transform(wx, wy, wz, &v); o[0] = v.sx; o[1] = v.sy; o[2] = v.cx; o[3] = v.cy; o[4] = v.cz; o[5] = v.fl; }
#endif
/* ---- workspace: the rows of one chunk (corners L, R, LB, RB), the clip buffers (cx, cy, cz,
 * planes the vertex lies on); at boot also the SD loader's 512-byte buffer */
union scr_ws_t {
	struct { scr_vtx V[MAXROWS][4]; int16_t pa[21][4], pb[21][4]; } w;
	uint8_t io[512];
};
#ifdef SCR_WS_EXTERN
extern scr_ws_t scr_ws;                                   /* fixed address (scr_bufs.S) */
#else
scr_ws_t scr_ws;
#endif
#define V  (scr_ws.w.V)
#define pa (scr_ws.w.pa)
#define pb (scr_ws.w.pb)
#if defined(SCR_XRAM_OUT) && !defined(SCR_WS_EXTERN)
extern uint8_t scr_io_buffer[] __attribute__((alias("scr_ws")));
#endif

/* ---- edge setup: rows whose centres lie in [ya, yb), X at the first row, slope */
#ifdef SCR_SPIRAM_64K                    /* (the value built into modelS_emit.S) */
#define XRAM_SLOTS_EXPECTED_ 0x06000UL
#else
#define XRAM_SLOTS_EXPECTED_ 0x14000UL
#endif
#if defined(SCR_EMIT_ASM) && defined(SCR_XRAM_OUT) && defined(SCR_FAST_EDGES)
/* edge setup in assembly (modelS_emit.S): the SCR_FAST_EDGES emit() below, bit-identical */
extern "C" void scr_emit(int16_t xa, int16_t ya, int16_t xb, int16_t yb, uint8_t ida, uint8_t idb);
#define emit scr_emit
static_assert(SCR_ROWS == 110 && XMAX16 == 4088 && SCR_NONE == 0xFF && XRAM_SLOTS == XRAM_SLOTS_EXPECTED_,
              "modelS_emit.S has these constants built in");
#else
/* edge setup. Coordinates are Q4 screen values within +-32000 (callers: projected vertices
 * (saturated), clipped outlines (clamped below), the HUD, the sky); the assembly version
 * (modelS_emit.S) relies on it */
NOINL static void emit(int16_t xa16, int16_t ya16, int16_t xb16, int16_t yb16, uint8_t ida, uint8_t idb)
{
	int32_t xa = xa16, ya = ya16, xb = xb16, yb = yb16;
	int32_t t, dx, dy, dX, x0, X, last;
	int16_t r0, r1;
	if (ya == yb) return;
	if (ya > yb) { t = xa; xa = xb; xb = t; t = ya; ya = yb; yb = t; }
	if (xa >= XMAX16 && xb >= XMAX16) return;          /* right border: never needed */
	r0 = (int16_t)((ya + 7) >> 4); r1 = (int16_t)(((yb + 7) >> 4) - 1);
	if (r0 < 0) r0 = 0;
	if (r1 > SCR_ROWS - 1) r1 = SCR_ROWS - 1;
	if (r1 < r0) return;
	dx = xb - xa; dy = yb - ya;
	dX = scr_sdiv(dx * 256 + (dx >= 0 ? (dy >> 1) : -(dy >> 1)), (uint16_t)dy);   /* dy > 0 */   /* dy < 65536 (y clipped) */
	x0 = xa * 16 + tdiv2k(((int32_t)r0 * 16 + 8 - ya) * dX, 4);   /* 8.8 at the first row */
	X = x0 + 127;                                                /* floor((x - 0.5) * 256) + 255 */
	last = X + (int32_t)(r1 - r0) * dX;
	if (X > 65535 || last > 65535) X -= (X > last ? X : last) - 65535;
	if (X < 0 || last < 0) X -= (X < last ? X : last);
#if defined(SCR_XRAM_OUT) && defined(SCR_FAST_EDGES)
#ifndef SCR_XRAM_MAX_EDGES
#define SCR_XRAM_MAX_EDGES 440                  /* slots 1..440 x 9 bytes: XRAM_SLOTS .. +4 KB */
#endif
	static_assert(9 * (SCR_XRAM_MAX_EDGES + 1) <= 4096, "edge slots exceed their SPI RAM area");
	/* SPI RAM: prepend to bucket[r0] (one write, no walk); scr_render_finish() sorts each row
	 * by X >> 8 (stable) and merges identical single-id edges, as the insertion below does */
	{
		uint8_t e[9];
		if (scr_nedges >= SCR_XRAM_MAX_EDGES) { scr_overflow |= 1; return; }
		uint16_t slot = ++scr_nedges;                       /* (merged duplicates still hold a slot) */
		e[0] = (uint8_t)scr_bucket[r0]; e[1] = (uint8_t)(scr_bucket[r0] >> 8);   /* link (the row is known) */
		e[2] = (uint8_t)r1; e[3] = (uint8_t)X; e[4] = (uint8_t)(X >> 8);
		e[5] = (uint8_t)dX; e[6] = (uint8_t)((uint16_t)dX >> 8);
		if (idb != SCR_NONE && idb < ida) { e[7] = idb; e[8] = ida; } else { e[7] = ida; e[8] = idb; }
		xram_write(XRAM_SLOTS + 9 * (uint32_t)slot, e, 9);
		scr_bucket[r0] = slot;
	}
#else
	/* insert into bucket[r0], sorted by X >> 8; merge with an identical single-id edge */
	{
		uint8_t nb, xi = (uint8_t)(X >> 8), e[9];
#ifdef SCR_XRAM_OUT
		uint8_t prev = 0, q[9];                             /* prev 0: the list head is internal */
		nb = scr_bucket[r0];
		while (nb) {
			xram_read(XRAM_SLOTS + 9 * (uint32_t)nb, q, 9);
#else
		uint8_t *link = &scr_bucket[r0];
		while ((nb = *link) != 0) {
			uint8_t *q = &scr_pool[9 * nb];
#endif
			if (q[3] == (uint8_t)X && q[4] == xi && q[2] == (uint8_t)r1 &&
			    q[5] == (uint8_t)dX && q[6] == (uint8_t)((uint16_t)dX >> 8) &&
			    q[8] == SCR_NONE && idb == SCR_NONE && q[7] != ida) {
				if (q[7] < ida) q[8] = ida; else { q[8] = q[7]; q[7] = ida; }
#ifdef SCR_XRAM_OUT
				xram_write(XRAM_SLOTS + 9 * (uint32_t)nb + 7, &q[7], 2);
#endif
				scr_merged++;
				return;
			}
			if (q[4] > xi) break;
#ifdef SCR_XRAM_OUT
			prev = nb; nb = q[0];
#else
			link = &q[0];
#endif
		}
		if (scr_nedges >= SCR_MAX_EDGES) { scr_overflow |= 1; return; }
		uint8_t slot = (uint8_t)++scr_nedges;
		e[0] = nb; e[1] = (uint8_t)r0; e[2] = (uint8_t)r1; e[3] = (uint8_t)X; e[4] = xi;
		e[5] = (uint8_t)dX; e[6] = (uint8_t)((uint16_t)dX >> 8);
		if (idb != SCR_NONE && idb < ida) { e[7] = idb; e[8] = ida; } else { e[7] = ida; e[8] = idb; }
#ifdef SCR_XRAM_OUT
		xram_write(XRAM_SLOTS + 9 * (uint32_t)slot, e, 9);
		if (prev) xram_write(XRAM_SLOTS + 9 * (uint32_t)prev, &slot, 1);
		else scr_bucket[r0] = slot;
#else
		for (uint8_t i = 0; i < 9; i++) scr_pool[9 * slot + i] = e[i];
		*link = slot;
#endif
	}
#endif
}
#endif

static void emit_v(const scr_vtx *a, const scr_vtx *b, uint8_t ida, uint8_t idb)
{
	emit(a->sx, a->sy, b->sx, b->sy, ida, idb);
}

/* ---- clipped outline: in camera space against the near plane and the four screen sides
 * (y with a margin), then projected - all 16/32-bit, coordinates bounded for edge setup */
#define CMAX 21                                 /* 16-vertex outlines + 5 planes */

#ifdef SCR_CLIP_ASM
/* in assembly (modelS_clip.S), bit-identical to plane() and clip_plane() below */
extern "C" uint8_t scr_clip_plane(uint8_t n, uint8_t k, int16_t (*in)[4], int16_t (*out)[4]);
#define clip_plane scr_clip_plane
static_assert(CMAX == 21 && ZNEARQ == 2 && SCR_FX16 == 3994 && SCR_FY16 == 2125 && CX16 == 2048 &&
              XMAX16 == 4088 && CY16 == 880 && YMIN16 == -64 && YMAX16 == 110 * 16 + 64,
              "modelS_clip.S has these constants built in");
#else
static int32_t plane(uint8_t k, const int16_t *v)        /* >= 0: inside */
{
	switch (k) {
	case 0:  return (int32_t)v[2] - ZNEARQ;
	case 1:  return (int32_t)SCR_FX16 * v[0] + (int32_t)CX16 * v[2];                   /* sx >= 0 */
	case 2:  return (int32_t)(XMAX16 - CX16) * v[2] - (int32_t)SCR_FX16 * v[0];        /* sx <= XMAX16 */
	case 3:  return (int32_t)(CY16 - YMIN16) * v[2] - (int32_t)SCR_FY16 * v[1];        /* sy >= YMIN16 */
	default: return (int32_t)SCR_FY16 * v[1] + (int32_t)(YMAX16 - CY16) * v[2];        /* sy <= YMAX16 */
	}
}

static uint8_t clip_plane(uint8_t n, uint8_t k, int16_t (*in)[4], int16_t (*out)[4])
{
	uint8_t m = 0;
	int32_t fb = n ? plane(k, in[0]) : 0;                 /* each vertex evaluated once: fa = last fb */
	for (uint8_t i = 0; i < n; i++) {
		uint8_t j = (i + 1 == n) ? 0 : i + 1;
		int32_t fa = fb;
		fb = plane(k, in[j]);
		if (fa >= 0 && m < CMAX) { out[m][0] = in[i][0]; out[m][1] = in[i][1]; out[m][2] = in[i][2]; out[m][3] = in[i][3]; m++; }
		if ((fa >= 0) != (fb >= 0) && m < CMAX) {
			int32_t den = fa - fb, num = fa;                    /* t = fa / (fa - fb) in [0, 1] */
			if (den < 0) { den = -den; num = -num; }
			while (den > 32767) { den >>= 1; num >>= 1; }
			int16_t t = scr_sdiv(num << 14, (uint16_t)den);     /* Q14 */
			for (uint8_t c = 0; c < 3; c++)
				out[m][c] = in[i][c] + (int16_t)((((int32_t)in[j][c] - in[i][c]) * t) >> 14);
			out[m][3] = (in[i][3] & in[j][3]) | (1 << k);       /* on plane k (and on shared ones) */
			m++;
		}
	}
	return m;
}
#endif

#ifdef SCR_EMITCLIP_ASM
/* in assembly (modelS_emitclip.S: scr_clip_plane, sdiv32_16, scr_emit), bit-identical to the C */
extern "C" void scr_emit_clipped(const scr_vtx *const *poly, uint8_t n, uint8_t id, int16_t (*a)[4], int16_t (*b)[4]);
#define emit_clipped(poly, n, id) scr_emit_clipped(poly, n, id, pa, pb)
static_assert(CMAX == 21 && ZNEARQ == 2 && SCR_FX16 == 3994 && SCR_FY16 == 2125 && CX16 == 2048 && XMAX16 == 4088 &&
              CY16 == 880 && YMIN16 == -64 && YMAX16 == 110 * 16 + 64 && SCR_NONE == 0xFF, "modelS_emitclip.S has these built in");
#else
static void emit_clipped(const scr_vtx *const *poly, uint8_t n, uint8_t id)
{
	uint8_t m, k;
	if (n > CMAX) n = CMAX;
	for (k = 0; k < n; k++) { pa[k][0] = poly[k]->cx; pa[k][1] = poly[k]->cy; pa[k][2] = poly[k]->cz; pa[k][3] = 0; }
	m = n;
	for (k = 0; k < 5 && m >= 3; k++) m = (k & 1) ? clip_plane(m, k, pb, pa) : clip_plane(m, k, pa, pb);
	if (m < 3) return;                                      /* result in pb (5 planes: odd count) */
	int32_t x0 = 0, y0 = 0, xp = 0, yp = 0;
	for (k = 0; k <= m; k++) {
		const int16_t *v = pb[k == m ? 0 : k];
		uint16_t z = (uint16_t)(v[2] < ZNEARQ ? ZNEARQ : v[2]);
		int32_t x = (int32_t)CX16 + scr_sdiv((int32_t)SCR_FX16 * v[0], z);
		int32_t y = (int32_t)CY16 - scr_sdiv((int32_t)SCR_FY16 * v[1], z);
		if (x < 0 || (v[3] & 2)) x = 0;                         /* exactly on the borders */
		if (x > XMAX16 || (v[3] & 4)) x = XMAX16;
		if (v[3] & 8) y = YMIN16;
		if (v[3] & 16) y = YMAX16;
		if (y > 32000) y = 32000;                               /* (emit's contract; never reached in practice) */
		if (y < -32000) y = -32000;
		if (k == 0) { x0 = x; y0 = y; } else emit((int16_t)xp, (int16_t)yp, (int16_t)x, (int16_t)y, id, SCR_NONE);
		xp = x; yp = y;
	}
	(void)x0; (void)y0;
}
#endif


#ifdef DBG_REGIONS
long dbg_piece[SCR_MAX_REGIONS]; char dbg_kind[SCR_MAX_REGIONS]; static long dbg_cur_piece; static char dbg_cur_kind;
#endif
NOINL static uint8_t new_region(uint8_t colour)
{
#ifdef DBG_REGIONS
	dbg_piece[scr_nregions] = dbg_cur_piece; dbg_kind[scr_nregions] = dbg_cur_kind;
#endif
	if (scr_nregions >= SCR_MAX_REGIONS) { scr_overflow |= 2; return SCR_NONE; }
#ifdef SCR_XRAM_OUT
	xram_write(out_base + SCR_STREAM_COLOURS + scr_nregions, &colour, 1);
#else
	scr_colours[scr_nregions] = colour;
#endif
	return (uint8_t)scr_nregions++;
}

static uint8_t simple(const scr_vtx *const *poly, uint8_t n)
{
#ifdef NOSHARE
	(void)poly; (void)n; return 0;                          /* debug: every region clipped/own outline */
#endif
	for (uint8_t k = 0; k < n; k++) if (poly[k]->fl) return 0;
	return 1;
}

/* colour of the remake's palette index (SCR_BASE_COLOUR + n) in the Uzebox palette */
extern const uint8_t scr_palette[23];
__attribute__((noinline)) static uint8_t pal(long idx) { return RD8(&scr_palette[idx - SCR_BASE_COLOUR]); }

/* ---- one piece */


NOINL static void draw_rows(long p, const uint8_t *rows, uint8_t nr, uint8_t what);
#define SIDES 1
#define ROAD  2
#define THIN  4                      /* skip the walls if they are thin on screen */


/* the rows of a chunk into V (camera space, projected); returns the AND of their flags */
#ifdef SCR_LOADROWS_ASM
/* in assembly (modelS_loadrows.S: scr_piece_rows_asm + scr_transform), bit-identical to the C */
extern "C" uint8_t scr_load_rows(long p, const uint8_t *rows, uint8_t nr, scr_vtx (*v)[4]);
static inline uint8_t load_rows(long p, const uint8_t *rows, uint8_t nr) { return scr_load_rows(p, rows, nr, V); }
#else
NOINL static uint8_t load_rows(long p, const uint8_t *rows, uint8_t nr)
{
	long cx = Track[p].x << 12, cz = Track[p].z << 12;
	uint8_t all = 0xFF;
	for (uint8_t k = 0; k < nr; k++) {
		COORD_3D C[1][4];
		scr_piece_rows(p, &rows[k], 1, C);
		for (uint8_t j = 0; j < 4; j++) {
			transform(cx + C[0][j].x, tdiv2k(C[0][j].y, 2), cz + C[0][j].z, &V[k][j]);
			all &= V[k][j].fl;
		}
	}
	return all;
}
#endif

/* the camera depth of a row's left corner (through load_rows: V is reloaded by draw_rows); the
 * farther chunk of a near piece is the one whose middle row is deeper (as accurate against the
 * z-buffer as the squared distance it replaces, and smaller) */
NOINL static int16_t row_depth(long p, uint8_t row)
{
	load_rows(p, &row, 1);
	return V[0][0].cz;
}

/* a piece: its rows (every `step` segments + the last); near pieces in two chunks of at most
 * MAXROWS rows sharing the seam row, the farther chunk first */
NOINL static void draw_piece(long p, uint8_t step, uint8_t walls)
{
	long ns = Track[p].numSegments;
	uint8_t rows[14], nr = 0;
	for (long r = 0; r < ns; r += step) rows[nr++] = (uint8_t)r;
	rows[nr++] = (uint8_t)ns;
	if (nr <= MAXROWS) { draw_rows(p, rows, nr, walls ? SIDES | ROAD : (SIDES | ROAD | THIN)); return; }
	/* chunks rows[0..CHUNK-1] and rows[CHUNK-1..nr-1]: which middle row is farther? */
	int16_t da = row_depth(p, rows[(CHUNK - 1) / 2]), db = row_depth(p, rows[(CHUNK - 1 + nr - 1) / 2]);
	/* as unchunked: all the walls first, then the road (farther chunk first); the edges the
	 * two passes share are merged on insertion */
	const uint8_t *f = rows, *q = rows + CHUNK - 1;
	uint8_t nf = CHUNK, nq = nr - CHUNK + 1;
	if (da < db) { f = q; q = rows; nf = nq; nq = CHUNK; }
	draw_rows(p, f, nf, SIDES); draw_rows(p, q, nq, SIDES);
	draw_rows(p, f, nf, ROAD);  draw_rows(p, q, nq, ROAD);
}

NOINL static void draw_rows(long p, const uint8_t *rows, uint8_t nr, uint8_t what)
{
	const ScrPiece &tp = Track[p];
	long ns = tp.numSegments, cx = tp.x << 12, cz = tp.z << 12;
	uint8_t k, j;
#ifdef DBG_TP
	if (p == 43) { printf("start: "); for (int i = 0; i < ns; i++) printf("%d ", tp.roadColour[i]); printf("(ns %ld)\n", ns); }
#endif
	uint8_t all = load_rows(p, rows, nr);
	if (what & THIN) {                                      /* walls under SCR_THIN_WALL (Q4 rows) high */
		int16_t h = 0;                                      /* on screen everywhere: not drawn */
		for (k = 0; k < nr; k++)
			for (j = 0; j < 2; j++) {
				if (V[k][j].fl | V[k][j + 2].fl) { h = 0x7FFF; break; }   /* clipped: keep */
				int16_t d = V[k][j + 2].sy - V[k][j].sy;
				if (d < 0) d = -d;
				if (d > h) h = d;
			}
		if (h < SCR_THIN_WALL) what &= ~SIDES;
	}
	if (all & 7) return;                                    /* entirely behind or beside */
#ifdef DBG_TP
	if (p == 43) { printf("after transform: "); for (int i = 0; i < ns; i++) printf("%d ", tp.roadColour[i]); printf("\n"); }
#endif
	/* road colours per drawn segment, and the runs */
	uint8_t col[MAXROWS], nseg = nr - 1;
	for (k = 0; k < nseg; k++) {
		uint8_t s0 = rows[k], s1 = rows[k + 1];
		long c = tp.roadColour[s0];
		if (s1 - s0 > 1) {
			uint8_t same = 1;
			for (uint8_t s = s0; s < s1; s++) if (tp.roadColour[s] != tp.roadColour[s0]) same = 0;
			if (!same) c = tp.roadColour[s0 + (s1 - s0) / 2];
		}
		col[k] = pal(c);
	}
	/* regions: left side, right side, then road runs far -> near */
#ifdef DBG_REGIONS
	dbg_cur_piece = p; dbg_cur_kind = 'S';
#endif
	uint8_t idL = SCR_NONE, idR = SCR_NONE;
	if (what & SIDES) { idL = new_region(pal(tp.sidesColour)); idR = new_region(pal(tp.sidesColour)); }
#ifdef DBG_REGIONS
	dbg_cur_kind = 'R';
#endif
	uint8_t rs[MAXROWS], re[MAXROWS], nrun = 0;            /* run = segments rs..re */
	for (k = (what & ROAD) ? 0 : nseg; k < nseg; ) {
		j = k;
		while (j + 1 < nseg && col[j + 1] == col[k]) j++;
		rs[nrun] = k; re[nrun] = j; nrun++;
		k = j + 1;
	}
	/* run distance: squared distance of its middle row's left corner, far first */
	uint8_t ord[MAXROWS], rid[MAXROWS];
	uint16_t dist[MAXROWS];
	for (k = 0; k < nrun; k++) {                            /* run centre: L, R of its first and last rows */
		const scr_vtx *a0 = &V[rs[k]][0], *a1 = &V[rs[k]][1], *b0 = &V[re[k] + 1][0], *b1 = &V[re[k] + 1][1];
		int32_t sx = ((int32_t)a0->cx + a1->cx + b0->cx + b1->cx) >> 10;  /* mean, >> 8: 16-bit squares */
		int32_t sy = ((int32_t)a0->cy + a1->cy + b0->cy + b1->cy) >> 10;
		int32_t sz = ((int32_t)a0->cz + a1->cz + b0->cz + b1->cz) >> 10;
		int32_t dd = sx * sx + sy * sy + sz * sz;
		dist[k] = (uint16_t)(dd > 65535 ? 65535 : dd);
		ord[k] = k;
	}
	for (k = 1; k < nrun; k++)                               /* insertion sort, far first */
		for (j = k; j > 0 && dist[ord[j - 1]] < dist[ord[j]]; j--) { uint8_t t = ord[j]; ord[j] = ord[j - 1]; ord[j - 1] = t; }
#ifdef DBG_RUNS
	for (k = 0; k < nrun; k++) printf("piece %ld step %d run %d segs %d..%d colour %d dist %ld\n", p, step, k, rs[k], re[k], col[rs[k]], (long)dist[k]);
#endif
	for (k = 0; k < nrun; k++) rid[ord[k]] = new_region(col[rs[ord[k]]]);   /* the run's colour */
#ifdef DBG_RUNS
	for (k = 0; k < nrun; k++) printf("  run %d -> region %d colour %d\n", k, rid[k], scr_colours[rid[k]]);
#endif
	/* simplicity (no clipping needed) of each region */
	const scr_vtx *poly[2 * MAXROWS];
	uint8_t n;
	uint8_t sL = 0, sR = 0;
	if (what & SIDES) {
		n = 0; for (k = 0; k < nr; k++) poly[n++] = &V[k][0]; for (k = nr; k-- > 0; ) poly[n++] = &V[k][2];
		sL = simple(poly, n); if (!sL) emit_clipped(poly, n, idL);
		n = 0; for (k = 0; k < nr; k++) poly[n++] = &V[k][1]; for (k = nr; k-- > 0; ) poly[n++] = &V[k][3];
		sR = simple(poly, n); if (!sR) emit_clipped(poly, n, idR);
	}
	uint8_t sRun[MAXROWS];
	for (k = 0; k < nrun; k++) {
		n = 0;
		for (j = rs[k]; j <= re[k] + 1; j++) poly[n++] = &V[j][0];
		for (j = re[k] + 2; j-- > rs[k]; ) poly[n++] = &V[j][1];
		sRun[k] = simple(poly, n);
		if (!sRun[k]) emit_clipped(poly, n, rid[k]);
	}
	/* edges of the simple regions; shared ones once with both ids */
	if (sL) {                                               /* left side: bottom, ends, top */
		for (k = 0; k + 1 < nr; k++) emit_v(&V[k][2], &V[k + 1][2], idL, SCR_NONE);
		emit_v(&V[0][0], &V[0][2], idL, SCR_NONE);
		emit_v(&V[nr - 1][0], &V[nr - 1][2], idL, SCR_NONE);
	}
	if (sR) {
		for (k = 0; k + 1 < nr; k++) emit_v(&V[k][3], &V[k + 1][3], idR, SCR_NONE);
		emit_v(&V[0][1], &V[0][3], idR, SCR_NONE);
		emit_v(&V[nr - 1][1], &V[nr - 1][3], idR, SCR_NONE);
	}
	for (k = 0; k < nseg; k++) {                            /* road edge segments, left and right */
		uint8_t r = 0, a = SCR_NONE;
		if (nrun) {
			while (!(rs[r] <= k && k <= re[r])) r++;
			if (sRun[r]) a = rid[r];
		}
		uint8_t bL = sL ? idL : SCR_NONE, bR = sR ? idR : SCR_NONE;
		if (a != SCR_NONE || bL != SCR_NONE) emit_v(&V[k][0], &V[k + 1][0], a != SCR_NONE ? a : bL, a != SCR_NONE ? bL : SCR_NONE);
		if (a != SCR_NONE || bR != SCR_NONE) emit_v(&V[k][1], &V[k + 1][1], a != SCR_NONE ? a : bR, a != SCR_NONE ? bR : SCR_NONE);
	}
	for (k = 0; k < nrun; k++) {                            /* row edges: run start / end */
		if (!sRun[k]) continue;
		uint8_t prev = (k > 0 && sRun[k - 1]) ? rid[k - 1] : SCR_NONE;
		emit_v(&V[rs[k]][0], &V[rs[k]][1], rid[k], prev);     /* shared with the previous run */
		if (k + 1 == nrun || !sRun[k + 1])
			emit_v(&V[re[k] + 1][0], &V[re[k] + 1][1], rid[k], SCR_NONE);
	}
}

/* ---- ground: the plane y = 0 as one big quad around the eye (region 0, drawn first).
 * Scaled by 1/16 (projection is scale-free) so that it fits the 16-bit camera path. */
NOINL static void draw_ground(void)
{
	static const int8_t sgn[4][2] = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
	scr_vtx g[4];
	int16_t dy = (int16_t)((0 - eye[1]) >> 6);
	for (uint8_t k = 0; k < 4; k++) {
		int32_t c[3];
		cam3(sgn[k][0] * 16384, dy, sgn[k][1] * 16384, c);
		g[k].cx = (int16_t)c[0]; g[k].cy = (int16_t)c[1]; g[k].cz = (int16_t)c[2]; g[k].fl = 1;
	}
	const scr_vtx *poly[4] = {&g[0], &g[1], &g[2], &g[3]};
	emit_clipped(poly, 4, new_region(RD8(&scr_palette[22])));   /* ground colour after the 22 track colours */
}

/* ---- frame */
#ifdef VIS_STATIC
static uint8_t *dbg_vis;
uint8_t *scr_dbg_vis(void) { return dbg_vis; }
#endif
/* ---- the opponent: its silhouette as a screen-aligned rectangle (the remake's car model is
 * 162 x 81 x 256 units): centred on the car, sized by perspective, the width by its heading
 * relative to the view (81 |cos| + 128 |sin|). Drawn right after the piece the car is on
 * (painter order: over its road, under nearer pieces). Two edges, like a HUD bar. */
long scr_opp[8] = {0, 0, 0, 0, -1};          /* x, y, z (game units), heading relative to the view, piece */
#ifndef SCR_NO_OPP
extern short Trig_Coeffs[];
void CalcYXZTrigCoefficients(long x_angle, long y_angle, long z_angle);
#ifndef SCR_CAR_BACK
#define SCR_CAR_BACK 0                  /* back-face test: 0 culls a cross product <= 0 (checked on screen), 1 >= 0 */
#endif
#ifndef SCR_OPP_RECT
/* the opponent's car: the remake's model (Car.cpp: VCAR_WIDTH 162, VCAR_LENGTH 256, VCAR_HEIGHT
 * 162), oriented as the remake places it - Rz(z angle) Rx(x angle) Ry(y angle), row vectors -
 * and raised by VCAR_HEIGHT / 4. Points x, y, z / 2 (to fit a byte): 4 wheels, then the body */
#ifdef SCR_CARV_ASM
extern "C" { extern const int8_t car_pts_flash[24][3]; }   /* (extern: C++ const is internal) */
#define car_pts car_pts_flash
extern "C" const int8_t car_pts_flash[24][3] PROGMEM = {
#else
static const int8_t car_pts[24][3] PROGMEM = {
#endif
	{-81, -40, -64}, {-81, 0, -64}, {-40, 0, -64}, {-40, -40, -64},     /* rear wheels */
	{ 40, -40, -64}, { 40, 0, -64}, { 81, 0, -64}, { 81, -40, -64},
	{-81, -40,  64}, {-81, 0,  64}, {-40, 0,  64}, {-40, -40,  64},     /* front wheels */
	{ 40, -40,  64}, { 40, 0,  64}, { 81, 0,  64}, { 81, -40,  64},
	{-40, -20, -64}, {-30, 40, -64}, { 30, 40, -64}, { 40, -20, -64},   /* body: rear */
	{-40, -20,  64}, {-40,  0,  64}, { 40,  0,  64}, { 40, -20,  64}};  /*       front */
/* quads (the remake's triangle pairs) and colours (palette index); 0 .. 3 the wheels (both
 * sides), 4 .. 9 the body: left, right, back, front, top, bottom */
static const uint8_t car_faces[10][5] PROGMEM = {
	{0, 1, 2, 3, 0}, {4, 5, 6, 7, 0}, {8, 9, 10, 11, 0}, {12, 13, 14, 15, 0},
	{20, 21, 17, 16, 12}, {19, 18, 22, 23, 12}, {16, 17, 18, 19, 10}, {23, 22, 21, 20, 10},
	{17, 21, 22, 18, 15}, {19, 23, 20, 16, 9}};

/* a face: visible from the eye (camera space: the quad's diagonals' normal against a vertex),
 * then drawn; wheels both sides (vis 0) */
NOINL static void car_face(uint8_t f, uint8_t vis)
{
	const scr_vtx *q[4];
	uint8_t k, behind = 0;
	for (k = 0; k < 4; k++) { q[k] = &V[0][0] + RD8(&car_faces[f][k]); behind |= q[k]->fl; }
	if (vis && !(behind & 1)) {             /* on screen: the projected diagonals' cross product */
		int16_t a0 = (q[2]->sx >> 1) - (q[0]->sx >> 1), a1 = (q[2]->sy >> 1) - (q[0]->sy >> 1);
		int16_t b0 = (q[3]->sx >> 1) - (q[1]->sx >> 1), b1 = (q[3]->sy >> 1) - (q[1]->sy >> 1);
		int32_t cr = (int32_t)a0 * b1 - (int32_t)a1 * b0;
#if SCR_CAR_BACK
		if (cr >= 0) return;
#else
		if (cr <= 0) return;
#endif
	}
	emit_clipped(q, 4, new_region(pal(SCR_BASE_COLOUR + RD8(&car_faces[f][4]))));
}

#ifdef SCR_CARV_ASM
/* in assembly (modelS_car.S): v[i] = transform(t + car_pts[i] M), i = 0 .. 23 */
extern "C" void scr_car_vertices(const int16_t *M, const int32_t *t, scr_vtx *v);
#else
NOINL static int32_t car_dot(const int16_t *p, const int16_t *m)   /* (point) . (column of M), Q14 */
{
	return ((int32_t)p[0] * m[0] + (int32_t)p[1] * m[3] + (int32_t)p[2] * m[6]) >> 14;
}
static void scr_car_vertices(const int16_t *M, const int32_t *t, scr_vtx *v)
{
	const int8_t *pp = &car_pts[0][0];
	for (uint8_t i = 0; i < 24; i++, v++) {
		int16_t pt[3];
		pt[0] = (int8_t)RD8(pp++); pt[1] = (int8_t)RD8(pp++); pt[2] = 2 * (int8_t)RD8(pp++);
		transform(t[0] + car_dot(pt, M), t[1] + car_dot(pt, M + 1), t[2] + car_dot(pt, M + 2), v);
	}
}
#endif

NOINL static int16_t car_depth(const scr_vtx *v, uint8_t n)   /* mean cz of n (4 or 8) points */
{
	int16_t z = 0;
	for (uint8_t i = 0; i < n; i++) z += v[i].cz >> 3;
	return n == 4 ? 2 * z : z;
}

NOINL static void draw_opponent(void)
{
	/* the orientation: the physics' own rotation (CalcYXZTrigCoefficients: Rz Rx Ry in its y-down
	 * frame) for the opponent's angles, flipped to y up (the camera's 0xAA mask); the physics'
	 * coefficients are kept */
	int16_t M[9], keep[9];
	int32_t t[3];
	uint8_t i, f;
	memcpy(keep, Trig_Coeffs, sizeof(keep));
	CalcYXZTrigCoefficients(scr_opp[5], scr_opp[6], scr_opp[7]);
	for (i = 0; i < 9; i++) M[i] = ((0xAA >> i) & 1) ? -Trig_Coeffs[i] : Trig_Coeffs[i];
	memcpy(Trig_Coeffs, keep, sizeof(keep));
	for (i = 0; i < 3; i++) t[i] = scr_opp[i] >> 14;
	t[1] = 40 - t[1];                                       /* y up, raised by VCAR_HEIGHT / 4 */
	scr_vtx *v = &V[0][0];
	scr_car_vertices(M, t, v);
	int16_t zb = car_depth(v + 16, 8);                      /* the body's centre */
	/* the wheels behind the body's centre, the body (back faces culled), the wheels in front */
	for (f = 0; f < 4; f++) if (car_depth(v + 4 * f, 4) > zb) car_face(f, 0);
	for (f = 4; f < 10; f++) car_face(f, 1);
	for (f = 0; f < 4; f++) if (car_depth(v + 4 * f, 4) <= zb) car_face(f, 0);
}
#else
NOINL static void draw_opponent(void)
{
	scr_vtx v;
	transform(scr_opp[0] >> 14, 40 - (scr_opp[1] >> 14), scr_opp[2] >> 14, &v);   /* centre */
	if (v.fl & 1) return;                                   /* behind the eye */
#ifdef SCR_OPP_FIXED_W
	int16_t hw = 26;                                        /* ~105 units: the average silhouette */
#else
	int16_t s = scr_sin(scr_opp[3]), c = scr_sin(scr_opp[3] + 16384);
	if (s < 0) s = -s;
	if (c < 0) c = -c;
	int16_t hw = (int16_t)(((int32_t)81 * c + (int32_t)128 * s) >> 16);   /* half width, quarter units */
#endif
	int16_t w = scr_sdiv((int32_t)SCR_FX16 * hw, (uint16_t)v.cz), h = scr_sdiv((int32_t)SCR_FY16 * 10, (uint16_t)v.cz);
	if (w > 4096) w = 4096;
	if (h > 2048) h = 2048;
	int16_t x0 = v.sx - w, x1 = v.sx + w, y0 = v.sy - h, y1 = v.sy + h;   /* (|sx|, |sy| <= 32000: no overflow) */
	if (x0 < 0) x0 = 0;
	if (x1 > XMAX16) x1 = XMAX16;
	if (y0 < YMIN16) y0 = YMIN16;
	if (y1 > YMAX16) y1 = YMAX16;
	if (x1 <= x0 || y1 <= y0) return;
	uint8_t id = new_region(SCR_OPP_SIDE);
	emit(x0, y0, x0, y1, id, SCR_NONE);
	emit(x1, y0, x1, y1, id, SCR_NONE);
}
#endif
#endif

/* sound off (the game sets scr_mute): bottom right, a left-facing triangle with a cross over
 * it - three regions in front of everything, 7 edges (Q4 screen units: x * 16, rows * 16) */
extern "C" { uint8_t scr_mute; }
/* edges: x0, row0, x1, row1 (x in pixels, rows in half rows), a new region before edges 0, 3, 5 */
static const uint8_t mute_edges[7][4] PROGMEM = {
	{249, 196, 249, 214}, {249, 196, 239, 205}, {239, 205, 249, 214},       /* triangle, pointing left */
	{236, 194, 252, 216}, {238, 194, 254, 216},                             /* bar \ (x + 2) */
	{252, 194, 236, 216}, {254, 194, 238, 216}};                            /* bar / */
NOINL static void draw_mute(void)
{
	uint8_t id = 0;
	for (uint8_t k = 0; k < 7; k++) {
		if (k == 0 || k == 3 || k == 5) id = new_region(k ? 0x07 : 0xFE);   /* white, then red bars */
		const uint8_t *e = mute_edges[k];
		emit((int16_t)(RD8(e) * 16), (int16_t)(RD8(e + 1) * 8), (int16_t)(RD8(e + 2) * 16), (int16_t)(RD8(e + 3) * 8), id, SCR_NONE);
	}
}

/* HUD: each rectangle one region, frontmost (emitted last), two vertical edges */
static void draw_hud(void)
{
	if (scr_mute) draw_mute();
	for (uint8_t i = 0; i < scr_hud_n; i++) {
		const scr_rect_t *r = &scr_hud[i];
		uint8_t id = new_region(r->colour);
		emit((int16_t)(r->x0 * 16), (int16_t)(r->y0 * 16), (int16_t)(r->x0 * 16), (int16_t)((r->y1 + 1) * 16), id, SCR_NONE);
		emit((int16_t)((r->x1 + 1) * 16), (int16_t)(r->y0 * 16), (int16_t)((r->x1 + 1) * 16), (int16_t)((r->y1 + 1) * 16), id, SCR_NONE);
	}
}

/* the far-road painter key of a point: 16 + its distance from the eye in units of 512 */
NOINL static uint8_t far_key(int32_t wx, int32_t wy, int32_t wz)
{
	int32_t d0 = (wx - eye[0]) >> 7, d1 = (wy - eye[1]) >> 7, d2 = (wz - eye[2]) >> 7;
	uint16_t dist = (uint16_t)(scr_isqrt((unsigned long)(d0 * d0 + d1 * d1 + d2 * d2)) >> 2);
	return dist > 239 ? 255 : (uint8_t)(16 + dist);
}

#ifdef SCR_XRAM_OUT
/* the lists -> the rasterizer's stream at out_base: colours, row mask, then per row with new
 * edges: count, count x [y1, X lo, X hi, dX lo, dX hi, idA, idB] (sorted by X) */
#ifdef SCR_FAST_EDGES
/* the edges of one row (or of an X window of it) -> its records, at buf: read the chain
 * (newest first) keeping X >> 12 in [lo, hi], in emission order; merge each single-id edge into
 * the first earlier kept edge of equal X >> 8 that is identical and single-id (as the sorted
 * insertion of the internal path does), else insert it stable by X >> 8; then pack the records
 * [y1 X dX idA idB] at buf + 1. Returns their number; *full: the window did not fit */
#define FCAP ((uint8_t)(sizeof(scr_ws) / 9))
NOINL static uint8_t finish_window(uint16_t s, uint8_t lo, uint8_t hi, uint8_t *buf, uint8_t *full)
{
	uint8_t m = 0, n = 0, k, j, q[9];
	*full = 0;
	for (uint16_t t = s; t; ) {                             /* read: newest first, at the top end */
		xram_read(XRAM_SLOTS + 9 * (uint32_t)t, q, 9);
		t = q[0] | ((uint16_t)q[1] << 8);
		uint8_t b = q[4] >> 4;
		if (b < lo || b > hi) continue;
		if (m == FCAP) { *full = 1; break; }
		memcpy(buf + 9 * (FCAP - 1 - m), q, 9); m++;       /* emission order from FCAP - m */
	}
	uint8_t *src = buf + 9 * (FCAP - m);
	for (k = 0; k < m; k++, src += 9) {
		if (src[8] == SCR_NONE) {
			for (j = 0; j < n; j++) {
				uint8_t *e = buf + 9 * j;
				if (e[4] > src[4]) break;
				if (!memcmp(e + 2, src + 2, 5) && e[8] == SCR_NONE && e[7] != src[7]) {
					if (e[7] < src[7]) e[8] = src[7]; else { e[8] = e[7]; e[7] = src[7]; }
					scr_merged++; goto next;
				}
			}
		}
		memcpy(q, src, 9);                                  /* (src may be overwritten below) */
		for (j = n; j > 0 && buf[9 * (j - 1) + 4] > q[4]; j--) ;
		memmove(buf + 9 * (j + 1), buf + 9 * j, 9 * (n - j));
		memcpy(buf + 9 * j, q, 9);
		n++;
	next: ;
	}
	for (k = 0; k < n; k++) memmove(buf + 1 + 7 * k, buf + 9 * k + 2, 7);   /* pack (downwards) */
	return n;
}

/* the lists -> the rasterizer's stream at out_base: colours, row mask, then per row with new
 * edges: count, count x [y1, X lo, X hi, dX lo, dX hi, idA, idB] (sorted by X) */
static void scr_render_finish(void)
{
	uint32_t w = out_base + SCR_STREAM_RECORDS;
	uint8_t mask[SCR_ROWS / 8 + 1], full;
	uint8_t *buf = (uint8_t *)&scr_ws;                      /* (the renderer is done with it) */
	for (uint8_t i = 0; i < sizeof(mask); i++) mask[i] = 0;
	for (uint8_t r = 0; r < SCR_ROWS; r++) {
		uint16_t s = scr_bucket[r];
		if (!s) continue;
		mask[r >> 3] |= (uint8_t)(1 << (r & 7));
		uint8_t n = finish_window(s, 0, 15, buf, &full);
		if (!full) {                                        /* the usual case: the whole row at once */
			buf[0] = n;
			xram_write(w, buf, (uint16_t)1 + 7 * n);
			w += 1 + 7 * (uint32_t)n;
			continue;
		}
		/* a crowded row: in windows of X (X >> 12 ranges; a merge never spans two), each window
		 * as wide as fits (a single range of more than FCAP edges would be cut) */
		uint32_t cnt_at = w++;
		n = 0;
		for (uint8_t lo = 0, hi; lo < 16; lo = hi + 1) {
			for (hi = 15; hi > lo; hi--) {                  /* the widest window that fits */
				finish_window(s, lo, hi, buf, &full);
				if (!full) break;
			}
			uint8_t nw = finish_window(s, lo, hi, buf, &full);
			xram_write(w, buf + 1, (uint16_t)7 * nw);
			w += 7 * (uint32_t)nw; n += nw;
		}
		xram_write(cnt_at, &n, 1);
	}
	xram_write(out_base + SCR_STREAM_MASK, mask, sizeof(mask));
}
#else
/* the lists -> the rasterizer's stream at out_base: colours, row mask, then per row with new
 * edges: count, count x [y1, X lo, X hi, dX lo, dX hi, idA, idB] (sorted by X) */
static void scr_render_finish(void)
{
	uint32_t w = out_base + SCR_STREAM_RECORDS;
	uint8_t mask[SCR_ROWS / 8 + 1], q[9];
	for (uint8_t i = 0; i < sizeof(mask); i++) mask[i] = 0;
	for (uint8_t r = 0; r < SCR_ROWS; r++) {
		uint8_t s = scr_bucket[r], n = 0;
		if (!s) continue;
		uint32_t cnt_at = w++;
		mask[r >> 3] |= (uint8_t)(1 << (r & 7));
		while (s) {
			xram_read(XRAM_SLOTS + 9 * (uint32_t)s, q, 9);
			xram_write(w, &q[2], 7);
			w += 7; n++;
			s = q[0];
		}
		xram_write(cnt_at, &n, 1);
	}
	xram_write(out_base + SCR_STREAM_MASK, mask, sizeof(mask));
}
#endif

NOINL static void render_frame(long cur_piece);
void scr_render_frame(long cur_piece, uint32_t base)
{
	out_base = base;
	render_frame(cur_piece);
	draw_hud();
	scr_render_finish();
}
NOINL static void render_frame(long cur_piece)
#else
void scr_render_frame(long cur_piece)
#endif
{
	long n = NumTrackPieces, p;
	uint8_t ord[SCR_MAX_VIS], nv = 0;                     /* visible pieces only */
	uint8_t key[SCR_MAX_VIS];                             /* larger = drawn earlier */
	scr_nedges = 0; scr_nregions = 0; scr_overflow = 0; scr_merged = 0;
	for (p = 0; p < SCR_ROWS; p++) scr_bucket[p] = 0;
	{	/* sky: one region over the whole picture (the rasterizer's background is colour 0):
		 * a single edge down the left border */
		uint8_t id = new_region(SCR_SKY);
		emit(0, YMIN16, 0, YMAX16, id, SCR_NONE);
	}
	draw_ground();
	uint8_t *rec = (uint8_t *)&scr_ws;                     /* (the workspace is free until drawing) */
	for (p = 0; p < n; p++) {                               /* bounding spheres: culling and key */
		if ((p & 7) == 0) scr_piece_records(p, (uint8_t)(n - p < 8 ? n - p : 8), rec);   /* 8 per read */
		const uint8_t *q = rec + 16 * (p & 7);             /* (as scr_piece_sphere) */
		long wx = ((long)(q[0] & 0x0f) << 12) + (long)(int8_t)q[12] * 64, wy = (long)q[13] * 64;
		long wz = ((long)(q[0] >> 4) << 12) + (long)(int8_t)q[14] * 64, rad = (long)q[15] * 64;
		/* sphere vs near plane and the four frustum sides (quarter units; radius + 1/8 margin) */
		int16_t e0 = (int16_t)((wx - eye[0]) >> 2), e1 = (int16_t)((wy - eye[1]) >> 2), e2 = (int16_t)((wz - eye[2]) >> 2);
		int32_t r = (rad >> 2) + (rad >> 5);
		/* depth first - cam3's z component, the same arithmetic: about half the pieces are behind */
		if ((((int32_t)e0 * Rm[2] + (int32_t)e1 * Rm[5] + (int32_t)e2 * Rm[8]) >> 14) + r < ZNEARQ) continue;
		int32_t cc[3];
		cam3(e0, e1, e2, cc);
		int32_t c0 = cc[0], c1 = cc[1], c2 = cc[2];
		if (c2 + r < ZNEARQ ||
		    ((c0 < 0 ? -c0 : c0) - r) * (int32_t)SCR_FX16 > c2 * (int32_t)CX16 ||
		    ((c1 < 0 ? -c1 : c1) - r) * (int32_t)SCR_FY16 > c2 * (int32_t)CY16) continue;
		/* painter key: the far road by distance; then (as the original) the near road in road
		 * order towards the car, after all the far road, the car's own piece last */
		long f = p - cur_piece, d;                            /* forward distance 0..n-1, no % */
		if (f < 0) f += n;
		d = (n - f < f) ? n - f : f;
		/* far road: 16 + distance in units of 512 (8 bits); near road: 0..5,
		 * further along the track first, the car's own piece last */
		uint8_t k = (d <= SCR_NEAR) ? (uint8_t)(d * 2 + (f > (n >> 1))) : far_key(wx, wy, wz);
		if (nv == SCR_MAX_VIS) {        /* full: keep the nearest (pieces come in track order, so */
			scr_overflow |= 4;          /* dropping the newest lost the road under the car on a */
			uint8_t m = 0;              /* track's second half): replace the farthest if nearer */
			for (uint8_t i = 1; i < nv; i++) if (key[i] > key[m]) m = i;
			if (k < key[m]) { key[m] = k; ord[m] = (uint8_t)p; }
			continue;
		}
		key[nv] = k;
		ord[nv++] = (uint8_t)p;
	}
	for (p = 1; p < nv; p++)                                /* insertion sort of the visible pieces */
		for (long j = p; j > 0 && key[j - 1] < key[j]; j--) {
			uint8_t tk = key[j]; key[j] = key[j - 1]; key[j - 1] = tk;
			uint8_t t = ord[j]; ord[j] = ord[j - 1]; ord[j - 1] = t;
		}
	uint8_t first = (nv > scr_draw_limit) ? nv - scr_draw_limit : 0;   /* farthest dropped first */
#ifndef SCR_NO_OPP
	/* the opponent is drawn right after the piece it is on - unless that piece is not drawn
	 * (culled: e.g. the road below a car high in the air is off screen): then by its own
	 * distance, before the first nearer piece (the far-road key) */
	uint8_t okey = 0;
	if (scr_opp[4] >= 0) {
		okey = 1;
		for (p = first; p < nv; p++) if (ord[p] == scr_opp[4]) okey = 0;
		if (okey) okey = far_key(scr_opp[0] >> 14, 40 - (scr_opp[1] >> 14), scr_opp[2] >> 14);
	}
#endif
	for (p = first; p < nv; p++) {
		long q = ord[p], d = q - cur_piece;
		if (d < 0) d += n;
		if (n - d < d) d = n - d;
#ifndef SCR_NO_OPP
		if (okey && key[p] < okey) { draw_opponent(); okey = 0; }
#endif
		draw_piece(q, d <= SCR_NEAR ? 1 : 13, 1);   /* (thin-wall skipping: no gain, walls reach the ground) */
#ifndef SCR_NO_OPP
		if (q == scr_opp[4]) draw_opponent();
#endif
	}
#ifndef SCR_NO_OPP
	if (okey) draw_opponent();                              /* nearer than every drawn piece */
#endif
}
