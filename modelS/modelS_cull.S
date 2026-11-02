; Back-face culling of a track piece's walls (modelS_render.cpp, draw_rows), bit-identical to the
; C wall_back there.
;
;   uint8_t scr_wall_back(const scr_vtx *p, const scr_vtx *q, uint8_t nr)
;
; p, q: &V[0][t], &V[0][b] in the projected corners V[nr][4] (scr_vtx: 11 bytes - sx, sy, cx, cy,
; cz, fl - a row 44): the left wall's columns 0, 2; the right wall's 3, 1 (swapping the two
; negates the cross product, so one test serves both). Returns 1 when every segment k (corners
; p0 = V[k][t], p1 = V[k+1][t], q0 = V[k][b], q1 = V[k+1][b]) faces away from the camera: the
; cross product of its diagonals on screen, (q1 - p0) x (q0 - p1) = A - B, positive. 0 as soon
; as one faces the camera, is edge on, or has a corner clipped or off screen (fl).
;
; Never touches r5 (video mode 19's: -ffixed-r5). Uses r0, r1 (cleared), r18-r27, Y (saved), Z.
#include <avr/io.h>

#define ROW 44                          /* 4 corners of 11 bytes */

	.section .text.scr_wall_back
	.global	scr_wall_back
scr_wall_back:
	push	r28
	push	r29
	movw	r30, r24                ; Z = p
	movw	r28, r22                ; Y = q
	mov	r21, r20                ; nr - 1 segments
	dec	r21
	breq	8f
1:	ldd	r18, Z+10               ; a corner clipped or off screen: keep
	ldd	r19, Z+ROW+10
	or	r18, r19
	ldd	r19, Y+10
	or	r18, r19
	ldd	r19, Y+ROW+10
	or	r18, r19
	brne	9f
	ldd	r18, Y+ROW              ; A = (q1.sx - p0.sx) * (q0.sy - p1.sy)
	ldd	r19, Y+ROW+1
	ld	r24, Z
	ldd	r25, Z+1
	sub	r18, r24
	sbc	r19, r25
	ldd	r26, Y+2
	ldd	r27, Y+3
	ldd	r24, Z+ROW+2
	ldd	r25, Z+ROW+3
	sub	r26, r24
	sbc	r27, r25
	call	__mulhisi3              ; (libgcc: r25:r22 = r19:r18 * r27:r26, signed; uses r0, r1)
	push	r22
	push	r23
	push	r24
	push	r25
	ldd	r18, Y+ROW+2            ; B = (q1.sy - p0.sy) * (q0.sx - p1.sx)
	ldd	r19, Y+ROW+3
	ldd	r24, Z+2
	ldd	r25, Z+3
	sub	r18, r24
	sbc	r19, r25
	ld	r26, Y
	ldd	r27, Y+1
	ldd	r24, Z+ROW
	ldd	r25, Z+ROW+1
	sub	r26, r24
	sbc	r27, r25
	call	__mulhisi3
	pop	r27                     ; A
	pop	r26
	pop	r19
	pop	r18
	sub	r18, r22                ; A - B: facing away only when positive
	sbc	r19, r23
	sbc	r26, r24
	sbc	r27, r25
	breq	9f
	brlt	9f
	adiw	r30, ROW                ; the next segment
	adiw	r28, ROW
	dec	r21
	brne	1b
8:	ldi	r24, 1
	rjmp	0f
9:	ldi	r24, 0
0:	pop	r29
	pop	r28
	ret
