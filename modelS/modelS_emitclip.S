; Model S: a polygon clipped to the view and emitted as edges - emit_clipped() of
; modelS_render.cpp in AVR assembly, bit-identical to it.
;
;   void scr_emit_clipped(const scr_vtx *const *poly, uint8_t n, uint8_t id,
;                         int16_t (*pa)[4], int16_t (*pb)[4])
;
; The vertices' camera coordinates (scr_vtx: cx 4, cy 6, cz 8) -> pa [cx, cy, cz, 0]; clipped
; against the 5 planes (scr_clip_plane, pa <-> pb: the result in pb); each vertex projected:
;   z = max(cz, ZNEARQ); x = CX16 + sdiv(FX16 cx, z), y = CY16 - sdiv(FY16 cy, z)
;   x: 0 if < 0 or on the left plane (flag 2), XMAX16 if > XMAX16 or on the right one (4)
;   y: YMIN16 on the top plane (8), YMAX16 on the bottom one (16), at most 32000
; and the closed outline emitted (scr_emit, region id). Never touches r5 (-ffixed-r5: the
; video interrupt's); internal labels are local (.L).
; Args (avr-gcc): poly r25:r24, n r22, id r20, pa r19:r18, pb r17:r16.
; Registers: n r2, id r3, m r4, previous x r7:r6, pa r9:r8, pb r11:r10, k r12, vertex r15:r14,
; x quotient r17:r16, previous y r29:r28.
#define CMAX    21
#define ZNEARQ  2
#define FX16    3994
#define FY16    2125
#define CX16    2048
#define XMAX16  4088
#define CY16    880
#define YMIN16  (-64)
#define YMAX16  (110 * 16 + 64)
#define SCR_NONE 0xFF

	.extern	scr_clip_plane
	.extern	scr_emit
	.extern	sdiv32_16

	.section .text.scr_emit_clipped
	.global	scr_emit_clipped

; (r25:r24, signed) * constant (r21:r20, positive) -> r25:r24:r23:r22. Uses r0, r1 (cleared), r18, r19, r26.
.Lmulk:	movw	r18, r24
	clr	r26
	muls	r19, r21
	movw	r24, r0
	mul	r18, r20
	movw	r22, r0
	mulsu	r19, r20
	sbc	r25, r26
	add	r23, r0
	adc	r24, r1
	adc	r25, r26
	mulsu	r21, r18
	add	r23, r0
	adc	r24, r1
	adc	r25, r26
	clr	r1
	ret

scr_emit_clipped:
	push	r2
	push	r3
	push	r4
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
	movw	r6, r24                 ; poly (until the copy is done)
	mov	r2, r22                 ; n
	mov	r3, r20                 ; id
	movw	r8, r18                 ; pa
	movw	r10, r16                ; pb
	ldi	r24, CMAX               ; n = min(n, CMAX)
	cp	r24, r2
	brsh	1f
	mov	r2, r24
1:	; pa[k] = [cx, cy, cz, 0]
	movw	r26, r8                 ; X = pa
	clr	r12
2:	cp	r12, r2
	breq	3f
	movw	r30, r6                 ; Z = poly[k]
	ld	r24, Z+
	ld	r25, Z+
	movw	r6, r30
	movw	r30, r24
	ldd	r24, Z + 4
	st	X+, r24
	ldd	r24, Z + 5
	st	X+, r24
	ldd	r24, Z + 6
	st	X+, r24
	ldd	r24, Z + 7
	st	X+, r24
	ldd	r24, Z + 8
	st	X+, r24
	ldd	r24, Z + 9
	st	X+, r24
	st	X+, r1
	st	X+, r1
	inc	r12
	rjmp	2b
3:	; the 5 planes: k even pa -> pb, odd pb -> pa (stop when fewer than 3 vertices are left)
	mov	r4, r2                  ; m
	clr	r12                     ; k
.Lplane:
	ldi	r24, 3
	cp	r4, r24
	brsh	4f
	rjmp	.Ldone
4:	ldi	r24, 5
	cp	r12, r24
	breq	.Lproject
	mov	r24, r4
	mov	r22, r12
	movw	r20, r8                 ; in = pa, out = pb (k even)
	movw	r18, r10
	sbrs	r12, 0
	rjmp	5f
	movw	r20, r10                ; k odd: in = pb, out = pa
	movw	r18, r8
5:	call	scr_clip_plane
	mov	r4, r24
	inc	r12
	rjmp	.Lplane

.Lproject:                              ; the result is in pb; vertices k = 0 .. m (m: the first again)
	clr	r12
.Lvertex:
	mov	r24, r12                ; vertex = pb + 8 (k == m ? 0 : k)
	cp	r24, r4
	brne	6f
	clr	r24
6:	movw	r14, r10
	lsl	r24
	lsl	r24
	lsl	r24
	add	r14, r24
	adc	r15, r1
	; x quotient: sdiv32_16(FX16 cx, z), z = max(cz, ZNEARQ)
	movw	r30, r14
	ld	r24, Z
	ldd	r25, Z + 1
	ldi	r20, lo8(FX16)
	ldi	r21, hi8(FX16)
	rcall	.Lmulk
	rcall	.Lz
	call	sdiv32_16
	movw	r16, r24
	; y quotient: sdiv32_16(FY16 cy, z)
	movw	r30, r14
	ldd	r24, Z + 2
	ldd	r25, Z + 3
	ldi	r20, lo8(FY16)
	ldi	r21, hi8(FY16)
	rcall	.Lmulk
	rcall	.Lz
	call	sdiv32_16               ; qy in r25:r24
	movw	r30, r14
	ldd	r26, Z + 6              ; the vertex's on-plane flags
	; y = CY16 - qy, at most 32000 (qy < -31120); flags 8: YMIN16, then 16: YMAX16
	ldi	r18, lo8(-31120)
	ldi	r19, hi8(-31120)
	cp	r24, r18
	cpc	r25, r19
	brge	7f
	ldi	r18, lo8(32000)
	ldi	r19, hi8(32000)
	rjmp	8f
7:	ldi	r18, lo8(CY16)
	ldi	r19, hi8(CY16)
	sub	r18, r24
	sbc	r19, r25
8:	sbrs	r26, 3
	rjmp	9f
	ldi	r18, lo8(YMIN16)
	ldi	r19, hi8(YMIN16)
9:	sbrs	r26, 4
	rjmp	10f
	ldi	r18, lo8(YMAX16)
	ldi	r19, hi8(YMAX16)
10:	; x = CX16 + qx: 0 when qx < -CX16 or flag 2; XMAX16 when qx > XMAX16 - CX16 or flag 4
	movw	r20, r16
	ldi	r24, lo8(-CX16)
	ldi	r25, hi8(-CX16)
	cp	r20, r24
	cpc	r21, r25
	brge	11f
	clr	r20                     ; qx < -CX16: x = 0
	clr	r21
	rjmp	12f
11:	subi	r20, lo8(-CX16)         ; x = qx + CX16
	sbci	r21, hi8(-CX16)
12:	sbrs	r26, 1
	rjmp	13f
	clr	r20
	clr	r21
13:	ldi	r24, lo8(XMAX16 - CX16)
	ldi	r25, hi8(XMAX16 - CX16)
	cp	r24, r16                ; qx > XMAX16 - CX16 (the unclamped x > XMAX16)
	cpc	r25, r17
	brlt	14f
	sbrs	r26, 2
	rjmp	15f
14:	ldi	r20, lo8(XMAX16)
	ldi	r21, hi8(XMAX16)
15:	; k == 0: remember it; else emit(prev, this)
	tst	r12
	breq	16f
	movw	r24, r6                 ; xa, ya = the previous vertex
	movw	r22, r28
	movw	r6, r20                 ; (this one is the next's previous: kept in call-saved registers)
	movw	r28, r18
	mov	r16, r3                 ; ida
	ldi	r26, SCR_NONE           ; idb
	mov	r14, r26
	call	scr_emit
	rjmp	17f
16:	movw	r6, r20
	movw	r28, r18
17:	inc	r12
	mov	r24, r4
	cp	r24, r12
	brlo	.Ldone
	rjmp	.Lvertex

.Ldone:	pop	r29
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
	pop	r4
	pop	r3
	pop	r2
	clr	r1
	ret

; the divisor: z = max(vertex cz, ZNEARQ) -> r21:r20 (vertex at r15:r14; keeps r22 .. r25)
.Lz:	movw	r30, r14
	ldd	r20, Z + 4
	ldd	r21, Z + 5
	cpi	r20, lo8(ZNEARQ)
	ldi	r18, hi8(ZNEARQ)
	cpc	r21, r18
	brge	1f
	ldi	r20, lo8(ZNEARQ)
	ldi	r21, hi8(ZNEARQ)
1:	ret
