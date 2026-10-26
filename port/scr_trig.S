; The rotation coefficients of CalcYXZTrigCoefficients() (3D_Engine.cpp) in AVR assembly,
; bit-identical to it (the physics' own arithmetic: 32-bit products, division by PRECISION
; truncating toward zero).
;
;   void scr_trig9(const int16_t *sc, short *out)       sc: sin x, y, z, cos x, y, z
;
; Values v: 0 sx, 1 sy, 2 sz, 3 cx, 4 cy, 5 cz, 6 sx*sy/P, 7 sx*cy/P, 8 zero, 9 P (16384).
; Each entry: (+-v[a] v[b] +- v[c] v[d]) / P; the first two give v6, v7, the next nine out[0..8]:
;   X_X =  cy cz + sxsy sz   X_Y = -cx sz             X_Z = -sy cz + sxcy sz
;   Y_X =  cy sz - sxsy cz   Y_Y =  cx cz             Y_Z = -sy sz - sxcy cz
;   Z_X =  cx sy             Z_Y =  sx P / P (= sx)   Z_Z =  cx cy
; Never touches r5 (-ffixed-r5: the video interrupt's); internal labels are local (.L).
; Args (avr-gcc): sc r25:r24, out r23:r22.
#include <avr/io.h>
#define FRAME 20

	.section .progmem.scr_trig9, "a", @progbits
.Ltab:	; a | b << 4, c | d << 4, signs (1: - first, 2: - second)
	.byte	0x10, 0x88, 0           ; v6 = sx sy / P
	.byte	0x40, 0x88, 0           ; v7 = sx cy / P
	.byte	0x54, 0x26, 0           ; X_X
	.byte	0x23, 0x88, 1           ; X_Y
	.byte	0x51, 0x27, 1           ; X_Z
	.byte	0x24, 0x56, 2           ; Y_X
	.byte	0x53, 0x88, 0           ; Y_Y
	.byte	0x21, 0x57, 3           ; Y_Z
	.byte	0x13, 0x88, 0           ; Z_X
	.byte	0x90, 0x88, 0           ; Z_Y = sx
	.byte	0x43, 0x88, 0           ; Z_Z

	.section .text.scr_trig9
	.global	scr_trig9

; (r23:r22) * (r21:r20), signed -> r25:r24:r19:r18. Uses r0, r1 (cleared), r26.
.Lmul:	clr	r26
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

; the product of v[low nibble] and v[high nibble] of r24 -> r25:r24:r19:r18
.Lprod:	mov	r25, r24
	andi	r24, 0x0F
	swap	r25
	andi	r25, 0x0F
	movw	r26, r28                ; X = &v[a] = Y + 1 + 2 a
	adiw	r26, 1
	add	r26, r24
	adc	r27, r1
	add	r26, r24
	adc	r27, r1
	ld	r22, X+
	ld	r23, X
	movw	r26, r28                ; X = &v[b]
	adiw	r26, 1
	add	r26, r25
	adc	r27, r1
	add	r26, r25
	adc	r27, r1
	ld	r20, X+
	ld	r21, X
	rjmp	.Lmul

; r25:r24:r19:r18 = -r25:r24:r19:r18
.Lneg:	com	r25
	com	r24
	com	r19
	neg	r18
	sbci	r19, -1
	sbci	r24, -1
	sbci	r25, -1
	ret

scr_trig9:
	push	r12
	push	r13
	push	r14
	push	r15
	push	r16
	push	r17
	push	r28
	push	r29
	in	r28, _SFR_IO_ADDR(SPL)
	in	r29, _SFR_IO_ADDR(SPH)
	sbiw	r28, FRAME
	in	r0, _SFR_IO_ADDR(SREG)
	cli
	out	_SFR_IO_ADDR(SPH), r29
	out	_SFR_IO_ADDR(SREG), r0
	out	_SFR_IO_ADDR(SPL), r28

	movw	r12, r22                ; out
	movw	r30, r24                ; v0 .. v5 = sc[0 .. 5]
	movw	r26, r28
	adiw	r26, 1
	ldi	r18, 12
1:	ld	r0, Z+
	st	X+, r0
	dec	r18
	brne	1b
	std	Y + 17, r1              ; v8 = 0
	std	Y + 18, r1
	std	Y + 19, r1              ; v9 = P = 0x4000
	ldi	r18, 0x40
	std	Y + 20, r18

	ldi	r30, lo8(.Ltab)
	ldi	r31, hi8(.Ltab)
	clr	r17                     ; (r16: entry 0 .. 10)
	clr	r16
.Lentry:
	lpm	r24, Z+                 ; T = +- v[a] v[b] (kept on the stack)
	rcall	.Lprod
	lpm	r27, Z+                 ; (c | d << 4, kept)
	lpm	r20, Z                  ; signs (Z stays on it)
	sbrc	r20, 0
	rcall	.Lneg
	push	r18                     ; T (first product)
	push	r19
	push	r24
	push	r25
	mov	r24, r27
	rcall	.Lprod                  ; second product
	lpm	r20, Z+                 ; signs again; Z -> the next entry
	sbrc	r20, 1
	rcall	.Lneg
	pop	r21                     ; T += it: r25:r24:r19:r18
	pop	r20
	pop	r15
	pop	r14
	add	r18, r14
	adc	r19, r15
	adc	r24, r20
	adc	r25, r21
	sbrs	r25, 7                  ; T < 0: + (P - 1), so the shift truncates toward zero
	rjmp	2f
	subi	r18, lo8(-16383)
	sbci	r19, hi8(-16383)
	sbci	r24, hlo8(-16383)
	sbci	r25, hhi8(-16383)
2:	lsl	r18                     ; T >> 14 (16 bits): (T << 2) >> 16
	rol	r19
	rol	r24
	rol	r25
	lsl	r18
	rol	r19
	rol	r24
	rol	r25
	cpi	r16, 2                  ; entries 0, 1: v6, v7; then out[0 .. 8]
	brsh	3f
	movw	r26, r28
	adiw	r26, 13                 ; &v6
	add	r26, r16
	adc	r27, r1
	add	r26, r16
	adc	r27, r1
	rjmp	4f
3:	movw	r26, r12
	mov	r18, r16
	subi	r18, 2
	add	r26, r18
	adc	r27, r1
	add	r26, r18
	adc	r27, r1
4:	st	X+, r24
	st	X, r25
	inc	r16
	cpi	r16, 11
	breq	.Ldone
	rjmp	.Lentry

.Ldone:	adiw	r28, FRAME
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
	clr	r1
	ret
