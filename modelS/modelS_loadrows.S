; Model S: the rows of a chunk into camera space and the screen - load_rows() of
; modelS_render.cpp in AVR assembly, bit-identical to it.
;
;   uint8_t scr_load_rows(long p, const uint8_t *rows, uint8_t nr, scr_vtx (*V)[4])
;
; For each row: its corners (scr_piece_rows_asm) moved to the piece's cube (record byte 0: x in
; the low nibble, z in the high one, * 4096), y / 4 truncated toward zero (tdiv2k), then
; scr_transform into V[k][0 .. 3]. Returns the AND of the corners' flags.
; Never touches r5 (-ffixed-r5: the video interrupt's); internal labels are local (.L).
; Args (avr-gcc): p r25:r22 (pieces < 256), rows r21:r20, nr r18, V r17:r16 (scr_vtx: 11 bytes).
; Registers: p r2, nr r3, AND r4, rows r7:r6, V cursor r9:r8, cube x * 16 r10 (x << 12 = r10 << 8),
; cube z * 16 r11, corner j r12 (across scr_transform: in the frame).
; Frame (Y + 1 ..): the row's corners C[4] (COORD_3D x, y, z int32: 48 bytes), j at 49.
#include <avr/io.h>
#define FRAME 49

	.extern	scr_praw
	.extern	scr_piece_rows_asm
	.extern	scr_transform

	.section .text.scr_load_rows
	.global	scr_load_rows

; r25:r24:r23:r22 = the int32 at Y + r24 (offset), plus (r26 << 8: the cube offset, 0 for y)
.Lld:	movw	r30, r28
	add	r30, r24
	adc	r31, r1
	ld	r22, Z
	ldd	r23, Z + 1
	ldd	r24, Z + 2
	ldd	r25, Z + 3
	add	r23, r26                ; + cube * 4096 = (cube * 16) << 8
	adc	r24, r1
	adc	r25, r1
	ret

scr_load_rows:
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

	mov	r2, r22                 ; p
	movw	r6, r20                 ; rows
	mov	r3, r18                 ; nr
	movw	r8, r16                 ; V
	call	scr_praw                ; (p still in r25:r22: nothing above may touch them) -> the record
	movw	r30, r24
	ld	r24, Z                  ; byte 0: cube x | z << 4
	mov	r10, r24
	andi	r24, 0x0F
	swap	r24                     ; x * 16
	mov	r25, r10
	andi	r25, 0xF0               ; z * 16
	mov	r10, r24
	mov	r11, r25
	ldi	r24, 0xFF
	mov	r4, r24                 ; AND of the flags

.Lrow:	tst	r3
	brne	1f
	rjmp	.Ldone
1:	mov	r22, r2                 ; scr_piece_rows_asm(p, rows, 1, C)
	clr	r23
	clr	r24
	clr	r25
	movw	r20, r6
	ldi	r18, 1
	movw	r16, r28
	subi	r16, lo8(-1)
	sbci	r17, hi8(-1)
	call	scr_piece_rows_asm
	clr	r24
	std	Y + 49, r24             ; j = 0
.Lcorner:
	ldd	r12, Y + 49             ; C[j] at Y + 1 + 12 j
	ldi	r24, 12
	mul	r12, r24
	mov	r12, r0
	clr	r1
	inc	r12                     ; (offset of C[j].x from Y)
	; z = C[j].z + cube z: -> r17:r14
	mov	r24, r12
	subi	r24, -8
	mov	r26, r11
	rcall	.Lld
	movw	r14, r22
	movw	r16, r24
	; y = tdiv2k(C[j].y, 2): -> r21:r18
	mov	r24, r12
	subi	r24, -4
	clr	r26
	rcall	.Lld
	sbrs	r25, 7
	rjmp	2f
	subi	r22, lo8(-3)            ; negative: (y + 3) >> 2 truncates toward zero
	sbci	r23, hi8(-3)
	sbci	r24, hlo8(-3)
	sbci	r25, hhi8(-3)
2:	asr	r25
	ror	r24
	ror	r23
	ror	r22
	asr	r25
	ror	r24
	ror	r23
	ror	r22
	movw	r18, r22
	movw	r20, r24
	; x = C[j].x + cube x: -> r25:r22
	mov	r24, r12
	mov	r26, r10
	rcall	.Lld
	movw	r12, r8                 ; v = V[k][j]
	push	r12
	push	r13
	call	scr_transform
	pop	r31                     ; AND = AND & v->fl
	pop	r30
	ldd	r24, Z + 10
	and	r4, r24
	ldi	r24, 11                 ; next corner: V cursor + sizeof(scr_vtx) (11 on the AVR: no padding)
	add	r8, r24
	adc	r9, r1
	ldd	r24, Y + 49
	inc	r24
	std	Y + 49, r24
	cpi	r24, 4
	breq	3f
	rjmp	.Lcorner
3:	ldi	r24, 1                  ; next row
	add	r6, r24
	adc	r7, r1
	dec	r3
	rjmp	.Lrow

.Ldone:	mov	r24, r4
	adiw	r28, FRAME
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
