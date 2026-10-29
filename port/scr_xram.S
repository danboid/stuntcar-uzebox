; Fast SPI RAM access for the game build (23LC1024, chip select PA4, sequential mode).
;   void xram_read(uint32_t addr, void *dst, uint16_t n)
;   void xram_write(uint32_t addr, const void *src, uint16_t n)
; Hold spi_lock for the transaction (the background copy task also uses the SPI bus) and
; release it through spi_unlock() (which runs the task if it waited). Polled transfers
; (~20 cycles per byte): SPIF is read before SPDR, as the hardware requires to clear it.
#include <avr/io.h>
	.extern spi_lock
	.extern spi_unlock

	.macro	SPIX reg                ; send \reg, receive into \reg
	out	_SFR_IO_ADDR(SPDR), \reg
91:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	91b
	in	\reg, _SFR_IO_ADDR(SPDR)
	.endm

	.section .text.xram_begin
xram_start:                             ; r26 = command, r22..r24 = address
	ldi	r27, 1
	sts	spi_lock, r27
	ldi	r27, (1 << SPE) | (1 << MSTR)
	out	_SFR_IO_ADDR(SPCR), r27
	ldi	r27, (1 << SPI2X)
	out	_SFR_IO_ADDR(SPSR), r27
	cbi	_SFR_IO_ADDR(PORTA), PA4
	SPIX	r26
#ifndef SCR_SPIRAM_64K
	SPIX	r24                     ; (64 KB chips take 16-bit addresses)
#endif
	SPIX	r23
	SPIX	r22
	movw	r30, r20                ; Z = buffer
	ret

; Transfers of up to 32 bytes (nearly all of them: ~7 bytes on average) in one transaction,
; without the long path's bookkeeping. Longer ones go in chunks of 32, each its own transaction,
; with spi_unlock() in between: the copy task (which feeds the video mode) never waits long for
; the bus. The byte loops overlap: the next byte's transfer starts as soon as the last one is in,
; the store (or the next load) done while it runs.
#define CHUNK 32
	.section .text.xram_read
	.global	xram_read
	.global	xram_write
xram_read:
	ldi	r26, 3
	rjmp	1f
xram_write:
	ldi	r26, 2
1:	cpi	r18, CHUNK + 1
	cpc	r19, r1
	brsh	10f                     ; long: in chunks
	tst	r18
	breq	8f
	mov	r19, r26                ; direction (bit 0: read)
	rcall	xram_start              ; (Z = buffer)
	mov	r27, r18
	rcall	xfer
	sbi	_SFR_IO_ADDR(PORTA), PA4
	jmp	spi_unlock              ; (runs the copy task if it waited)
8:	ret

; r27 bytes (1 .. 255) at Z, direction r19 bit 0 (1: read); the transaction open. Uses r0, r26.
xfer:	sbrs	r19, 0
	rjmp	5f
	ldi	r26, 0xFF               ; read
	out	_SFR_IO_ADDR(SPDR), r26
3:	dec	r27
	breq	4f
91:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	91b
	in	r0, _SFR_IO_ADDR(SPDR)
	out	_SFR_IO_ADDR(SPDR), r26 ; the next byte, while this one is stored
	st	Z+, r0
	rjmp	3b
4:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	4b
	in	r0, _SFR_IO_ADDR(SPDR)
	st	Z+, r0
	ret
5:	ld	r26, Z+                 ; write
	out	_SFR_IO_ADDR(SPDR), r26
6:	dec	r27
	breq	7f
	ld	r26, Z+                 ; the next byte, while this one is sent
92:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	92b
	out	_SFR_IO_ADDR(SPDR), r26 ; (SPSR read with SPIF set, then SPDR: SPIF cleared)
	rjmp	6b
7:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	7b
	in	r0, _SFR_IO_ADDR(SPDR)
	ret

10:	push	r11
	push	r12
	push	r13
	push	r14
	push	r15
	push	r16
	push	r17
	push	r28
	push	r29
	mov	r11, r26                ; command
	movw	r12, r22                ; address
	movw	r14, r24
	movw	r28, r20                ; buffer
	movw	r16, r18                ; bytes left
2:	cp	r16, r1
	cpc	r17, r1
	breq	9f
	mov	r26, r11
	movw	r22, r12
	mov	r24, r14
	rcall	xram_start
	ldi	r27, CHUNK              ; m = min(left, CHUNK)
	tst	r17
	brne	3f
	cp	r16, r27
	brsh	3f
	mov	r27, r16
3:	sub	r16, r27                ; left -= m, address += m
	sbc	r17, r1
	add	r12, r27
	adc	r13, r1
	adc	r14, r1
	adc	r15, r1
	movw	r30, r28
	mov	r19, r11
	rcall	xfer
	movw	r28, r30
	sbi	_SFR_IO_ADDR(PORTA), PA4
	clr	r1
	call	spi_unlock              ; (runs the copy task if it waited)
	rjmp	2b
9:	pop	r29
	pop	r28
	pop	r17
	pop	r16
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	pop	r11
	ret
