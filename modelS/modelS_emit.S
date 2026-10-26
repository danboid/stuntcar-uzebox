; Model S: edge setup in AVR assembly (the SCR_FAST_EDGES variant of emit() in modelS_render.cpp,
; bit-identical to it).
;
;   void scr_emit(int16_t xa, int16_t ya, int16_t xb, int16_t yb, uint8_t ida, uint8_t idb)
;
; An edge from (xa, ya) to (xb, yb), Q4 screen units within +-32000, toggling region ida (and
; idb, or SCR_NONE): rows r0 .. r1 whose centres lie in [ya, yb); X (8.8) at the first row and
; the slope dX (8.8 per row) - the same integer steps as the C:
;   r0 = (ya + 7) >> 4, r1 = ((yb + 7) >> 4) - 1, clamped to 0 .. SCR_ROWS - 1
;   dX = sdiv32_16(dx * 256 +- (dy >> 1), dy)              (rounded, saturated)
;   X  = xa * 16 + tdiv((r0 * 16 + 8 - ya) * dX, 16) + 127
;   last = X + (r1 - r0) * dX; X shifted so that X and last lie in 0 .. 65535
; The 9-byte slot [link lo, link hi, r1, X lo, X hi, dX lo, dX hi, id, id] is prepended to the
; row's list in SPI RAM (scr_render_finish() sorts and merges each row).
; Args (avr-gcc): xa r25:r24, ya r23:r22, xb r21:r20, yb r19:r18, ida r16, idb r14.
; r5 is never used: the game is built with -ffixed-r5 (r5 belongs to the video interrupt, which
; may run at any time - saving and restoring r5 here would not be enough).
; Registers: xa r3:r2, ya r11:r10, xb r7:r6, yb r9:r8, ida r16, idb r17, r0 r12, r1 r13, dX r15:r14;
; later X r9:r8:r7:r6, last r11:r10:r3:r2, the slot number r17:r16.

#include <avr/io.h>
#define SCR_ROWS           110
#define XMAX16             4088
#define SCR_NONE           0xFF
#define SCR_XRAM_MAX_EDGES 440
#ifdef SCR_SPIRAM_64K
#define XRAM_SLOTS         0x06000
#else
#define XRAM_SLOTS         0x14000
#endif

	.extern	sdiv32_16
	.extern	xram_write
	.extern	scr_bucket
	.extern	scr_nedges
	.extern	scr_overflow

	.section .text.scr_emit
	.global	scr_emit

; (r23:r22) * (r21:r20), signed -> r25:r24:r19:r18. Uses r0, r1 (cleared), r26.
.Lemit_mul16s:
	clr	r26
	muls	r23, r21
	movw	r24, r0
	mul	r22, r20
	movw	r18, r0
	mulsu	r23, r20
	sbc	r25, r26
	add	r19, r0
	adc	r24, r1
	adc	r25, r26
	mulsu	r21, r22
	sbc	r25, r26
	add	r19, r0
	adc	r24, r1
	adc	r25, r26
	clr	r1
	ret

scr_emit:
	push	r2
	push	r3
	push	r6
	push	r7
	push	r8
	push	r9
	push	r10
	push	r11
	push	r12
	push	r13
	push	r14
	push	r15
	push	r16
	push	r17
	push	r28
	push	r29
	in	r28, _SFR_IO_ADDR(SPL)          ; 9-byte frame for the slot
	in	r29, _SFR_IO_ADDR(SPH)
	sbiw	r28, 9
	in	r0, _SFR_IO_ADDR(SREG)
	cli
	out	_SFR_IO_ADDR(SPH), r29
	out	_SFR_IO_ADDR(SREG), r0
	out	_SFR_IO_ADDR(SPL), r28          ; slot at Y+1 .. Y+9

	movw	r2, r24                         ; xa
	movw	r10, r22                        ; ya
	movw	r6, r20                         ; xb
	movw	r8, r18                         ; yb
	mov	r17, r14                        ; idb (ida stays in r16)

	cp	r10, r8                         ; ya == yb: nothing
	cpc	r11, r9
	brne	1f
	rjmp	.Lemit_done
1:	cp	r8, r10                         ; ya > yb: swap the ends
	cpc	r9, r11
	brge	2f
	movw	r24, r2
	movw	r2, r6
	movw	r6, r24
	movw	r24, r10
	movw	r10, r8
	movw	r8, r24
2:	; xa >= XMAX16 && xb >= XMAX16: the right border, never needed
	ldi	r24, lo8(XMAX16)
	ldi	r25, hi8(XMAX16)
	cp	r2, r24
	cpc	r3, r25
	brlt	3f
	cp	r6, r24
	cpc	r7, r25
	brlt	3f
	rjmp	.Lemit_done
3:	; r0 = (ya + 7) >> 4 -> r12 (clamped >= 0), r1 = ((yb + 7) >> 4) - 1 -> r13 (<= ROWS - 1)
	movw	r24, r10
	adiw	r24, 7
	asr	r25
	ror	r24
	asr	r25
	ror	r24
	asr	r25
	ror	r24
	asr	r25
	ror	r24
	tst	r25
	brpl	4f
	clr	r24
	clr	r25
4:	movw	r12, r24                        ; r0 (r13 = 0 now; r0 <= 2000 fits a word)
	movw	r24, r8
	adiw	r24, 7
	asr	r25
	ror	r24
	asr	r25
	ror	r24
	asr	r25
	ror	r24
	asr	r25
	ror	r24
	sbiw	r24, 1                          ; r1 (word, signed)
	ldi	r26, SCR_ROWS - 1
	cpi	r24, SCR_ROWS - 1
	cpc	r25, r1
	brlt	5f
	mov	r24, r26
	clr	r25
5:	cp	r24, r12                        ; r1 < r0: no row
	cpc	r25, r13
	brge	6f
	rjmp	.Lemit_done
6:	mov	r13, r24                        ; r1 (now 0 .. ROWS - 1; r12 = r0 likewise)

	; dX = sdiv32_16(dx * 256 + (dx >= 0 ? dy >> 1 : -(dy >> 1)), dy)
	movw	r20, r8                         ; dy = yb - ya (1 .. 64000)
	sub	r20, r10
	sbc	r21, r11
	movw	r24, r6                         ; dx = xb - xa, 32-bit: r25:r24:r23:r22 -> as n
	clr	r26
	sbrc	r7, 7
	com	r26                             ; xb sign
	clr	r27
	sbrc	r3, 7
	com	r27                             ; xa sign
	sub	r24, r2
	sbc	r25, r3
	sbc	r26, r27                        ; dx: r26:r25:r24 (17 bits, sign in r26)
	mov	r23, r24                        ; n = dx * 256: r25:r24:r23:r22 = dx << 8
	mov	r24, r25
	mov	r25, r26
	clr	r22
	movw	r18, r20                        ; h = dy >> 1
	lsr	r19
	ror	r18
	tst	r25
	brmi	7f
	add	r22, r18                        ; dx >= 0: + h
	adc	r23, r19
	adc	r24, r1
	adc	r25, r1
	rjmp	8f
7:	sub	r22, r18                        ; dx < 0: - h
	sbc	r23, r19
	sbc	r24, r1
	sbc	r25, r1
8:	call	sdiv32_16                       ; -> r25:r24 = dX
	movw	r14, r24

	; t = r0 * 16 + 8 - ya (16-bit), p = t * dX, q = tdiv(p, 16)
	mov	r22, r12
	clr	r23
	ldi	r24, 4
9:	lsl	r22
	rol	r23
	dec	r24
	brne	9b
	subi	r22, lo8(-8)
	sbci	r23, hi8(-8)
	sub	r22, r10
	sbc	r23, r11
	movw	r20, r14
	rcall	.Lemit_mul16s                          ; p: r25:r24:r19:r18
	sbrs	r25, 7
	rjmp	11f
	com	r25                             ; p < 0: q = -((-p) >> 4)
	com	r24
	com	r19
	neg	r18
	sbci	r19, -1
	sbci	r24, -1
	sbci	r25, -1
	rcall	.Lemit_shr4
	com	r25
	com	r24
	com	r19
	neg	r18
	sbci	r19, -1
	sbci	r24, -1
	sbci	r25, -1
	rjmp	12f
11:	rcall	.Lemit_shr4                            ; p >= 0: q = p >> 4
12:	; X = xa * 16 + q + 127 -> r9:r8:r7:r6 (yb, xb no longer needed)
	movw	r6, r2                          ; xa, sign-extended
	clr	r8
	sbrc	r3, 7
	com	r8
	mov	r9, r8
	ldi	r26, 4
13:	lsl	r6
	rol	r7
	rol	r8
	rol	r9
	dec	r26
	brne	13b
	add	r6, r18
	adc	r7, r19
	adc	r8, r24
	adc	r9, r25
	ldi	r26, 127
	add	r6, r26
	adc	r7, r1
	adc	r8, r1
	adc	r9, r1

	; last = X + (r1 - r0) * dX -> r11:r10:r3:r2 (xa, ya no longer needed)
	mov	r22, r13
	sub	r22, r12
	clr	r23
	movw	r20, r14
	rcall	.Lemit_mul16s
	movw	r2, r6
	movw	r10, r8
	add	r2, r18
	adc	r3, r19
	adc	r10, r24
	adc	r11, r25

	; if (X > 65535 || last > 65535) X -= max(X, last) - 65535
	; if (X < 0 || last < 0) X -= min(X, last)        (last as computed above, unchanged)
	movw	r18, r6                         ; m = max(X, last) in r21:r20:r19:r18
	movw	r20, r8
	cp	r18, r2
	cpc	r19, r3
	cpc	r20, r10
	cpc	r21, r11
	brge	14f
	movw	r18, r2
	movw	r20, r10
14:	cp	r1, r20                         ; m > 65535 <=> (m >> 16) > 0, signed
	cpc	r1, r21
	brge	15f
	subi	r18, 0xFF                       ; m - 65535 = m - 0xFFFF
	sbci	r19, 0xFF
	sbci	r20, 0
	sbci	r21, 0
	sub	r6, r18
	sbc	r7, r19
	sbc	r8, r20
	sbc	r9, r21
15:	movw	r18, r6                         ; m = min(X, last)
	movw	r20, r8
	cp	r2, r18
	cpc	r3, r19
	cpc	r10, r20
	cpc	r11, r21
	brge	16f
	movw	r18, r2
	movw	r20, r10
16:	sbrs	r21, 7                          ; m < 0: X -= m
	rjmp	17f
	sub	r6, r18
	sbc	r7, r19
	sbc	r8, r20
	sbc	r9, r21
17:
	; if (idb != NONE && idb < ida) [idb, ida] else [ida, idb] (frees r17:r16 for the slot number)
	mov	r24, r16
	mov	r25, r17
	cpi	r25, SCR_NONE
	breq	19f
	cp	r25, r24
	brsh	19f
	mov	r24, r17
	mov	r25, r16
19:	std	Y + 8, r24
	std	Y + 9, r25
	; a slot: if (scr_nedges >= MAX) { scr_overflow |= 1; return; }  slot = ++scr_nedges
	lds	r16, scr_nedges
	lds	r17, scr_nedges + 1
	cpi	r16, lo8(SCR_XRAM_MAX_EDGES)
	ldi	r26, hi8(SCR_XRAM_MAX_EDGES)
	cpc	r17, r26
	brlo	18f
	lds	r26, scr_overflow
	ori	r26, 1
	sts	scr_overflow, r26
	rjmp	.Lemit_done
18:	subi	r16, 0xFF                       ; ++
	sbci	r17, 0xFF
	sts	scr_nedges, r16
	sts	scr_nedges + 1, r17

	; the slot: [bucket[r0] lo, hi, r1, X lo, X hi, dX lo, dX hi, ida/idb ordered]
	ldi	r30, lo8(scr_bucket)
	ldi	r31, hi8(scr_bucket)
	add	r30, r12
	adc	r31, r1
	add	r30, r12
	adc	r31, r1                         ; Z = &scr_bucket[r0]
	ld	r24, Z
	ldd	r25, Z + 1
	std	Y + 1, r24
	std	Y + 2, r25
	std	Y + 3, r13
	std	Y + 4, r6
	std	Y + 5, r7
	std	Y + 6, r14
	std	Y + 7, r15
	; xram_write(XRAM_SLOTS + 9 * slot, slot bytes, 9)
	movw	r22, r16                        ; 9 * slot = 8 * slot + slot
	clr	r24
	clr	r25
	ldi	r26, 3
20:	lsl	r22
	rol	r23
	rol	r24
	dec	r26
	brne	20b
	add	r22, r16
	adc	r23, r17
	adc	r24, r1
	subi	r22, lo8(-(XRAM_SLOTS))         ; + 0x14000: bytes 1 and 2 only (low byte 0)
	sbci	r23, hi8(-(XRAM_SLOTS))
	sbci	r24, hlo8(-(XRAM_SLOTS))
	sbci	r25, hhi8(-(XRAM_SLOTS))
	movw	r20, r28
	subi	r20, lo8(-1)
	sbci	r21, hi8(-1)
	ldi	r18, 9
	clr	r19
	movw	r12, r30                        ; (r0 no longer needed: keep &scr_bucket[r0])
	call	xram_write
	movw	r30, r12                        ; scr_bucket[r0] = slot
	st	Z, r16
	std	Z + 1, r17

.Lemit_done:	adiw	r28, 9                          ; drop the frame
	in	r0, _SFR_IO_ADDR(SREG)
	cli
	out	_SFR_IO_ADDR(SPH), r29
	out	_SFR_IO_ADDR(SREG), r0
	out	_SFR_IO_ADDR(SPL), r28
	pop	r29
	pop	r28
	pop	r17
	pop	r16
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	pop	r11
	pop	r10
	pop	r9
	pop	r8
	pop	r7
	pop	r6
	pop	r3
	pop	r2
	clr	r1
	ret

; r25:r24:r19:r18 >>= 4 (logical: called with a non-negative value)
.Lemit_shr4:	ldi	r26, 4
1:	lsr	r25
	ror	r24
	ror	r19
	ror	r18
	dec	r26
	brne	1b
	ret
