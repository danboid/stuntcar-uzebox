; void scr_cam3(int16_t d0, int16_t d1, int16_t d2, int32_t *c)
;   c[j] = ((int32_t)d0 * R[j] + (int32_t)d1 * R[3 + j] + (int32_t)d2 * R[6 + j]) >> 14, j = 0..2
;   R = scr_Rm (int16_t[9], row-major, Q14). Bit-identical to the C version (modelS_render.cpp).
; Args: d0 r25:r24, d1 r23:r22, d2 r21:r20, c r19:r18.
; muls/mulsu need r16..r23: d0 -> r17:r16, d1 -> r19:r18, d2 -> r21:r20, R word r23:r22;
; accumulator r15:r14:r13:r12, zero r24, counter r25, c in X.
	.extern scr_Rm
	.section .text.scr_cam3
	.global scr_cam3

	.macro	MACC ah, al, off            ; acc += (\ah:\al) * R word at Z+off
	ldd	r22, Z+\off
	ldd	r23, Z+\off+1
	muls	\ah, r23                ; ah*bh -> bits 16..31
	add	r14, r0
	adc	r15, r1
	mul	\al, r22                ; al*bl -> bits 0..15
	add	r12, r0
	adc	r13, r1
	adc	r14, r24
	adc	r15, r24
	mulsu	\ah, r22                ; ah*bl -> bits 8..23 (signed)
	sbc	r15, r24
	add	r13, r0
	adc	r14, r1
	adc	r15, r24
	mulsu	r23, \al                ; bh*al -> bits 8..23 (signed)
	sbc	r15, r24
	add	r13, r0
	adc	r14, r1
	adc	r15, r24
	.endm

scr_cam3:
	push	r12
	push	r13
	push	r14
	push	r15
	push	r16
	push	r17
	movw	r26, r18                ; X = c
	movw	r16, r24                ; d0
	movw	r18, r22                ; d1
	clr	r24
	ldi	r25, 3
	ldi	r30, lo8(scr_Rm)
	ldi	r31, hi8(scr_Rm)
1:	clr	r12
	clr	r13
	clr	r14
	clr	r15
	MACC	r17, r16, 0
	MACC	r19, r18, 6
	MACC	r21, r20, 12
	clr	r22                     ; >> 14: sign-extend to 40 bits, << 2, keep bytes 2..4
	sbrc	r15, 7
	com	r22
	mov	r23, r22                ; (sign byte for the result's top)
	lsl	r12
	rol	r13
	rol	r14
	rol	r15
	rol	r22
	lsl	r12
	rol	r13
	rol	r14
	rol	r15
	rol	r22
	st	X+, r14
	st	X+, r15
	st	X+, r22
	st	X+, r23
	adiw	r30, 2                  ; next column of R
	dec	r25
	breq	2f
	rjmp	1b                      ; (the loop is too long for brne)
2:	clr	r1
	pop	r17
	pop	r16
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	ret
