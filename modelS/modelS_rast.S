/*
 * Model S rasterizer - turns Model S edge lists into run-length rows for Uzebox video mode 19
 * (clean-room, ATmega644). Model S: named in tribute to Sega's Model 1 / Model 2 arcade
 * hardware (Virtua Racing...); this is its scanline back end, modelS_render.cpp the front end.
 *
 * void rast_row(uint8_t row)
 *   (SPI RAM variant: see below)
 *      the active list, kept sorted by integer x (inserted after equal x).
 *   2. sweep: walk the active list; each edge toggles its 1 or 2 region ids on a small
 *      sorted stack (top = frontmost region). After each group of equal-x edges the
 *      colour (colours[top], or background 0) is compared with the current colour and,
 *      if it changed and x > pos, a run is emitted. Each edge's x is stepped by dX; an
 *      edge ending on this row is unlinked and its slot returned to the free list (the
 *      next display frame reads the stream again).
 *   3. the last run (to x=256), the end-of-line pair (1,0xFE) (padded if odd).
 *   4. re-sort: insertion pass restoring x order after stepping.
 *
 * Edge slot (9 bytes, slot 0 = null): link, y0, y1, Xlo, Xhi, dXlo, dXhi, idA, idB(0xFF=none)
 * RLE output: ring[256] (256-aligned), write index ring_w. Blocks while the ring is full
 * (r5 = the video interrupt's committed read index; r5 is never used here). Same format as the demo,
 * except a 255 px run is coded 128 + 127.
 *
 * Registers inside rast_row:
 *   r24 row          r25 current colour   r23 pos          r20 const 9
 *   r16 x of group   r17/r11 edge index   r13 stack depth  r12 const 1 (ring-full check)
 *   r15 const 0      r2:r3 prev link ptr  X ring pointer   Y scratch ptr   Z node ptr
 */
#include <avr/io.h>

	.extern pool
	.extern rowmask
	.extern rs_ptr

	.section .bss
rs_rd:	.skip	3                       ; the next record to read (rast_row)
rb_busy: .skip	1                       ; emitb: short-run pixels so far in the row
rb_gl:	.skip	1                       ;        the open block: length, colour, its longest run
rb_gc:	.skip	1
rb_gbest: .skip	1
	.text
	.extern free_head
	.extern rast_overflow
	.extern colours
	.extern istack
	.extern act_head
#ifdef RAST_TO_BUF
	; whole pictures are rasterized once, in the main program, row by row into rast_buf
	; (256-aligned; the caller stores each row away and resets rast_buf_w); no ring waits
#define ring   rast_buf
#define ring_w rast_buf_w
	.extern spi_lock
	.extern spi_unlock
	.extern bg_pending
#endif
	.extern ring
	.extern ring_w

#define NINE r20
#define ZERO r15

	.macro NODEPTR idx              ; Z = pool + 9*idx   (5 cycles)
	mul	\idx, NINE
	movw	r30, r0
	subi	r30, lo8(-(pool))
	sbci	r31, hi8(-(pool))
	.endm

#ifdef RAST_TO_BUF
	.macro ROOM2                    ; (no consumer while a picture is rasterized)
	.endm
	.macro ROOM2_UNUSED
#else
	.macro ROOM2                    ; wait until the ring has room for one more pair:
#endif
91:	mov	r22, r5                 ; r5 = consumer's committed read index (video ISR)
	subi	r22, 2                  ; full when read == write + 2 (indices are even here)
	cp	r22, r26
	breq	91b
	.endm

	.macro SPIGET off               ; one SPI byte into Y+off (~20 cycles, no call)
	out	_SFR_IO_ADDR(SPDR), ZERO
91:	in	r19, _SFR_IO_ADDR(SPSR)
	sbrs	r19, SPIF
	rjmp	91b
	in	r21, _SFR_IO_ADDR(SPDR)
	std	Y+\off, r21
	.endm

#ifdef RAST_TO_BUF
	.macro UNLOCK                   ; release the bus; run the copy task now if it waited (else it
	sts	spi_lock, ZERO          ; would wait for the next line, and find the bus taken again)
	lds	r19, bg_pending
	tst	r19
	breq	99f
	rcall	run_pending
99:
	.endm
#endif

	.macro PUT reg                  ; append to ring (X), stay inside its page
	st	X+, \reg
	ldi	r27, hi8(ring)
	.endm

	.macro TOG                      ; toggle region r18: fast paths inline, top kept in r10
	tst	r13
	breq	1f                      ; empty: push
	cp	r18, r10
	breq	2f                      ; == top: pop
	brsh	1f                      ; above top: push
	rcall	toggle                  ; below top: general case, top unchanged
	rjmp	3f
1:	ldi	r28, lo8(istack)
	ldi	r29, hi8(istack)
	add	r28, r13
	adc	r29, ZERO
	st	Y, r18
	inc	r13
	mov	r10, r18
	rjmp	3f
2:	dec	r13
	breq	3f
	ldi	r28, lo8(istack - 1)
	ldi	r29, hi8(istack - 1)
	add	r28, r13
	adc	r29, ZERO
	ld	r10, Y
3:
	.endm

	.section .text
spix:	out	_SFR_IO_ADDR(SPDR), r18  ; send r18, return the received byte in r18
1:	in	r18, _SFR_IO_ADDR(SPSR)
	sbrs	r18, SPIF
	rjmp	1b
	in	r18, _SFR_IO_ADDR(SPDR)
	ret

	.global rast_empty
rast_empty:                             ; call-overhead calibration
	ret

	.global rast_row
rast_row:
	.global act_begin
act_begin:
	push	r2
	push	r4
	push	r6
	push	r7
	push	r8
	push	r10
	push	r9
	push	r3
	push	r11
	push	r12
	push	r13
	push	r14
	push	r15
	push	r16
	push	r17
	push	r28
	push	r29
	ldi	NINE, 9
	clr	ZERO

;---------------------------------------------------------------- 1. activation
	mov	r18, r24                ; rowmask bit `row`?
	lsr	r18
	lsr	r18
	lsr	r18
	ldi	r30, lo8(rowmask)
	ldi	r31, hi8(rowmask)
	add	r30, r18
	adc	r31, ZERO
	ld	r19, Z
	mov	r18, r24
	andi	r18, 7
	breq	2f
1:	lsr	r19
	dec	r18
	brne	1b
2:	sbrs	r19, 0
	rjmp	act_done
	; the row's new edges: the count, then each record in a transaction of its own, the bus free
	; while it is sorted in (holding it through the whole row starved the video copy task:
	; black lines on busy rows)
#ifdef RAST_TO_BUF
	ldi	r18, 1                  ; main program: hold the SPI bus against the copy task
	sts	spi_lock, r18
#endif
	cbi	_SFR_IO_ADDR(PORTA), 4  ; SPI RAM: READ at rs_ptr
	ldi	r18, 3
	rcall	spix
#ifndef SCR_SPIRAM_64K
	lds	r18, rs_ptr + 2                 ; (64 KB chips take 16-bit addresses)
	rcall	spix
#endif
	lds	r18, rs_ptr + 1
	rcall	spix
	lds	r18, rs_ptr
	rcall	spix
	rcall	spix                    ; count
	mov	r9, r18
	sbi	_SFR_IO_ADDR(PORTA), 4
#ifdef RAST_TO_BUF
	UNLOCK
#endif
	ldi	r19, 7                  ; rs_rd = rs_ptr + 1, rs_ptr += 1 + 7 * count
	mul	r9, r19
	lds	r18, rs_ptr
	lds	r19, rs_ptr + 1
	lds	r21, rs_ptr + 2
	subi	r18, 0xFF               ; + 1
	sbci	r19, 0xFF
	sbci	r21, 0xFF
	sts	rs_rd, r18
	sts	rs_rd + 1, r19
	sts	rs_rd + 2, r21
	add	r18, r0
	adc	r19, r1
	adc	r21, ZERO
	sts	rs_ptr, r18
	sts	rs_ptr + 1, r19
	sts	rs_ptr + 2, r21
	ldi	r26, lo8(act_head)      ; X = &prev.link for the merge
	ldi	r27, hi8(act_head)
	.global act_loop
act_loop:
	tst	r9
	brne	3f
	rjmp	act_end
3:	dec	r9
	lds	r18, free_head          ; take a slot (0 = none left: read into slot 0, drop it)
	mul	r18, NINE
	movw	r28, r0
	subi	r28, lo8(-(pool))
	sbci	r29, hi8(-(pool))
	tst	r18
	breq	5f
	ld	r14, Y
	sts	free_head, r14
5:	std	Y+1, r24                ; y0 = row
	push	r18
#ifdef RAST_TO_BUF
	ldi	r18, 1
	sts	spi_lock, r18
#endif
	cbi	_SFR_IO_ADDR(PORTA), 4  ; READ the record at rs_rd
	ldi	r18, 3
	rcall	spix
#ifndef SCR_SPIRAM_64K
	lds	r18, rs_rd + 2
	rcall	spix
#endif
	lds	r18, rs_rd + 1
	rcall	spix
	lds	r18, rs_rd
	rcall	spix
	SPIGET	2                       ; the 7 record bytes, straight into the slot
	SPIGET	3
	SPIGET	4
	SPIGET	5
	SPIGET	6
	SPIGET	7
	SPIGET	8
	sbi	_SFR_IO_ADDR(PORTA), 4
#ifdef RAST_TO_BUF
	UNLOCK
#endif
	lds	r18, rs_rd              ; rs_rd += 7
	lds	r19, rs_rd + 1
	lds	r21, rs_rd + 2
	subi	r18, 0xF9
	sbci	r19, 0xFF
	sbci	r21, 0xFF
	sts	rs_rd, r18
	sts	rs_rd + 1, r19
	sts	rs_rd + 2, r21
	pop	r18
	tst	r18
	brne	7f
	lds	r19, rast_overflow
	inc	r19
	sts	rast_overflow, r19
	rjmp	act_loop
7:	ldd	r16, Y+4                ; new x
1:	ld	r17, X                  ; X = &prev.link, continues from the last insert
	tst	r17
	breq	2f
	NODEPTR	r17
	ldd	r19, Z+4
	cp	r16, r19
	brlo	2f                      ; new.x < node.x: insert before node
	movw	r26, r30
	rjmp	1b
2:	st	Y, r17
	st	X, r18
	movw	r26, r28                ; next new edge goes after this one
	rjmp	act_loop
act_end:
	.global act_done
act_done:

;---------------------------------------------------------------- 2. sweep
	sts	rb_busy, ZERO           ; the row's short-run budget (emitb)
	sts	rb_gl, ZERO
	sts	rb_gbest, ZERO
	lds	r26, ring_w
	ldi	r27, hi8(ring)
	clr	r25                     ; colour = background
	clr	r23                     ; pos = 0
	clr	r13                     ; stack empty
	ldi	r21, 0xFF
	mov	r4, r21                 ; last evaluated top = none
	clr	r6                      ; previous stepped x
	clr	r7                      ; unsorted flag
	ldi	r21, 1
	mov	r12, r21
	ldi	r21, lo8(act_head)
	mov	r2, r21
	ldi	r21, hi8(act_head)
	mov	r3, r21
	lds	r17, act_head
	tst	r17
	brne	3f
	rjmp	sweep_done
3:	mov	r11, r17
	NODEPTR	r17
	.global node
node:
	ldd	r16, Z+4                ; x
	ldd	r18, Z+7
	TOG
	ldd	r18, Z+8
	cpi	r18, 0xFF
	breq	4f
	TOG
4:	ldd	r18, Z+3                ; X += dX
	ldd	r19, Z+4
	ldd	r14, Z+5
	ldd	r21, Z+6
	add	r18, r14
	adc	r19, r21
	std	Z+3, r18
	std	Z+4, r19
	ld	r17, Z                  ; next index
	ldd	r18, Z+2                ; y1
	cp	r18, r24
	brne	keep
	; ---- retire: unlink, return the slot to the free list
	movw	r28, r2
	st	Y, r17
	lds	r21, free_head
	st	Z, r21
	sts	free_head, r11
	rjmp	group
	.global keep
keep:
	movw	r2, r30                 ; prev = this node's link
	cp	r19, r6                 ; still sorted after stepping?
	brsh	1f
	inc	r7
1:	mov	r6, r19
	.global group
group:
	tst	r17
	breq	last
	mov	r11, r17
	NODEPTR	r17
	ldd	r19, Z+4
	cp	r19, r16
	breq	9f                      ; same x: keep toggling before evaluating colour
	rcall	eval
9:	rjmp	node
last:
	rcall	eval
	.global sweep_done
sweep_done:
	mov	r19, r23                ; final run: 256 - pos
	neg	r19
	brne	1f
	ldi	r19, 128                ; pos 0: one colour across the whole line = 128 + 128
	rcall	emitb
	ldi	r19, 128
1:	rcall	emitb
	rcall	eflush                  ; a block still open
	sbrs	r26, 0
	rjmp	5f
	ldi	r21, 1                  ; pad odd stream with a background single pixel
	PUT	r21
5:	ROOM2
	ldi	r21, 1                  ; end of line (colour 1 shows as black: DDRC bit 0 is off)
	PUT	r21
	ldi	r21, 0xFE
	PUT	r21
	sts	ring_w, r26

;---------------------------------------------------------------- 4. re-sort
	ldi	r26, lo8(act_head)
	ldi	r27, hi8(act_head)
	clr	r16                     ; previous x
	.global rs_next
rs_next:
	ld	r17, X
	tst	r17
	breq	rs_done
	NODEPTR	r17
	ldd	r19, Z+4
	cp	r19, r16
	brlo	rs_move
	mov	r16, r19
	movw	r26, r30
	rjmp	rs_next
	.global rs_move
rs_move:                                ; unlink and reinsert from the head
	ld	r18, Z
	st	X, r18
	ldi	r28, lo8(act_head)
	ldi	r29, hi8(act_head)
6:	ld	r18, Y
	tst	r18
	breq	8f
	movw	r2, r28
	mul	r18, NINE
	movw	r28, r0
	subi	r28, lo8(-(pool))
	sbci	r29, hi8(-(pool))
	ldd	r21, Y+4
	cp	r19, r21
	brsh	6b
	movw	r28, r2
8:	ld	r18, Y
	st	Z, r18
	st	Y, r17
	rjmp	rs_next
	.global rs_done
rs_done:

	clr	r1
	pop	r29
	pop	r28
	pop	r17
	pop	r16
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	pop	r11
	pop	r3
	pop	r9
	pop	r10
	pop	r8
	pop	r7
	pop	r6
	pop	r4
	pop	r2
	ret

;---------------------------------------------------------------- helpers
; toggle region id r18 on the sorted stack istack[0..r13-1]. Uses Y, r19, r21, r22.
	.global toggle
toggle:
	ldi	r28, lo8(istack)
	ldi	r29, hi8(istack)
	mov	r19, r13
1:	subi	r19, 1
	brcs	t_append
	ld	r21, Y+
	cp	r21, r18
	breq	t_remove
	brlo	1b
	sbiw	r28, 1                  ; insert before this element (carry-shift up)
	mov	r22, r18
2:	ld	r21, Y
	st	Y+, r22
	mov	r22, r21
	subi	r19, 1
	brcc	2b
	st	Y, r22
	inc	r13
	ret
t_append:
	st	Y, r18
	inc	r13
	ret
t_remove:                               ; shift the r19 following elements down
3:	tst	r19
	breq	4f
	ld	r21, Y
	sbiw	r28, 1
	st	Y, r21
	adiw	r28, 2
	dec	r19
	rjmp	3b
4:	dec	r13
	ret

; colour change check at x = r16. Uses Y, r18, r19, r21.
	.global eval
eval:
	ldi	r18, 0xFF               ; key = top region, 0xFF if none
	tst	r13
	breq	1f
	mov	r18, r10
1:	cp	r18, r4
	breq	9f                      ; top unchanged since last check: colour unchanged
	mov	r4, r18
	cpi	r18, 0xFF
	brne	2f
	clr	r18                     ; background
	rjmp	3f
2:	ldi	r28, lo8(colours)
	ldi	r29, hi8(colours)
	add	r28, r18
	adc	r29, ZERO
	ld	r18, Y
3:	cp	r18, r25
	breq	9f
	cp	r23, r16
	brsh	4f
	mov	r19, r16
	sub	r19, r23
	rcall	emitb
	mov	r23, r16
4:	mov	r25, r18
9:	ret

#ifdef RAST_TO_BUF
; spi_unlock() (C: runs the waiting copy task) with every register it may change kept
run_pending:
	push	r0
	push	r1
	push	r18
	push	r19
	push	r20
	push	r21
	push	r22
	push	r23
	push	r24
	push	r25
	push	r26
	push	r27
	push	r30
	push	r31
	clr	r1
	call	spi_unlock
	pop	r31
	pop	r30
	pop	r27
	pop	r26
	pop	r25
	pop	r24
	pop	r23
	pop	r22
	pop	r21
	pop	r20
	pop	r19
	pop	r18
	pop	r1
	pop	r0
	ret
#endif

; emit with the row's short-run budget. Video mode 19 draws runs shorter than LONG_RUN pixels
; (and single pixels) inside its interrupt, 5 cycles per pixel; a row with too many of them
; (zebra-striped walls far away) leaves the copy task that feeds the mode too little time: the
; mode runs dry and shows black lines. Within scr_short_budget short-run pixels a row is as it is;
; beyond, short runs are gathered into blocks of at least LONG_RUN pixels, each the colour of its
; longest run. r25 colour, r19 length (0 = nothing). Uses r19, r21, X (as emit).
	.extern scr_short_budget        ; (short-run pixels per row kept as they are: the game adapts it)
#define LONG_RUN 28
emitb:
	tst	r19
	breq	9f
	cpi	r19, LONG_RUN
	brsh	5f                      ; long: flush a block, then the run
	lds	r21, rb_gl
	tst	r21
	brne	2f                      ; a block is open: into it
	lds	r21, rb_busy
	add	r21, r19
	brcs	2f                      ; over the budget: start a block
	push	r19
	lds	r19, scr_short_budget
	cp	r19, r21
	pop	r19
	brlo	2f
	sts	rb_busy, r21
	rjmp	emit                    ; within the budget: as it is
2:	lds	r21, rb_gbest           ; into the block; its colour: its longest run's
	cp	r21, r19
	brsh	3f
	sts	rb_gbest, r19
	sts	rb_gc, r25
3:	lds	r21, rb_gl
	add	r21, r19
	sts	rb_gl, r21
	cpi	r21, LONG_RUN
	brlo	9f
eflush:	lds	r19, rb_gl              ; the open block (r25 kept)
	tst	r19
	breq	9f
	push	r25
	lds	r25, rb_gc
	sts	rb_gl, ZERO
	sts	rb_gbest, ZERO
	rcall	emit
	pop	r25
9:	ret
5:	push	r19
	rcall	eflush
	pop	r19
	rjmp	emit

; emit a run of colour r25, length r19 (mod 256; 0 = nothing). Uses r19, r21, X.
	.global emit
emit:
	tst	r19
	breq	9f
	sbrs	r26, 0
	rjmp	1f
	mov	r21, r25                ; finish an open pair with a single pixel
	ori	r21, 1
	PUT	r21
	dec	r19
	breq	9f
1:	ROOM2
	PUT	r25
	cpi	r19, 3
	brsh	2f
	cpi	r19, 2
	brne	9f
	mov	r21, r25
	ori	r21, 1
	PUT	r21
9:	ret
2:	cpi	r19, 0x81
	brsh	3f
	subi	r19, 2
	lsl	r19
	PUT	r19
	ret
3:	ldi	r21, 0xF8               ; 126 + rest (rest coded (n-128)*2)
	cpi	r19, 0xFF
	brne	4f
	ldi	r21, 0xFC               ; 255 = 128 + 127 (avoid 0xFE)
4:	PUT	r21
7:	ROOM2
	PUT	r25
	cpi	r21, 0xFC
	brne	5f
	ldi	r19, (127 - 2) * 2
	PUT	r19
	ret
5:	subi	r19, 0x80
	lsl	r19
	PUT	r19
	ret
