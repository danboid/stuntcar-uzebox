/* Integer maths shared by the PC and AVR builds of the port (bit-identical results). */
#include "scr_platform.h"
#include "scr_io.h"
#include "scr_trackdata.h"	/* table area offsets: the sin and atan tables live in the SD data file */
/* sin(angle) * 16384 truncated toward zero, angle in 1/65536 turns (the remake's table
 * holds the same values to within 1) */
#ifdef SCR_EXACT_SIN                /* experiment (PC): the remake's own table, built as it does */
#include <math.h>
short scr_sin(long angle)
{
	static short t[65536 + 16384];
	static int built;
	if (!built) {
		double ang = 0, step = (2.0 * 3.1415926535898) / 65536.0;
		for (long i = 0; i < 65536 + 16384; i++) { t[i] = (short)(sin(ang) * 16384.0); ang += step; }
		built = 1;
	}
	return t[angle];
}
#else
short scr_sin(long angle)
{
	long a = angle & 0xffff, q = a >> 14, idx, frac;
	unsigned long v;
	a &= 0x3fff;
	if (q & 1) a = 0x4000 - a;
	idx = a >> 6; frac = a & 63;
	{
		uint16_t s2[2];
		xram_read(XRAM_TRACKS + SCR_T_SIN + 2 * (uint32_t)idx, s2, 4);
		v = ((unsigned long)s2[0] * (64 - frac) + (unsigned long)s2[1] * frac) >> 6;   /* Q15 */
	}
	v >>= 1;                                                        /* Q14, truncated */
	return (short)((q & 2) ? -(long)v : (long)v);
}
#endif
/* round(|atan(o/a)| * 65536 / 2pi), as CalcCurveMeasurements; a == 0 gives 90 degrees */
long scr_atan_angle(long o, long a)
{
	unsigned long ao = labs(o), aa = labs(a), r, idx, frac, v;
	int swap = 0;
	if (aa == 0) return 16384;
	if (ao > aa) { unsigned long t = ao; ao = aa; aa = t; swap = 1; }
	while (aa >= 0x10000UL) { ao >>= 1; aa >>= 1; }                 /* keep ao << 16 in 32 bits */
	r = (ao << 16) / aa;                                            /* ratio, Q16, <= 1 */
	idx = r >> 8; frac = r & 0xff;
	if (idx >= 256) v = xram_rdu16(XRAM_TRACKS + SCR_T_ATAN + 2 * 256);
	else {
		uint16_t a2[2];
		xram_read(XRAM_TRACKS + SCR_T_ATAN + 2 * (uint32_t)idx, a2, 4);
		v = (((unsigned long)a2[0] * (256 - frac)) + ((unsigned long)a2[1] * frac) + 128) >> 8;   /* Q2 */
	}
	if (swap) v = 65536 - v;                                        /* 16384 in Q2 */
	return (long)((v + 2) >> 2);
}
/* floor(sqrt(v)) */
unsigned long scr_isqrt(unsigned long v)
{
	unsigned long r = 0, b = 1UL << 30;
	while (b > v) b >>= 2;
	while (b) { if (v >= r + b) { v -= r + b; r = (r >> 1) + b; } else r >>= 1; b >>= 2; }
	return r;
}

/* atan2(y, x) in 1/65536 turns, -32768..32768 (renderer-side orientation angles) */
long scr_atan2(long y, long x)
{
	long a;
	if (x == 0 && y == 0) return 0;
	a = scr_atan_angle(y, x);                     /* |atan(y/x)|, 0..16384 */
	if (x >= 0) return (y >= 0) ? a : -a;
	return (y >= 0) ? 32768 - a : -(32768 - a);
}
