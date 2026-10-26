; Model S: polygon clipping against one plane, in AVR assembly (clip_plane() and plane() in
; modelS_render.cpp, bit-identical to them).
;
;   uint8_t scr_clip_plane(uint8_t n, uint8_t k, int16_t (*in)[4], int16_t (*out)[4])
;
; Sutherland-Hodgman: vertices [cx, cy, cz, on-plane flags] in camera space (quarter units).
; Plane k (f >= 0: inside):
;   0: cz - ZNEARQ          1: FX16 cx + CX16 cz           2: (XMAX16 - CX16) cz - FX16 cx
;   3: (CY16 - YMIN16) cz - FY16 cy                        4: FY16 cy + (YMAX16 - CY16) cz
; Each vertex is evaluated once (f of the edge's end is the .Lclip_next edge's start). An inside
; vertex is copied; where an edge crosses the plane, the crossing is added:
;   den = fa - fb, num = fa (both negated if den < 0, both halved while den > 32767),
;   t = sdiv32_16(num << 14, den), c = a + (int16)(((int32)(b - a) * t) >> 14),
;   flags = (flags a & flags b) | 1 << k.  At most CMAX vertices out. Returns their number.
; Args (avr-gcc): n r24, k r22, in r21:r20, out r19:r18. Never touches r5 (-ffixed-r5: it
; belongs to the video interrupt).
; Registers: n r2, k r3, m r4, i r10, in r7:r6, out cursor r9:r8, fa r15:r14:r13:r12,
; fb r29:r28:r17:r16, in[i] r11 (offset), in[j] Z.

#define CMAX    21
#define ZNEARQ  2
#define FX16    3994
#define FY16    2125
#define CX16    2048
#define XMAX16  4088
#define CY16    880
#define YMIN16  (-64)
#define YMAX16  (110 * 16 + 64)

	.extern	sdiv32_16

	.section .text.scr_clip_plane
	.global	scr_clip_plane

; (r23:r22) * (r21:r20), signed -> r25:r24:r19:r18. Uses r0, r1 (cleared), r26.
.Lclip_cmul16s:
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

; f = plane k (r3) of the vertex at Z -> r25:r24:r23:r22 (signed 32). Uses r18-r21, r26, r27.
.Lclip_planef:
	ldd	r22, Z + 4              ; cz
	ldd	r23, Z + 5
	tst	r3
	brne	1f
	subi	r22, lo8(ZNEARQ)        ; k 0: cz - ZNEARQ (sign-extended)
	sbci	r23, hi8(ZNEARQ)
	clr	r24
	sbrc	r23, 7
	com	r24
	mov	r25, r24
	ret
1:	; C * cz, C by k: 1 -> CX16, 2 -> XMAX16 - CX16, 3 -> CY16 - YMIN16, 4 -> YMAX16 - CY16
	ldi	r20, lo8(CX16)
	ldi	r21, hi8(CX16)
	mov	r26, r3
	cpi	r26, 1
	breq	2f
	ldi	r20, lo8(XMAX16 - CX16)
	ldi	r21, hi8(XMAX16 - CX16)
	cpi	r26, 2
	breq	2f
	ldi	r20, lo8(CY16 - YMIN16)
	ldi	r21, hi8(CY16 - YMIN16)
	cpi	r26, 3
	breq	2f
	ldi	r20, lo8(YMAX16 - CY16)
	ldi	r21, hi8(YMAX16 - CY16)
2:	rcall	.Lclip_cmul16s                 ; r25:r24:r19:r18 = C * cz
	push	r18                     ; (keep it)
	push	r19
	push	r24
	push	r25
	; A * (cx or cy): k 1, 2: FX16 * cx; k 3, 4: FY16 * cy
	mov	r26, r3
	cpi	r26, 3
	brsh	3f
	ld	r22, Z                  ; cx
	ldd	r23, Z + 1
	ldi	r20, lo8(FX16)
	ldi	r21, hi8(FX16)
	rjmp	4f
3:	ldd	r22, Z + 2              ; cy
	ldd	r23, Z + 3
	ldi	r20, lo8(FY16)
	ldi	r21, hi8(FY16)
4:	rcall	.Lclip_cmul16s                 ; r25:r24:r19:r18 = A * v
	pop	r21                     ; C * cz -> r21:r20:r27:r26
	pop	r20
	pop	r27
	pop	r26
	mov	r22, r3                 ; k 2, 3: f = C cz - A v; k 1, 4: f = A v + C cz
	cpi	r22, 2
	breq	5f
	cpi	r22, 3
	breq	5f
	add	r18, r26
	adc	r19, r27
	adc	r24, r20
	adc	r25, r21
	movw	r22, r18
	ret
5:	sub	r26, r18
	sbc	r27, r19
	sbc	r20, r24
	sbc	r21, r25
	movw	r22, r26
	movw	r24, r20
	ret

scr_clip_plane:
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
	mov	r2, r24                 ; n
	mov	r3, r22                 ; k
	movw	r6, r20                 ; in
	movw	r8, r18                 ; out cursor
	clr	r4                      ; m
	tst	r2
	brne	1f
	rjmp	.Lclip_ret_m
1:	movw	r30, r6                 ; fb = f(in[0])
	rcall	.Lclip_planef
	movw	r16, r22
	movw	r28, r24
	clr	r10                     ; i = 0

.Lclip_loop:	movw	r12, r16                ; fa = fb
	movw	r14, r28
	mov	r24, r10                ; j = i + 1 == n ? 0 : i + 1
	inc	r24
	cp	r24, r2
	brne	2f
	clr	r24
2:	movw	r30, r6                 ; Z = in[j]
	lsl	r24
	lsl	r24
	lsl	r24
	add	r30, r24
	adc	r31, r1
	push	r30
	push	r31
	rcall	.Lclip_planef                  ; fb = f(in[j])
	movw	r16, r22
	movw	r28, r24
	; in[i] -> X
	mov	r24, r10
	lsl	r24
	lsl	r24
	lsl	r24
	movw	r26, r6
	add	r26, r24
	adc	r27, r1
	; fa >= 0 && m < CMAX: copy in[i]
	sbrc	r15, 7
	rjmp	3f
	mov	r24, r4
	cpi	r24, CMAX
	brsh	3f
	movw	r30, r8
	ldi	r25, 8
6:	ld	r24, X+
	st	Z+, r24
	dec	r25
	brne	6b
	sbiw	r26, 8
	movw	r8, r30
	inc	r4
3:	; (fa >= 0) != (fb >= 0) && m < CMAX: the crossing
	pop	r31                     ; Z = in[j]
	pop	r30
	mov	r24, r15
	eor	r24, r29
	sbrs	r24, 7
	rjmp	.Lclip_next
	mov	r24, r4
	cpi	r24, CMAX
	brlo	7f
	rjmp	.Lclip_next
7:	push	r26                     ; (in[i], in[j] kept over the division)
	push	r27
	push	r30
	push	r31
	; den = fa - fb -> r21:r20:r19:r18, num = fa -> r25:r24:r23:r22
	movw	r18, r12
	movw	r20, r14
	sub	r18, r16
	sbc	r19, r17
	sbc	r20, r28
	sbc	r21, r29
	movw	r22, r12
	movw	r24, r14
	sbrs	r21, 7                  ; den < 0: negate both
	rjmp	8f
	com	r21
	com	r20
	com	r19
	neg	r18
	sbci	r19, -1
	sbci	r20, -1
	sbci	r21, -1
	com	r25
	com	r24
	com	r23
	neg	r22
	sbci	r23, -1
	sbci	r24, -1
	sbci	r25, -1
8:	; while (den > 32767) { den >>= 1; num >>= 1; }
	tst	r21
	brne	9f
	tst	r20
	brne	9f
	sbrs	r19, 7
	rjmp	10f
9:	lsr	r21
	ror	r20
	ror	r19
	ror	r18
	asr	r25
	ror	r24
	ror	r23
	ror	r22
	rjmp	8b
10:	; t = sdiv32_16(num << 14, den): num << 16 >> 2
	mov	r25, r23
	mov	r24, r22
	clr	r23
	clr	r22
	asr	r25
	ror	r24
	ror	r23
	asr	r25
	ror	r24
	ror	r23
	movw	r20, r18
	call	sdiv32_16               ; t in r25:r24 (0 .. 16384)
	movw	r22, r24                ; t -> r23:r22
	pop	r31                     ; Z = in[j], X = in[i]
	pop	r30
	pop	r27
	pop	r26
	movw	r18, r8                 ; out[m] -> r19:r18
	ldi	r20, 3                  ; c = 0 .. 2
11:	push	r20
	ld	r20, X+                 ; a = in[i][c]
	ld	r21, X+
	ld	r24, Z+                 ; b = in[j][c]
	ld	r25, Z+
	clr	r0                      ; diff = b - a, 17 bits: low word r25:r24, sign r0 (0 / 0xFF)
	sbrc	r25, 7
	com	r0
	clr	r1
	sbrc	r21, 7
	com	r1
	sub	r24, r20
	sbc	r25, r21
	sbc	r0, r1
	clr	r1
	push	r20                     ; a
	push	r21
	push	r26                     ; (.Lclip_pmul uses r26, r27)
	push	r27
	rcall	.Lclip_pmul                    ; p = diff * t -> r21:r20:r25:r24
	pop	r27
	pop	r26
	lsl	r24                     ; (p >> 14) & 0xFFFF = (p << 2) >> 16
	rol	r25
	rol	r20
	rol	r21
	lsl	r24
	rol	r25
	rol	r20
	rol	r21
	pop	r25                     ; a
	pop	r24
	add	r20, r24                ; out[m][c] = a + that
	adc	r21, r25
	push	r30
	push	r31
	movw	r30, r18
	st	Z+, r20
	st	Z+, r21
	movw	r18, r30
	pop	r31
	pop	r30
	pop	r20
	dec	r20
	brne	11b
	; flags: (in[i][3] & in[j][3]) | 1 << k (X, Z at element 3; the flags fit the low byte)
	ld	r24, X
	ld	r25, Z
	and	r24, r25
	ldi	r25, 1
	mov	r20, r3
12:	tst	r20
	breq	13f
	lsl	r25
	dec	r20
	rjmp	12b
13:	or	r24, r25
	movw	r30, r18
	st	Z+, r24
	st	Z+, r1
	movw	r8, r30
	inc	r4
.Lclip_next:	inc	r10
	cp	r10, r2
	breq	.Lclip_ret_m
	rjmp	.Lclip_loop

.Lclip_ret_m:	mov	r24, r4
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
	pop	r4
	pop	r3
	pop	r2
	clr	r1
	ret

; p = (r25:r24, unsigned) * (r23:r22, unsigned) - (r0 != 0 ? r23:r22 << 16 : 0)
;   -> r21:r20:r25:r24 (signed 32: the 17-bit signed difference times t)
; Uses r0, r1 (cleared), r26, r27.
.Lclip_pmul:
	push	r0
	mul	r24, r22                ; lo*lo -> bits 0..15
	movw	r26, r0
	mul	r25, r23                ; hi*hi -> bits 16..31
	movw	r20, r0
	mul	r24, r23                ; lo*hi -> bits 8..23
	add	r27, r0
	adc	r20, r1
	clr	r0
	adc	r21, r0
	mul	r25, r22                ; hi*lo -> bits 8..23
	add	r27, r0
	adc	r20, r1
	clr	r0
	adc	r21, r0
	movw	r24, r26
	pop	r0
	tst	r0                      ; negative difference: - t << 16
	breq	1f
	sub	r20, r22
	sbc	r21, r23
1:	clr	r1
	ret
