; Model S: one vertex to camera space and the screen, in AVR assembly (transform() in
; modelS_render.cpp, bit-identical to it).
;
;   void scr_transform(int32_t wx, int32_t wy, int32_t wz, scr_vtx *v)
;
;   d = (w - eye) >> 2 (int16); c = scr_cam3(d)       camera space, quarter units
;   v->cx, cy, cz = c; v->fl = 0
;   cz < ZNEARQ: fl = 1 (behind), sx = sy = 0
;   sx = CX16 + sdiv32_16(FX16 * cx, cz), sy = CY16 - sdiv32_16(FY16 * cy, cz)  (17-bit sums)
;   fl |= 2 (sx < 0), 4 (sx > XMAX16), 8 (|sy| > YSANE); sx, sy saturated to +-32000
; scr_vtx: sx 0, sy 2, cx 4, cy 6, cz 8, fl 10.
; Args (avr-gcc): wx r25:r22, wy r21:r18, wz r17:r14, v r13:r12. Never touches r5 (-ffixed-r5:
; it belongs to the video interrupt).
#include <avr/io.h>
#define CX16    2048
#define CY16    880
#define XMAX16  4088
#define ZNEARQ  2
#define YSANE   30000
#define FX16    3994
#define FY16    2125

	.extern	scr_cam3
	.extern	sdiv32_16
	.extern	scr_eye

	.section .text.scr_transform
	.global	scr_transform

; r25:r24 (signed 16) * constant in r21:r20 (positive, < 32768) -> r25:r24:r23:r22 (signed 32)
; (the argument layout of sdiv32_16's dividend). Uses r0, r1 (cleared), r18, r19, r26.
.Ltr_mulk:
	movw	r18, r24
	clr	r26
	muls	r19, r21                ; ah*bh
	movw	r24, r0
	mul	r18, r20                ; al*bl
	movw	r22, r0
	mulsu	r19, r20                ; ah*bl
	sbc	r25, r26
	add	r23, r0
	adc	r24, r1
	adc	r25, r26
	mulsu	r21, r18                ; bh*al (bh >= 0: no sign correction)
	add	r23, r0
	adc	r24, r1
	adc	r25, r26
	clr	r1
	ret

scr_transform:
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
	in	r28, _SFR_IO_ADDR(SPL)  ; frame: c[3] (12 bytes) at Y+1
	in	r29, _SFR_IO_ADDR(SPH)
	sbiw	r28, 12
	in	r0, _SFR_IO_ADDR(SREG)
	cli
	out	_SFR_IO_ADDR(SPH), r29
	out	_SFR_IO_ADDR(SREG), r0
	out	_SFR_IO_ADDR(SPL), r28

	; d0 = (wx - eye[0]) >> 2 -> r25:r24 for scr_cam3 (low 16 bits of the 32-bit result)
	; d1 = (wy - eye[1]) >> 2 -> r23:r22, d2 = (wz - eye[2]) >> 2 -> r21:r20
	lds	r26, scr_eye + 0
	lds	r27, scr_eye + 1
	lds	r30, scr_eye + 2
	lds	r31, scr_eye + 3
	sub	r22, r26
	sbc	r23, r27
	sbc	r24, r30
	sbc	r25, r31
	asr	r25
	ror	r24
	ror	r23
	ror	r22
	asr	r25
	ror	r24
	ror	r23
	ror	r22
	movw	r10, r22                ; d0
	lds	r26, scr_eye + 4
	lds	r27, scr_eye + 5
	lds	r30, scr_eye + 6
	lds	r31, scr_eye + 7
	sub	r18, r26
	sbc	r19, r27
	sbc	r20, r30
	sbc	r21, r31
	asr	r21
	ror	r20
	ror	r19
	ror	r18
	asr	r21
	ror	r20
	ror	r19
	ror	r18                     ; d1 = r19:r18
	lds	r26, scr_eye + 8
	lds	r27, scr_eye + 9
	lds	r30, scr_eye + 10
	lds	r31, scr_eye + 11
	sub	r14, r26
	sbc	r15, r27
	sbc	r16, r30
	sbc	r17, r31
	asr	r17
	ror	r16
	ror	r15
	ror	r14
	asr	r17
	ror	r16
	ror	r15
	ror	r14                     ; d2 = r15:r14
	movw	r24, r10                ; scr_cam3(d0, d1, d2, c)
	movw	r22, r18
	movw	r20, r14
	movw	r18, r28
	subi	r18, lo8(-1)
	sbci	r19, hi8(-1)
	call	scr_cam3

	; v->cx, cy, cz (low words of c[0..2]); fl = 0
	movw	r30, r12                ; Z = v
	ldd	r24, Y + 1
	ldd	r25, Y + 2
	std	Z + 4, r24
	std	Z + 5, r25
	ldd	r24, Y + 5
	ldd	r25, Y + 6
	std	Z + 6, r24
	std	Z + 7, r25
	ldd	r14, Y + 9              ; cz -> r15:r14 (kept for the divisions)
	ldd	r15, Y + 10
	std	Z + 8, r14
	std	Z + 9, r15
	std	Z + 10, r1
	ldi	r24, ZNEARQ             ; cz < ZNEARQ: behind
	cp	r14, r24
	cpc	r15, r1
	brge	1f
	ldi	r24, 1
	std	Z + 10, r24
	std	Z + 0, r1
	std	Z + 1, r1
	std	Z + 2, r1
	std	Z + 3, r1
	rjmp	.Ltr_done
1:
	; sx = CX16 + sdiv32_16(FX16 * cx, cz)  -> r17:r16:r11:r10 (17 bits, signed)
	ldd	r24, Y + 1
	ldd	r25, Y + 2
	ldi	r20, lo8(FX16)
	ldi	r21, hi8(FX16)
	rcall	.Ltr_mulk
	movw	r20, r14
	call	sdiv32_16               ; q in r25:r24
	movw	r10, r24
	clr	r16
	sbrc	r25, 7
	com	r16
	mov	r17, r16
	ldi	r24, lo8(CX16)
	ldi	r25, hi8(CX16)
	add	r10, r24
	adc	r11, r25
	adc	r16, r1
	adc	r17, r1
	movw	r30, r12
	ldd	r26, Z + 10             ; fl
	sbrc	r17, 7                  ; sx < 0
	ori	r26, 2
	ldi	r24, lo8(XMAX16)        ; sx > XMAX16 <=> XMAX16 - sx < 0
	ldi	r25, hi8(XMAX16)
	clr	r22
	clr	r23
	sub	r24, r10
	sbc	r25, r11
	sbc	r22, r16
	sbc	r23, r17
	sbrc	r23, 7
	ori	r26, 4
	std	Z + 10, r26
	rcall	.Ltr_sat32000                ; r11:r10 = saturated sx
	movw	r30, r12
	std	Z + 0, r10
	std	Z + 1, r11

	; sy = CY16 - sdiv32_16(FY16 * cy, cz)
	movw	r30, r12
	ldd	r24, Z + 6
	ldd	r25, Z + 7
	ldi	r20, lo8(FY16)
	ldi	r21, hi8(FY16)
	rcall	.Ltr_mulk
	movw	r20, r14
	call	sdiv32_16               ; q in r25:r24
	clr	r16                     ; sy = CY16 - q -> r17:r16:r11:r10
	clr	r17
	ldi	r26, lo8(CY16)
	ldi	r27, hi8(CY16)
	movw	r10, r26
	clr	r22
	sbrc	r25, 7
	com	r22                     ; q's sign byte
	sub	r10, r24
	sbc	r11, r25
	sbc	r16, r22
	sbc	r17, r22
	; |sy| > YSANE: sy > YSANE or sy < -YSANE
	movw	r30, r12
	ldd	r26, Z + 10
	ldi	r24, lo8(YSANE)         ; YSANE - sy < 0
	ldi	r25, hi8(YSANE)
	clr	r22
	clr	r23
	sub	r24, r10
	sbc	r25, r11
	sbc	r22, r16
	sbc	r23, r17
	sbrc	r23, 7
	ori	r26, 8
	ldi	r24, lo8(YSANE)         ; sy + YSANE < 0
	ldi	r25, hi8(YSANE)
	add	r24, r10
	adc	r25, r11
	mov	r22, r16
	mov	r23, r17
	adc	r22, r1
	adc	r23, r1
	sbrc	r23, 7
	ori	r26, 8
	std	Z + 10, r26
	rcall	.Ltr_sat32000
	movw	r30, r12
	std	Z + 2, r10
	std	Z + 3, r11

.Ltr_done:	adiw	r28, 12
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
	clr	r1
	ret

; r17:r16:r11:r10 (signed 32) -> r11:r10 saturated to +-32000. Uses r24, r25, r22, r23.
.Ltr_sat32000:
	ldi	r24, lo8(32000)         ; 32000 - x < 0: x = 32000
	ldi	r25, hi8(32000)
	clr	r22
	clr	r23
	sub	r24, r10
	sbc	r25, r11
	sbc	r22, r16
	sbc	r23, r17
	brpl	1f
	ldi	r24, lo8(32000)
	ldi	r25, hi8(32000)
	movw	r10, r24
	ret
1:	ldi	r24, lo8(32000)         ; x + 32000 < 0: x = -32000
	ldi	r25, hi8(32000)
	add	r24, r10
	adc	r25, r11
	mov	r22, r16
	mov	r23, r17
	adc	r22, r1
	adc	r23, r1
	brpl	2f
	ldi	r24, lo8(-32000)
	ldi	r25, hi8(-32000)
	movw	r10, r24
2:	ret
