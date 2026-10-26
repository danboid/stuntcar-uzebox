; The copy task's inner loop (bg_task in scr_game.c): n bytes of the open SPI RAM read into the
; video mode's ring from index w; returns the new index.
;
;   uint8_t scr_copy_row(uint8_t w, uint8_t n)
;
; Each byte's transfer starts as soon as the previous one is read, the store and the count done
; while it runs: the loop goes at the bus's pace (~18 cycles per byte, the C loop ~33). The ring
; is 256-aligned: its index wraps with the pointer's low byte. Never touches r5
; (-ffixed-r5: the video interrupt's); internal labels are local (.L).
; Args (avr-gcc): w r24, n r22. Uses r0, r19, r23, X.
#include <avr/io.h>

	.extern	ring

	.section .text.scr_copy_row
	.global	scr_copy_row
scr_copy_row:
	tst	r22
	breq	.Lret
	ldi	r27, hi8(ring)          ; X = &ring[w]
	ldi	r26, lo8(ring)
	add	r26, r24
	ldi	r23, 0xFF
	out	_SFR_IO_ADDR(SPDR), r23 ; the first byte
.Lloop:	dec	r22
	breq	.Llast
1:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	1b
	in	r19, _SFR_IO_ADDR(SPDR)
	out	_SFR_IO_ADDR(SPDR), r23 ; the next byte, while this one is stored
	st	X, r19
	inc	r26                     ; (wraps inside the ring's page)
	rjmp	.Lloop
.Llast:
2:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	2b
	in	r19, _SFR_IO_ADDR(SPDR)
	st	X, r19
	inc	r26
	mov	r24, r26                ; the new index (ring's low byte is 0)
.Lret:	ret
