; the unrolled variant of fastmath.S (game/Makefile FASTDIV=1): same results, ~2% faster rendering
/* int16_t sdiv32_16(int32_t n, uint16_t d): n / d for d > 0, truncating toward zero,
 * saturated to +-32767. Restoring division, 16 quotient bits, ~200 cycles
 * (libgcc's 32/32 division costs ~950 here). */
	.section .text
	.global sdiv32_16
	.type sdiv32_16, @function
sdiv32_16:
	clt
	tst	r25
	brpl	1f
	set                             ; negative dividend: divide |n|, negate result
	com	r25
	com	r24
	com	r23
	neg	r22
	sbci	r23, 0xFF
	sbci	r24, 0xFF
	sbci	r25, 0xFF
1:	cp	r24, r20                ; quotient must fit 16 bits: n >> 16 < d
	cpc	r25, r21
	brlo	0f
	rjmp	sat
0:
	; quotient < 256 (about half the slopes)? Then its top 8 bits are zero: skip those
	; 8 steps with one byte shift. Exact: valid iff (n >> 8) < d.
	tst	r25
	brne	q_full
	cp	r23, r20
	cpc	r24, r21
	brsh	q_full
	mov	r25, r24
	mov	r24, r23
	mov	r23, r22
	clr	r22
	rjmp	q_step8
q_full:	; 16 quotient bits, unrolled
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
q_step8:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	1f
	cp	r24, r20
	cpc	r25, r21
	brlo	2f
1:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
2:
	movw	r24, r22
	tst	r25
	brmi	sat
	brtc	5f
	com	r25
	neg	r24
	sbci	r25, 0xFF
5:	ret
sat:	ldi	r24, 0xFF
	ldi	r25, 0x7F
	brtc	6f
	ldi	r24, 0x01
	ldi	r25, 0x80
6:	ret
	.size sdiv32_16, .-sdiv32_16

/* uint16 core: (r25:r24:r23:r22) / (r21:r20) with r25:r24 < d.
 * quotient -> r23:r22, remainder -> r25:r24. Uses r18. */
udiv_core:
	ldi	r18, 16
1:	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	brcs	2f
	cp	r24, r20
	cpc	r25, r21
	brlo	3f
2:	sub	r24, r20
	sbc	r25, r21
	ori	r22, 1
3:	dec	r18
	brne	1b
	ret

/* int32_t sdiv32_16_32(int32_t n, uint16_t d): n / d for d > 0, truncating toward
 * zero, full 32-bit quotient (two 16-bit division steps). Uses r18, r26, r27, r30, r31. */
	.global sdiv32_16_32
	.type sdiv32_16_32, @function
sdiv32_16_32:
	clt
	tst	r25
	brpl	1f
	set
	com	r25
	com	r24
	com	r23
	neg	r22
	sbci	r23, 0xFF
	sbci	r24, 0xFF
	sbci	r25, 0xFF
1:	movw	r26, r22                ; n low word
	movw	r22, r24                ; high word / d
	clr	r24
	clr	r25
	rcall	udiv_core
	movw	r30, r22                ; quotient high word
	movw	r22, r26                ; (remainder : low word) / d
	rcall	udiv_core
	movw	r24, r30
	brtc	2f
	com	r25
	com	r24
	com	r23
	neg	r22
	sbci	r23, 0xFF
	sbci	r24, 0xFF
	sbci	r25, 0xFF
2:	ret
	.size sdiv32_16_32, .-sdiv32_16_32
