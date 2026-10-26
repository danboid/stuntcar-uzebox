/* On-demand track for the Stunt Car Racer port. Replaces the remake's fully expanded
 * Track[] (tens of KB) with values computed from flash tables when read. The physics and
 * opponent code read Track[p].field, Track[p].coords[i].x and Track_Map[x][z] unchanged. */
#pragma once
#include "scr_platform.h"
#include "3D_Engine.h"     /* COORD_3D */
#include "Track.h"         /* constants, TRACK_PIECE fields */

COORD_3D scr_track_coord(long piece, long index);
#ifdef SCR_GAME
uint8_t scr_is_gap(long piece);                 /* port: a pit between stepping stones */
long scr_rescue_piece(long piece);              /* the piece itself, after a pit, or after a wall ahead */
extern uint8_t scr_input;                          /* game_tick's input (scr_gap_stuck: trying to drive) */
uint8_t scr_gap_stuck(long touching, long piece, uint8_t limit);   /* stuck in front of a wall */
#endif

struct ScrCoords {
	long piece;
	COORD_3D operator[](long index) const { return scr_track_coord(piece, index); }  /* by value */
};
struct ScrPiece {
	long x, y, z, roughPieceAngle, oppositeDirection, curveToLeft, type;
	long lengthReduction, steeringAmount, numSegments, firstSegment, initialColour;
	BYTE roadColour[MAX_SEGMENTS_PER_PIECE];
	BYTE sidesColour;
	ScrCoords coords;
};
struct ScrTrack { const ScrPiece &operator[](long piece) const; };
struct ScrMapRow { long x; long operator[](long z) const; };
struct ScrTrackMap { ScrMapRow operator[](long x) const { ScrMapRow r; r.x = x; return r; } };

extern ScrTrack Track;
extern ScrTrackMap Track_Map;
extern long TrackID, NumTrackPieces, NumTrackSegments, PlayersStartPiece, StartLinePiece, HalfALapPiece;
extern long StandardBoost, SuperBoost;
extern unsigned char sections_car_can_be_put_on[];

/* renderer access */
void scr_piece_rows(long piece, const uint8_t *rows, uint8_t nr, COORD_3D (*out)[4]);
void scr_piece_records(long first, uint8_t n, uint8_t *dst);
void scr_piece_sphere(long piece, long *cx, long *cy, long *cz, long *rad);
