; The copy task: void bg_task(void) - called from video mode 19's line interrupt (or from
; spi_unlock) with interrupts enabled. Copies the rows of the picture being shown from SPI RAM
; into the mode's 256-byte ring, one complete row at a time, while there is room. At row 0 it
; switches to a newly published picture and publishes where row 0 starts in the ring (the mode
; resyncs there at each frame start). Rows lie one after another in SPI RAM: within one run of
; the task the read stays open across rows. Each byte's transfer starts as soon as the previous
; one is read, the store done while it runs (~18 cycles per byte).
;
; Never touches r5 (the mode's read index in the ring: -ffixed-r5). The ring is 256-aligned: its
; index is the pointer's low byte. Uses only call-clobbered registers; r1 stays 0.
; Registers: r20 the read is open, r21 room in the ring, r22 bytes left, r23 the row's length,
; r19 0xFF, X the ring.
#include <avr/io.h>

#define NROWS 110
#ifdef SCR_SPIRAM_64K
#define PIC_HI 0x00                     /* pictures at 0x08000 / 0x0C000 */
#else
#define PIC_HI 0x01                     /* pictures at 0x18000 / 0x1C000 */
#endif

	.extern	ring, ring_w, front, pending, cp_row, cp_ptr, err_colour
	.extern	frame_start_w, frame_start_valid, rast_abort, m19_video_on

	.section .text.bg_task
	.global	bg_task
	.section .text.bg_task
bg_task:
	clr	r20                     ; (the read is not open)
.Lloop:
	lds	r24, err_colour
	tst	r24
	breq	0f
	rjmp	.Lerr
0:	lds	r25, rast_abort         ; the mode is resyncing: start again at row 0
	tst	r25
	breq	1f
	sts	rast_abort, r1
	sts	cp_row, r1
1:	lds	r25, cp_row
	tst	r25
	brne	.Lrow
	tst	r20                     ; row 0: (a new picture: another address)
	breq	2f
	sbi	_SFR_IO_ADDR(PORTA), PA4
	clr	r20
2:	lds	r24, pending
	sts	front, r24
	sts	cp_ptr, r1              ; cp_ptr = pic_base[front]
	ldi	r25, 0x80
	sbrc	r24, 0
	ldi	r25, 0xC0
	sts	cp_ptr + 1, r25
	ldi	r25, PIC_HI
	sts	cp_ptr + 2, r25
	lds	r24, ring_w
	sts	frame_start_w, r24
	ldi	r24, 1
	sts	frame_start_valid, r24
.Lrow:
	lds	r26, ring_w             ; room = 254 - (ring_w - r5)
	mov	r21, r5
	sub	r21, r26
	subi	r21, 2
	tst	r20
	brne	3f
	cbi	_SFR_IO_ADDR(PORTA), PA4 ; open the read at cp_ptr
	ldi	r24, 3
	rcall	.Lspx
#ifndef SCR_SPIRAM_64K
	lds	r24, cp_ptr + 2         ; (64 KB chips take 16-bit addresses)
	rcall	.Lspx
#endif
	lds	r24, cp_ptr + 1
	rcall	.Lspx
	lds	r24, cp_ptr
	rcall	.Lspx
	ldi	r20, 1
3:	ldi	r24, 0xFF               ; the row's length
	rcall	.Lspx
	cp	r21, r24
	brsh	4f
	sbi	_SFR_IO_ADDR(PORTA), PA4 ; not enough room yet (re-read next time)
	ret
4:	mov	r23, r24
	mov	r22, r24
	ldi	r27, hi8(ring)          ; X = &ring[ring_w]
	ldi	r19, 0xFF
	tst	r22
	breq	7f
	out	_SFR_IO_ADDR(SPDR), r19
5:	dec	r22
	breq	6f
91:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	91b
	in	r0, _SFR_IO_ADDR(SPDR)
	out	_SFR_IO_ADDR(SPDR), r19 ; the next byte, while this one is stored
	st	X, r0
	inc	r26                     ; (wraps inside the ring's page)
	rjmp	5b
6:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	6b
	in	r0, _SFR_IO_ADDR(SPDR)
	st	X, r0
	inc	r26
7:	sts	ring_w, r26             ; publish the complete row
	lds	r24, cp_ptr             ; cp_ptr += 1 + n
	lds	r25, cp_ptr + 1
	lds	r22, cp_ptr + 2
	sec
	adc	r24, r23
	adc	r25, r1
	adc	r22, r1
	sts	cp_ptr, r24
	sts	cp_ptr + 1, r25
	sts	cp_ptr + 2, r22
	rcall	.Lnext
	rjmp	.Lloop

.Lerr:	tst	r20                     ; boot failure: a solid screen of err_colour (no SPI RAM)
	breq	1f
	sbi	_SFR_IO_ADDR(PORTA), PA4
	clr	r20
1:	lds	r26, ring_w
	mov	r25, r26
	sub	r25, r5
	cpi	r25, 254 - 6 + 1
	brlo	2f
	ret
2:	ldi	r27, hi8(ring)
	ldi	r25, 126 << 1           ; 128 + 128 pixels, end of line
	st	X, r24
	inc	r26
	st	X, r25
	inc	r26
	st	X, r24
	inc	r26
	st	X, r25
	inc	r26
	ldi	r25, 1
	st	X, r25
	inc	r26
	ldi	r25, 0xFE
	st	X, r25
	inc	r26
	lds	r25, cp_row
	tst	r25
	brne	3f
	lds	r25, ring_w
	sts	frame_start_w, r25
	ldi	r25, 1
	sts	frame_start_valid, r25
3:	sts	ring_w, r26
	rcall	.Lnext
	rjmp	.Lloop

.Lnext:	ldi	r24, 1                  ; rows are coming; cp_row++, wrapping at NROWS
	sts	m19_video_on, r24
	lds	r24, cp_row
	inc	r24
	cpi	r24, NROWS
	brne	1f
	clr	r24
#ifdef DEBUG_STATS
	lds	r25, frames_rastered
	subi	r25, 0xFF
	sts	frames_rastered, r25
	lds	r25, frames_rastered + 1
	sbci	r25, 0xFF
	sts	frames_rastered + 1, r25
#endif
1:	sts	cp_row, r24
	ret

.Lspx:	out	_SFR_IO_ADDR(SPDR), r24 ; send r24, receive into r24
1:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	1b
	in	r24, _SFR_IO_ADDR(SPDR)
	ret
