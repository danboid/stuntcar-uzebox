; Track .Lrows_row corners in AVR assembly (scr_piece_rows() / row_corners() in scr_track.cpp,
; bit-identical to them). Used by the Model S renderer and by the physics (scr_track_coord).
;
;   void scr_piece_rows_asm(long piece, const uint8_t *rows, uint8_t nr, COORD_3D (*out)[4])
;
; For each .Lrows_row: corners L, R, LB, RB (COORD_3D: x, y, z as int32 at 0, 4, 8; 12 bytes each).
; Row ns (the piece's segment count) is the next piece's .Lrows_row 0, moved by the cube offset.
;   na = the source record's angle/template byte: t = na & 15, reversed = na & 0x10,
;   rough angle = na & 0xc0; template points (x0, z0) of the .Lrows_row from SPI RAM, rotated:
;   0x00: (x0, z0)  0x40: (z0, 0x800 - x0)  0x80: (0x800 - x0, 0x800 - z0)  0xc0: (0x800 - z0, x0)
;   x, z = 2 * that (PC_FACTOR) + cube offset * 4096; LB, RB: the same x, z, y = 0 (TRACK_BOTTOM_Y)
;   L.y, R.y = 2 * (height profile value + the record's side shift)
; then scr_bridge_fix() (the drawbridge, in C). Never touches r5 (-ffixed-r5: the video
; interrupt's).
; Args (avr-gcc): piece r25:r22, rows r21:r20, nr r18, out r17:r16.
; Registers: piece r2 (pieces < 256), nr r3, rows r7:r6, out r9:r8, cp r10, ns r11, .Lrows_row r12,
; src r13, srow r14, dcx r15, dcz r16, na r17. Frame (Y + 1 ..): pts[4] int16 at 1, lid 9,
; rid 10, lsh 11, rsh 13, yl 15, yr 17.
#include <avr/io.h>
#define SCR_T_PIECE_Y     0x04000
#define SCR_T_PIECE_Y_OFF 0x049BA
#define SCR_T_TMPL_XZ     0x04ABA
#define FRAME 18

	.extern	scr_praw
	.extern	scr_bridge_fix
	.extern	scr_tab_ns
	.extern	scr_tab_xzoff
	.extern	NumTrackPieces
	.extern	xram_read

	.section .data
.Lrows_c_lid:	.byte	0xFF                    ; height profile start offsets, cached per side id
.Lrows_c_rid:	.byte	0xFF                    ; (ids are 0 .. 127: 0xFF never matches)
	.section .bss
.Lrows_c_loff:	.space	2
.Lrows_c_roff:	.space	2

	.section .text.scr_piece_rows_asm
	.global	scr_piece_rows_asm

; xram_read(r24:r23:r22 + (r19:r18 as a 16-bit offset), Y + r20, r21 bytes)
.Lrows_rd:	clr	r25
	add	r22, r18
	adc	r23, r19
	adc	r24, r1
	adc	r25, r1
	mov	r18, r21                ; n
	clr	r19
	mov	r26, r20
	movw	r20, r28
	add	r20, r26
	adc	r21, r1
	jmp	xram_read

; pts[q]: x0 r23:r22, z0 r25:r24 (q in r24: 0 or 1)
.Lrows_pt:	movw	r30, r28
	lsl	r24
	lsl	r24
	adiw	r30, 1
	add	r30, r24
	adc	r31, r1
	ld	r22, Z+
	ld	r23, Z+
	ld	r24, Z+
	ld	r25, Z+
	ret

; v (r25:r24, int16) * 2 + d (r26, signed cubes) * 4096 -> r25:r24:r23:r22. Uses r20, r21, r27.
; (d << 12 is formed first: com sets the carry, so nothing of it may sit inside the add chain)
.Lrows_expand:	mov	r27, r26                ; d << 12: byte 1 r27, byte 2 r20, byte 3 r21 (byte 0 is 0)
	swap	r27
	andi	r27, 0xF0
	mov	r20, r26
	swap	r20
	andi	r20, 0x0F
	sbrc	r26, 7
	ori	r20, 0xF0
	clr	r21
	sbrc	r26, 7
	com	r21
	movw	r22, r24                ; v, sign-extended, * 2
	clr	r24
	sbrc	r23, 7
	com	r24
	mov	r25, r24
	lsl	r22
	rol	r23
	rol	r24
	rol	r25
	add	r23, r27
	adc	r24, r20
	adc	r25, r21
	ret

scr_piece_rows_asm:
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

	mov	r2, r22                 ; piece
	movw	r6, r20                 ; rows
	mov	r3, r18                 ; nr
	movw	r8, r16                 ; out
	call	scr_praw                ; (r25:r22 = piece, unchanged) -> the record
	movw	r30, r24
	ld	r10, Z                  ; cp
	ldd	r24, Z + 1              ; a0
	andi	r24, 0x0F
	lds	r30, scr_tab_ns
	lds	r31, scr_tab_ns + 1
	add	r30, r24
	adc	r31, r1
	lpm	r11, Z                  ; ns

.Lrows_row:	tst	r3
	brne	1f
	rjmp	.Lrows_done
1:	movw	r30, r6
	ld	r12, Z+                 ; .Lrows_row
	movw	r6, r30
	mov	r13, r2                 ; src = piece, srow = .Lrows_row, no offset
	mov	r14, r12
	clr	r15
	clr	r16
	cp	r12, r11                ; .Lrows_row == ns: the next piece's .Lrows_row 0
	brne	3f
	mov	r22, r2                 ; src = piece + 1 < NumTrackPieces ? piece + 1 : 0
	inc	r22
	lds	r24, NumTrackPieces
	lds	r25, NumTrackPieces + 1
	lds	r26, NumTrackPieces + 2
	lds	r27, NumTrackPieces + 3
	cp	r22, r24
	cpc	r1, r25
	cpc	r1, r26
	cpc	r1, r27
	brlt	2f
	clr	r22
2:	mov	r13, r22
	clr	r14
3:	mov	r22, r13                ; n = praw(src)
	clr	r23
	clr	r24
	clr	r25
	call	scr_praw
	movw	r30, r24
	ld	r24, Z                  ; cn
	ldd	r17, Z + 1              ; na
	ldd	r25, Z + 2
	andi	r25, 0x7F
	std	Y + 9, r25              ; lid
	ldd	r25, Z + 3
	andi	r25, 0x7F
	std	Y + 10, r25             ; rid
	ldd	r25, Z + 5              ; lsh (big-endian in the record)
	std	Y + 11, r25
	ldd	r25, Z + 4
	std	Y + 12, r25
	ldd	r25, Z + 7              ; rsh
	std	Y + 13, r25
	ldd	r25, Z + 6
	std	Y + 14, r25
	cp	r13, r2                 ; another piece: its cube offset from this one
	breq	4f
	mov	r25, r24
	andi	r25, 0x0F
	mov	r26, r10
	andi	r26, 0x0F
	sub	r25, r26
	mov	r15, r25                ; dcx
	mov	r25, r24
	swap	r25
	andi	r25, 0x0F
	mov	r26, r10
	swap	r26
	andi	r26, 0x0F
	sub	r25, r26
	mov	r16, r25                ; dcz
4:	; template points: j = 2 srow, reversed: 2 ns(na) - j; read 8 bytes at TMPL_XZ + 4 (xzoff[t] + j)
	mov	r24, r17
	andi	r24, 0x0F               ; t
	lds	r30, scr_tab_ns
	lds	r31, scr_tab_ns + 1
	add	r30, r24
	adc	r31, r1
	lpm	r25, Z                  ; ns(na)
	lds	r30, scr_tab_xzoff
	lds	r31, scr_tab_xzoff + 1
	add	r30, r24
	adc	r31, r1
	lpm	r26, Z                  ; xzoff[t]
	mov	r18, r14                ; j = 2 srow
	clr	r19
	lsl	r18
	rol	r19
	sbrs	r17, 4
	rjmp	5f
	mov	r20, r25                ; reversed: 2 ns - j
	clr	r21
	lsl	r20
	rol	r21
	sub	r20, r18
	sbc	r21, r19
	movw	r18, r20
5:	add	r18, r26                ; + xzoff, * 4 (bytes)
	adc	r19, r1
	lsl	r18
	rol	r19
	lsl	r18
	rol	r19
	ldi	r22, lo8(SCR_T_TMPL_XZ)
	ldi	r23, hi8(SCR_T_TMPL_XZ)
	ldi	r24, hlo8(SCR_T_TMPL_XZ)
	ldi	r20, 1
	ldi	r21, 8
	rcall	.Lrows_rd                      ; pts
	; profile offsets (cached per id): .Lrows_c_loff = PIECE_Y_OFF[lid], .Lrows_c_roff = PIECE_Y_OFF[rid]
	ldd	r24, Y + 9
	lds	r25, .Lrows_c_lid
	cp	r24, r25
	breq	6f
	sts	.Lrows_c_lid, r24
	mov	r18, r24
	clr	r19
	lsl	r18
	rol	r19
	ldi	r22, lo8(SCR_T_PIECE_Y_OFF)
	ldi	r23, hi8(SCR_T_PIECE_Y_OFF)
	ldi	r24, hlo8(SCR_T_PIECE_Y_OFF)
	ldi	r20, 15                 ; (via the frame: yl's slot)
	ldi	r21, 2
	rcall	.Lrows_rd
	ldd	r24, Y + 15
	ldd	r25, Y + 16
	sts	.Lrows_c_loff, r24
	sts	.Lrows_c_loff + 1, r25
6:	ldd	r24, Y + 10
	lds	r25, .Lrows_c_rid
	cp	r24, r25
	breq	7f
	sts	.Lrows_c_rid, r24
	mov	r18, r24
	clr	r19
	lsl	r18
	rol	r19
	ldi	r22, lo8(SCR_T_PIECE_Y_OFF)
	ldi	r23, hi8(SCR_T_PIECE_Y_OFF)
	ldi	r24, hlo8(SCR_T_PIECE_Y_OFF)
	ldi	r20, 15
	ldi	r21, 2
	rcall	.Lrows_rd
	ldd	r24, Y + 15
	ldd	r25, Y + 16
	sts	.Lrows_c_roff, r24
	sts	.Lrows_c_roff + 1, r25
7:	; yl = PIECE_Y[.Lrows_c_loff + srow], yr = PIECE_Y[.Lrows_c_roff + srow] (int16 each)
	lds	r18, .Lrows_c_loff
	lds	r19, .Lrows_c_loff + 1
	add	r18, r14
	adc	r19, r1
	lsl	r18
	rol	r19
	ldi	r22, lo8(SCR_T_PIECE_Y)
	ldi	r23, hi8(SCR_T_PIECE_Y)
	ldi	r24, hlo8(SCR_T_PIECE_Y)
	ldi	r20, 15
	ldi	r21, 2
	rcall	.Lrows_rd
	lds	r18, .Lrows_c_roff
	lds	r19, .Lrows_c_roff + 1
	add	r18, r14
	adc	r19, r1
	lsl	r18
	rol	r19
	ldi	r22, lo8(SCR_T_PIECE_Y)
	ldi	r23, hi8(SCR_T_PIECE_Y)
	ldi	r24, hlo8(SCR_T_PIECE_Y)
	ldi	r20, 17
	ldi	r21, 2
	rcall	.Lrows_rd

	; corners 0 (L) and 1 (R), with 2 (LB) and 3 (RB) below them: q = reversed ? 1 - c : c
	clr	r4                      ; c
.Lrows_corner:	mov	r24, r4
	sbrs	r17, 4
	rjmp	8f
	ldi	r24, 1
	sub	r24, r4
8:	rcall	.Lrows_pt                      ; x0 r23:r22, z0 r25:r24
	; rotate by na & 0xc0 -> x r21:r20, z r19:r18
	mov	r26, r17
	andi	r26, 0xC0
	brne	9f
	movw	r20, r22                ; 0x00: (x0, z0)
	movw	r18, r24
	rjmp	12f
9:	cpi	r26, 0x40
	brne	10f
	movw	r20, r24                ; 0x40: (z0, 0x800 - x0)
	ldi	r18, lo8(0x800)
	ldi	r19, hi8(0x800)
	sub	r18, r22
	sbc	r19, r23
	rjmp	12f
10:	cpi	r26, 0x80
	brne	11f
	ldi	r20, lo8(0x800)         ; 0x80: (0x800 - x0, 0x800 - z0)
	ldi	r21, hi8(0x800)
	sub	r20, r22
	sbc	r21, r23
	ldi	r18, lo8(0x800)
	ldi	r19, hi8(0x800)
	sub	r18, r24
	sbc	r19, r25
	rjmp	12f
11:	ldi	r20, lo8(0x800)         ; 0xc0: (0x800 - z0, x0)
	ldi	r21, hi8(0x800)
	sub	r20, r24
	sbc	r21, r25
	movw	r18, r22
12:	; o[c].x = o[c + 2].x = .Lrows_expand(x, dcx); z likewise; o[c + 2].y = 0
	push	r18
	push	r19
	movw	r24, r20
	mov	r26, r15
	rcall	.Lrows_expand                  ; X -> r25:r24:r23:r22
	movw	r30, r8                 ; Z = &o[c]
	mov	r26, r4
	ldi	r27, 12
	mul	r26, r27
	add	r30, r0
	adc	r31, r1
	clr	r1
	st	Z, r22                  ; o[c].x
	std	Z + 1, r23
	std	Z + 2, r24
	std	Z + 3, r25
	std	Z + 24, r22             ; o[c + 2].x
	std	Z + 25, r23
	std	Z + 26, r24
	std	Z + 27, r25
	std	Z + 28, r1              ; o[c + 2].y = 0
	std	Z + 29, r1
	std	Z + 30, r1
	std	Z + 31, r1
	pop	r25
	pop	r24
	push	r30
	push	r31
	mov	r26, r16
	rcall	.Lrows_expand                  ; Z value
	pop	r31
	pop	r30
	std	Z + 8, r22              ; o[c].z
	std	Z + 9, r23
	std	Z + 10, r24
	std	Z + 11, r25
	std	Z + 32, r22             ; o[c + 2].z
	std	Z + 33, r23
	std	Z + 34, r24
	std	Z + 35, r25
	; o[c].y = 2 * (y + shift): c 0: yl + lsh, c 1: yr + rsh (17 bits, then doubled)
	movw	r26, r28
	tst	r4
	breq	13f
	adiw	r26, 2                  ; (c 1: rsh at 13, yr at 17 - 2 bytes on from lsh, yl)
13:	adiw	r26, 11                 ; X = &lsh (or &rsh)
	ld	r22, X+
	ld	r23, X+
	adiw	r26, 2                  ; X = &yl (or &yr): lsh 11 -> yl 15
	ld	r24, X+
	ld	r25, X+
	clr	r20                     ; sign bytes
	sbrc	r23, 7
	com	r20
	clr	r21
	sbrc	r25, 7
	com	r21
	add	r22, r24
	adc	r23, r25
	adc	r20, r21                ; r20 = bits 16..23 (and the sign above)
	clr	r21
	sbrc	r20, 7
	com	r21
	lsl	r22
	rol	r23
	rol	r20
	rol	r21
	std	Z + 4, r22
	std	Z + 5, r23
	std	Z + 6, r20
	std	Z + 7, r21
	inc	r4
	mov	r24, r4
	cpi	r24, 2
	breq	14f
	rjmp	.Lrows_corner
14:	; the drawbridge (C): scr_bridge_fix(piece, .Lrows_row, o)
	mov	r22, r2
	clr	r23
	clr	r24
	clr	r25
	mov	r18, r12
	clr	r19
	clr	r20
	clr	r21
	movw	r16, r8
	call	scr_bridge_fix
	ldi	r24, 48                 ; next .Lrows_row
	add	r8, r24
	adc	r9, r1
	dec	r3
	rjmp	.Lrows_row

.Lrows_done:	adiw	r28, FRAME
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
