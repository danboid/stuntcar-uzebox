; Model S: the opponent's car - its 24 model points to camera space and the screen.
;
;   void scr_car_vertices(const int16_t *M, const int32_t *t, scr_vtx *v)
;
; For each point p of car_pts (x, y, z / 2 as signed bytes, in flash): w_j = t_j +
; ((p . column j of M) >> 14) (M: Q14, row-major), then scr_transform(w0, w1, w2, v + i).
; Never touches r5 (-ffixed-r5: the video interrupt's); internal labels are local (.L).
; Args (avr-gcc): M r25:r24, t r23:r22, v r21:r20.
; Registers: count r2, flash pointer r4:r3, M r7:r6, t r9:r8, v r11:r10, accumulator r17:r14.
; Frame (Y + 1 ..): p0, p1, p2 (int16) at 1, w0, w1, w2 (int32) at 7.
#include <avr/io.h>
#define FRAME 18

	.extern	scr_transform
	.extern	car_pts_flash

	.section .text.scr_car_vertices
	.global	scr_car_vertices

; acc (r17:r16:r15:r14) += (r23:r22) * (r21:r20), signed. Uses r0, r1 (cleared), r26.
.Lmac:	clr	r26
	muls	r23, r21                ; ah * bh -> bytes 2, 3
	add	r16, r0
	adc	r17, r1
	mul	r22, r20                ; al * bl -> bytes 0, 1
	add	r14, r0
	adc	r15, r1
	adc	r16, r26
	adc	r17, r26
	mulsu	r23, r20                ; ah * bl (signed) -> bytes 1, 2 (sign into 3)
	sbc	r17, r26
	add	r15, r0
	adc	r16, r1
	adc	r17, r26
	mulsu	r21, r22                ; bh * al (signed) -> bytes 1, 2 (sign into 3)
	sbc	r17, r26
	add	r15, r0
	adc	r16, r1
	adc	r17, r26
	clr	r1
	ret

; a signed byte from flash at r4:r3 (post-increment) -> r25:r24
.Lbyte:	mov	r30, r3
	mov	r31, r4
	lpm	r24, Z+
	mov	r3, r30
	mov	r4, r31
	clr	r25
	sbrc	r24, 7
	com	r25
	ret

scr_car_vertices:
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
	in	r28, _SFR_IO_ADDR(SPL)
	in	r29, _SFR_IO_ADDR(SPH)
	sbiw	r28, FRAME
	in	r0, _SFR_IO_ADDR(SREG)
	cli
	out	_SFR_IO_ADDR(SPH), r29
	out	_SFR_IO_ADDR(SREG), r0
	out	_SFR_IO_ADDR(SPL), r28

	movw	r6, r24                 ; M
	movw	r8, r22                 ; t
	movw	r10, r20                ; v
	ldi	r24, lo8(car_pts_flash)
	mov	r3, r24
	ldi	r24, hi8(car_pts_flash)
	mov	r4, r24
	ldi	r24, 24
	mov	r2, r24

.Lpoint:
	rcall	.Lbyte                  ; p0, p1, p2 (= 2 z) -> the frame
	std	Y + 1, r24
	std	Y + 2, r25
	rcall	.Lbyte
	std	Y + 3, r24
	std	Y + 4, r25
	rcall	.Lbyte
	lsl	r24
	rol	r25
	std	Y + 5, r24
	std	Y + 6, r25
	clr	r12                     ; j = 0 .. 2 (r12: 2 j, the column's byte offset)
.Lcol:	clr	r14                     ; acc = p0 M[j] + p1 M[3 + j] + p2 M[6 + j]
	clr	r15
	movw	r16, r14
	movw	r30, r6
	add	r30, r12
	adc	r31, r1
	ldd	r22, Y + 1
	ldd	r23, Y + 2
	ld	r20, Z
	ldd	r21, Z + 1
	rcall	.Lmac
	movw	r30, r6
	add	r30, r12
	adc	r31, r1
	ldd	r22, Y + 3
	ldd	r23, Y + 4
	ldd	r20, Z + 6
	ldd	r21, Z + 7
	rcall	.Lmac
	movw	r30, r6
	add	r30, r12
	adc	r31, r1
	ldd	r22, Y + 5
	ldd	r23, Y + 6
	ldd	r20, Z + 12
	ldd	r21, Z + 13
	rcall	.Lmac
	lsl	r14                     ; acc >> 14 (it fits 16 bits): ((acc << 2) >> 16)
	rol	r15
	rol	r16
	rol	r17
	lsl	r14
	rol	r15
	rol	r16
	rol	r17
	clr	r24                     ; sign-extended, + t[j] -> w[j]
	sbrc	r17, 7
	com	r24
	movw	r30, r8                 ; Z = &t[j] (4 bytes each: 2 * (2 j))
	add	r30, r12
	adc	r31, r1
	add	r30, r12
	adc	r31, r1
	ld	r20, Z
	ldd	r21, Z + 1
	ldd	r22, Z + 2
	ldd	r23, Z + 3
	add	r20, r16
	adc	r21, r17
	adc	r22, r24
	adc	r23, r24
	movw	r30, r28                ; w[j] at Y + 7 + 4 j
	adiw	r30, 7
	add	r30, r12
	adc	r31, r1
	add	r30, r12
	adc	r31, r1
	st	Z, r20
	std	Z + 1, r21
	std	Z + 2, r22
	std	Z + 3, r23
	inc	r12
	inc	r12
	ldi	r24, 6
	cp	r12, r24
	breq	.Lcall
	rjmp	.Lcol
.Lcall:	ldd	r22, Y + 7              ; scr_transform(w0, w1, w2, v)
	ldd	r23, Y + 8
	ldd	r24, Y + 9
	ldd	r25, Y + 10
	ldd	r18, Y + 11
	ldd	r19, Y + 12
	ldd	r20, Y + 13
	ldd	r21, Y + 14
	ldd	r14, Y + 15
	ldd	r15, Y + 16
	ldd	r16, Y + 17
	ldd	r17, Y + 18
	movw	r12, r10
	call	scr_transform
	ldi	r24, 11                 ; next point: + sizeof(scr_vtx) (11 on the AVR: no padding)
	add	r10, r24
	adc	r11, r1
	dec	r2
	breq	.Ldone
	rjmp	.Lpoint

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
