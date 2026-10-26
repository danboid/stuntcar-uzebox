/* On-demand track (see scr_track.h). Every value equals what the remake's ConvertAmigaTrack
 * stores, including the join-up of consecutive pieces and the moving drawbridge. */
#include "scr_track.h"
#include "scr_trackdata.h"
#include "StuntCarRacer.h"
#include "scr_io.h"

ScrTrack Track;
ScrTrackMap Track_Map;
long TrackID = NO_TRACK, NumTrackPieces, NumTrackSegments, PlayersStartPiece, StartLinePiece, HalfALapPiece;
long StandardBoost, SuperBoost;
unsigned char sections_car_can_be_put_on[] =
	{0x00,0x80,0x20,0xc0,0x00,0x73,0x80,0xc0,0xa9,0x59,0x00,0x02,0xa9,0x5e,0x85,0x4b};
extern bool bSuperLeague;
extern long player_current_piece, opponents_current_piece;

/* Current track: a SCR_TRACK_SLOT-byte slot in the SPI RAM (loaded from SCRTRK.BIN):
 *   0: pieces, 1: start piece, 2: standard boost, 3: super boost, 4-5: segments (LE)
 *   16 + 16 * p: piece record - xz, angle&template, left Y id, right Y id, left shift (BE),
 *                right shift (BE), firstSegment (LE), steep-segment mask (LE)
 *   1664 + 16 * x + z: Track_Map (0xFF = none) */
static uint32_t tbase;
#define RC_SIZE 4
static struct { int16_t tag; uint8_t r[16]; } rc[RC_SIZE];
#ifdef PROF_NOINLINE
__attribute__((noinline))
#endif
static const uint8_t *praw(long p)
{
	uint8_t h = (uint8_t)p & (RC_SIZE - 1);
	if (rc[h].tag != p) { xram_read(tbase + 16 + 16 * (uint32_t)p, rc[h].r, 16); rc[h].tag = (int16_t)p; }
	return rc[h].r;
}
#define XZPOS(p)   (praw(p)[0])
#define ANGTMPL(p) (praw(p)[1])
#define LEFTID(p)  (praw(p)[2])
#define RIGHTID(p) (praw(p)[3])
static long be16(const uint8_t *b) { return (long)(int16_t)(((uint16_t)b[0] << 8) | b[1]); }
#define LSHIFT(p)  be16(praw(p) + 4)
#define RSHIFT(p)  be16(praw(p) + 6)
#define FIRSTSEG(p) ((long)(praw(p)[8] | ((uint16_t)praw(p)[9] << 8)))
#define STEEP(p)    ((uint16_t)(praw(p)[10] | ((uint16_t)praw(p)[11] << 8)))

char GetPieceAngleAndTemplate(long piece) { return (char)ANGTMPL(piece); }

/* ---- drawbridge state (Track.cpp: MoveDrawBridge / UpdateDrawBridgeYCoords) */
#define NUM_DRAW_BRIDGE_Y_VALUES 15
static long draw_bridge_y_list[NUM_DRAW_BRIDGE_Y_VALUES];
static long on_draw_bridge_offset = 0, draw_bridge_frame_count = 0;
static bool bridge_moved = false;                /* coords overridden since conversion */
static const unsigned char TAB5a996[16] PROGMEM = {0xd2,0xbb,0xb7,0xb3,0xb1,0xad,0xab,0xa7,0xa6,0xa4,0xa2,0xa1,0x9f,0x9f,0x9f,0x9e};

/* y list index for (piece, row) under the drawbridge, or -1 */
static long bridge_index(long piece, long row)
{
	if (!bridge_moved || TrackID != DRAW_BRIDGE) return -1;
	switch (piece) {
	case 51: return (row >= 1 && row <= 8) ? row - 1 : -1;
	case 52: return (row <= 7) ? 7 + row : -1;
	case 54: return (row >= 1 && row <= 8) ? (NUM_DRAW_BRIDGE_Y_VALUES - 1) - (row - 1) : -1;
	case 55: return (row <= 7) ? (NUM_DRAW_BRIDGE_Y_VALUES - 1 - 7) - row : -1;
	}
	return -1;
}

/* ---- base coordinates (before join-up and drawbridge) */
static long tmpl_of(long piece) { return ANGTMPL(piece) & 0x0f; }
static long nseg_of(long piece) { return RD8(&scr_tmpl_ns[tmpl_of(piece)]); }

/* one coordinate: the corner of its row, computed by scr_piece_rows (the renderer's row
 * generator - proven identical to the former per-coordinate code on every corner of every
 * track, drawbridge states included; one implementation instead of two: flash) */
void scr_piece_rows(long piece, const uint8_t *rows, uint8_t nr, COORD_3D (*out)[4]);
static COORD_3D compute_coord(long piece, long index)
{
	uint8_t row = (uint8_t)(index >> 2);
	COORD_3D c[1][4];
	scr_piece_rows(piece, &row, 1, c);
	return c[0][index & 3];
}

/* small direct-mapped cache of computed coordinates */
#define CC_SIZE 4                      /* (RAM; 8 entries are ~4% faster) */
static struct { int16_t piece, index; COORD_3D c; } cc[CC_SIZE];
static void cc_clear(void) { for (int i = 0; i < CC_SIZE; i++) cc[i].piece = -1; }
COORD_3D scr_track_coord(long piece, long index)
{
	unsigned h = (unsigned)(piece * 7 + index) & (CC_SIZE - 1);
	if (cc[h].piece != piece || cc[h].index != index) {
		cc[h].c = compute_coord(piece, index); cc[h].piece = (int16_t)piece; cc[h].index = (int16_t)index;
	}
	return cc[h].c;
}

/* ---- piece records: small LRU cache of decoded records */
#define PC_SIZE 2
static ScrPiece pcache[PC_SIZE];
static int16_t pc_tag[PC_SIZE];                 /* set by invalidate() at every track load */
static uint8_t pc_age[PC_SIZE];

static void decode_piece(long piece, ScrPiece *r)
{
	long a = ANGTMPL(piece), t = a & 0x0f, i;
	long c = XZPOS(piece);
	BYTE road, sides;
	r->x = c & 0x0f; r->y = 0; r->z = (c & 0xf0) >> 4;
	r->roughPieceAngle = ((a & 0xc0) * MAX_ANGLE) / 0x100;
	r->oppositeDirection = (a & 0x10) ? TRUE : FALSE;
	r->curveToLeft = RD8(&scr_tmpl_left[t]);
	r->type = RD8(&scr_tmpl_type[t]);
	r->lengthReduction = RD8(&scr_tmpl_lr[t]);
	r->steeringAmount = RD8(&scr_tmpl_steer[t]);
	r->numSegments = RD8(&scr_tmpl_ns[t]);
	r->firstSegment = FIRSTSEG(piece);			/* precomputed (SCRTRK.BIN) */
	r->initialColour = (RIGHTID(piece) & 0x80) >> 7;
	if (piece & 1) { road = bSuperLeague ? SCR_BASE_COLOUR + 17 : SCR_BASE_COLOUR + 2;
	                 sides = bSuperLeague ? SCR_BASE_COLOUR + 16 : SCR_BASE_COLOUR + 10; }
	else           { road = bSuperLeague ? SCR_BASE_COLOUR + 18 : SCR_BASE_COLOUR + 1;
	                 sides = SCR_BASE_COLOUR + 15; }
	r->sidesColour = sides;
	{
		uint16_t steep = STEEP(piece);                 /* precomputed from the original's colours */
		for (i = 0; i < r->numSegments; i++) r->roadColour[i] = (steep & (1u << i)) ? SCR_BASE_COLOUR + 0 : road;
	}
	r->coords.piece = piece;
}

const ScrPiece &ScrTrack::operator[](long piece) const
{
	int i, best = 0;
	for (i = 0; i < PC_SIZE; i++) if (pc_tag[i] == piece) { pc_age[i] = 0; goto hit; }
	for (i = 0; i < PC_SIZE; i++) { if (pc_age[i] > pc_age[best]) best = i; if (pc_tag[i] < 0) { best = i; break; } }
	decode_piece(piece, &pcache[best]); pc_tag[best] = (int16_t)piece; i = best; pc_age[i] = 0;
hit:
	for (int k = 0; k < PC_SIZE; k++) if (k != i && pc_age[k] < 255) pc_age[k]++;
	return pcache[i];
}

long ScrMapRow::operator[](long z) const
{
	uint8_t v;
	xram_read(tbase + 1664 + 16 * (uint32_t)x + (uint32_t)z, &v, 1);
	return (v == 0xFF) ? -1 : (long)v;
}

static void invalidate(void) { for (int i = 0; i < PC_SIZE; i++) pc_tag[i] = -1; for (int i = 0; i < RC_SIZE; i++) rc[i].tag = -1; cc_clear(); }

#ifdef SCR_GAME
/* port: the track's gaps - pits whose middle lies 5100 .. 6400 below both ends (Stepping Stones'
 * four between the stones, Draw Bridge's two; every other dip is < 2800). A car that falls in is
 * on the road, so the off-road crane never comes: Car_Behaviour.cpp rescues it, and the crane
 * drops cars after a gap. Each pit has a height profile of its own, used by no other piece of
 * the eight tracks (found by that depth test): 47 (the stepping stones), 44 and 66 */
__attribute__((noinline)) static uint8_t prof_id(uint8_t p) { return praw(p)[2] & 0x7f; }   /* a piece's height profile */
__attribute__((noinline)) uint8_t scr_is_gap(long p)
{
	uint8_t id = prof_id((uint8_t)p);
	return id == 47 || id == 44 || id == 66;
}
/* a wall: a steep segment the road climbs (Big Ramp's jumps: ramp, steep drop, two or three pieces
 * of road on the ground, steep wall up to the landing). The pieces with one, across all eight
 * tracks, are exactly those with these height profiles. wall_after: the piece after the first
 * wall in piece q or the next three, never across the finish line; 0 if none */
static const uint8_t wall_ids[] PROGMEM = { 16, 19, 32, 42, 44, 47, 48, 55, 61, 66, 69, 97, 107, 118 };
static uint8_t wall_after(uint8_t q)
{
	uint8_t n = (uint8_t)NumTrackPieces;
	for (uint8_t r = q; r < q + 4 && r + 1 < n; r++) {
		uint8_t id = prof_id(r);
		for (uint8_t i = 0; i < sizeof(wall_ids); i++)
			if (RD8(&wall_ids[i]) == id) return r + 1;
	}
	return 0;
}
/* the crane, when stuck in front of a wall - in one of Stepping Stones' or Draw Bridge's pits, or
 * Big Ramp's gaps: on the road, a wall (above) in this piece or the next three, trying to drive (accelerate
 * or brake held: game_tick's scr_input) - for more than 2 * limit ticks without reaching a new
 * piece: in one of Big Ramp's gaps, against its wall or bouncing off it. (Anywhere else - sliding
 * back down a steep climb, reversing for a run-up - the original's rules alone.) A piece 1-8 ahead
 * of the furthest reached is progress; on it or up to 8 behind is not; further (the crane, a new
 * race) starts afresh */
static uint8_t stuck_to;                                /* where that crane puts the car (0: no) */
uint8_t scr_input;
__attribute__((noinline)) uint8_t scr_gap_stuck(long touching, long piece, uint8_t limit)
{
	static uint8_t sticks, best;                            /* (the pits' profiles are walls too) */
	uint8_t n = (uint8_t)NumTrackPieces, p = (uint8_t)piece, w;
	uint8_t d = p >= best ? p - best : p + n - best;       /* pieces ahead of the furthest */
	if (d && (d <= 8 || n - d > 8)) { best = p; sticks = 0; }   /* progress, or afresh */
	else if (scr_input & 0x0c && (uint8_t)touching && (w = wall_after(p)) && ++sticks > 2 * limit) {
		sticks = 0; stuck_to = w; return 1;
	}
	return 0;
}
/* where the crane puts the car: the piece after a pit; and, when it came because the car was
 * stuck in front of a wall (scr_gap_stuck), past the wall */
__attribute__((noinline)) long scr_rescue_piece(long p)
{
	uint8_t q = stuck_to;
	if (q) { stuck_to = 0; return q; }
	q = (uint8_t)p;                                          /* (pieces < 256) */
	if (scr_is_gap(q) && ++q >= (uint8_t)NumTrackPieces) q = 0;
	return q;
}
#endif

long ConvertAmigaTrack(long track)
{
	uint8_t h[6];
	if (track < 0 || track >= NUM_TRACKS) { TrackID = NO_TRACK; return FALSE; }
	tbase = XRAM_TRACKS + (uint32_t)track * SCR_TRACK_SLOT;
	xram_read(tbase, h, 6);
	TrackID = track;
	NumTrackPieces = h[0];
	PlayersStartPiece = h[1];
	StartLinePiece = PlayersStartPiece;
	HalfALapPiece = StartLinePiece + NumTrackPieces / 2;
	if (HalfALapPiece > NumTrackPieces) HalfALapPiece -= NumTrackPieces;
	StandardBoost = h[2];
	SuperBoost = h[3];
	NumTrackSegments = h[4] | ((long)h[5] << 8);
	bridge_moved = false;
	invalidate();
	return TRUE;
}

/* ---- drawbridge (logic as Track.cpp; the dead opponents_speed_values writes are omitted) */
static void bridge_set_coords(void) { bridge_moved = true; cc_clear(); }

void MoveDrawBridge(void)
{
	long f, i, height, y, yinc;
	(void)f;
	if (TrackID != DRAW_BRIDGE) return;
	if (player_current_piece >= 56) goto player_not_on_draw_bridge;
	if (player_current_piece >= 51) goto on_draw_bridge;
player_not_on_draw_bridge:
	if (opponents_current_piece >= 56) goto not_on_draw_bridge;
	if (opponents_current_piece >= 51) goto on_draw_bridge;
	if (on_draw_bridge_offset == 0) goto not_on_draw_bridge;
	if (opponents_current_piece < 48) goto not_on_draw_bridge;
on_draw_bridge:
	on_draw_bridge_offset = 12;
	return;
not_on_draw_bridge:
	draw_bridge_frame_count++;
	on_draw_bridge_offset = 0;
	height = ((draw_bridge_frame_count & 0x1f) - 0x10);
	if (height < 0) height = labs(height) - 1;
	(void)TAB5a996;
	y = yinc = (height + 4) << 5;
	for (i = 0; i < NUM_DRAW_BRIDGE_Y_VALUES; i++) { draw_bridge_y_list[i] = y; y += yinc; }
	bridge_set_coords();
}

void ResetDrawBridge(void)
{
	on_draw_bridge_offset = 0;
	draw_bridge_frame_count = 0;
	player_current_piece = opponents_current_piece = PlayersStartPiece;
	MoveDrawBridge();
}

/* ---- renderer access ------------------------------------------------------------------ */
#ifdef SCR_ROWS_ASM
/* in assembly (scr_rows.S), bit-identical to the C below; its helpers: */
extern "C" {
extern const uint8_t *const scr_tab_ns, *const scr_tab_xzoff;   /* (extern: C++ const is internal) */
const uint8_t *const scr_tab_ns = scr_tmpl_ns, *const scr_tab_xzoff = scr_tmpl_xzoff;
__attribute__((noinline)) const uint8_t *scr_praw(long p) { return praw(p); }
__attribute__((noinline)) void scr_bridge_fix(long piece, long row, COORD_3D *o)   /* the drawbridge */
{
	/* bridge_index() in bytes: pieces 51, 52 rise with the row, 54, 55 fall; -1: not the bridge */
	if (!bridge_moved || TrackID != DRAW_BRIDGE) return;
	uint8_t p = (uint8_t)piece, r = (uint8_t)row;
	int8_t bi = -1;
	if (p == 51 || p == 54) { if (r >= 1 && r <= 8) bi = (int8_t)(r - 1); }
	else if (p == 52 || p == 55) { if (r <= 7) bi = (int8_t)(7 + r); }
	if (bi < 0) return;
	if (p >= 54) bi = (int8_t)((NUM_DRAW_BRIDGE_Y_VALUES - 1) - bi);
	const uint8_t *q = praw(piece);
	long y = draw_bridge_y_list[bi];
	o[0].y = (y + be16(q + 4)) * PC_FACTOR;
	o[1].y = (y + be16(q + 6)) * PC_FACTOR;
}
void scr_piece_rows_asm(long piece, const uint8_t *rows, uint8_t nr, COORD_3D (*out)[4]);
}
static_assert(SCR_T_PIECE_Y == 0x04000UL && SCR_T_PIECE_Y_OFF == 0x049BAUL && SCR_T_TMPL_XZ == 0x04ABAUL &&
              XRAM_TRACKS == 0 && PC_FACTOR == 2 && TRACK_BOTTOM_Y == 0 && sizeof(COORD_3D) == 12,
              "scr_rows.S has these built in");
void scr_piece_rows(long piece, const uint8_t *rows, uint8_t nr, COORD_3D (*out)[4])
{
	scr_piece_rows_asm(piece, rows, nr, out);
}
#else
/* Corners of the given rows of a piece (row r: L, R, LB, RB = coords[4r..4r+3]), equal to
 * scr_track_coord() but computed directly: one record read, one burst for the template
 * points of a row, two height reads. */
static inline __attribute__((always_inline)) void row_corners(long piece, long row, uint8_t a, long ns, long lid, long rid, long lsh, long rsh, COORD_3D *o)
{
	long t = a & 0x0f, rough = a & 0xc0, j, x0, z0, x, z, k;
	int16_t pts[4];
	j = 2 * row;                                            /* left point index; right = j + 1 */
	if (a & 0x10) j = ((ns + 1) * 2 - 1) - (j + 1);       /* reversed: right, left adjacent */
	xram_read(XRAM_TRACKS + SCR_T_TMPL_XZ + 4 * (uint32_t)(RD8(&scr_tmpl_xzoff[t]) + j), pts, 8);
	for (k = 0; k < 2; k++) {
		long q = (a & 0x10) ? 1 - k : k;                    /* which of the two points is corner k */
		x0 = pts[2 * q]; z0 = pts[2 * q + 1];
		switch (rough) {
		case 0x00: x = x0;         z = z0;         break;
		case 0x40: x = z0;         z = 0x800 - x0; break;
		case 0x80: x = 0x800 - x0; z = 0x800 - z0; break;
		default:   x = 0x800 - z0; z = x0;         break;
		}
		o[k].x = o[k + 2].x = x * PC_FACTOR;
		o[k].z = o[k + 2].z = z * PC_FACTOR;
		o[k + 2].y = TRACK_BOTTOM_Y;
	}
	static long c_lid = -1, c_rid = -1;                 /* profile start offsets: fixed per id */
	static uint16_t c_loff, c_roff;
	if (lid != c_lid) { c_loff = xram_rdu16(XRAM_TRACKS + SCR_T_PIECE_Y_OFF + 2 * (uint32_t)lid); c_lid = lid; }
	if (rid != c_rid) { c_roff = xram_rdu16(XRAM_TRACKS + SCR_T_PIECE_Y_OFF + 2 * (uint32_t)rid); c_rid = rid; }
	long yl = xram_rd16(XRAM_TRACKS + SCR_T_PIECE_Y + 2 * (uint32_t)(c_loff + row));
	long yr = xram_rd16(XRAM_TRACKS + SCR_T_PIECE_Y + 2 * (uint32_t)(c_roff + row));
	o[0].y = (yl + lsh) * PC_FACTOR;
	o[1].y = (yr + rsh) * PC_FACTOR;
	(void)piece;
}

void scr_piece_rows(long piece, const uint8_t *rows, uint8_t nr, COORD_3D (*out)[4])
{
	const uint8_t *r = praw(piece);
	uint8_t cp = r[0], a0 = r[1];
	long lsh = be16(r + 4), rsh = be16(r + 6);
	long ns = RD8(&scr_tmpl_ns[a0 & 0x0f]);
	for (uint8_t k = 0; k < nr; k++) {
		long row = rows[k], bi, src = piece, srow = row, ddx = 0, ddz = 0;
		if (row == ns) {                                    /* join-up: the next piece's first row */
			src = (piece + 1 < NumTrackPieces) ? piece + 1 : 0;
			srow = 0;
		}
		const uint8_t *n = praw(src);                       /* one expansion of row_corners (flash) */
		uint8_t na = n[1], cn = n[0];
		if (src != piece) {
			ddx = ((long)(cn & 0x0f) - (long)(cp & 0x0f)) * (1L << (LOG_CUBE_SIZE - LOG_PRECISION));   /* long: int is 16 bits on the AVR */
			ddz = ((long)((cn & 0xf0) >> 4) - (long)((cp & 0xf0) >> 4)) * (1L << (LOG_CUBE_SIZE - LOG_PRECISION));
		}
		row_corners(src, srow, na, RD8(&scr_tmpl_ns[na & 0x0f]), n[2] & 0x7f, n[3] & 0x7f, be16(n + 4), be16(n + 6), out[k]);
		for (int c = 0; c < 4; c++) { out[k][c].x += ddx; out[k][c].z += ddz; }
		if ((bi = bridge_index(piece, row)) >= 0) {
			out[k][0].y = (draw_bridge_y_list[bi] + lsh) * PC_FACTOR;
			out[k][1].y = (draw_bridge_y_list[bi] + rsh) * PC_FACTOR;
		}
	}
}
#endif

/* bounding sphere of a piece in world display units (cube corner + centre, y / 4), radius */
/* raw 16-byte records of pieces first .. first + n - 1 in one SPI transaction (the renderer's
 * culling pass: n records at once instead of one transaction each) */
void scr_piece_records(long first, uint8_t n, uint8_t *dst)
{
	xram_read(tbase + 16 + 16 * (uint32_t)first, dst, (uint16_t)n * 16);
}

void scr_piece_sphere(long piece, long *cx, long *cy, long *cz, long *rad)
{
	const uint8_t *r = praw(piece);
	*cx = ((long)(r[0] & 0x0f) << 12) + (long)(int8_t)r[12] * 64;
	*cy = (long)r[13] * 64;
	*cz = ((long)(r[0] >> 4) << 12) + (long)(int8_t)r[14] * 64;
	*rad = (long)r[15] * 64;
}
