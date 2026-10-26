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

; Transfers of more than 32 bytes go in chunks, each its own transaction, with spi_unlock() in
; between: the copy task (which feeds the video mode) never waits long for the bus.
#define CHUNK 32
	.section .text.xram_read
	.global	xram_read
	.global	xram_write
xram_read:
	ldi	r26, 3
	rjmp	1f
xram_write:
	ldi	r26, 2
1:	push	r11
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
	ldi	r26, 0xFF
	sbrs	r11, 0                  ; (command 3: read, 2: write)
	rjmp	5f
4:	out	_SFR_IO_ADDR(SPDR), r26 ; read m bytes
91:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	91b
	in	r0, _SFR_IO_ADDR(SPDR)
	st	Y+, r0
	dec	r27
	brne	4b
	rjmp	6f
5:	ld	r26, Y+                 ; write m bytes
	out	_SFR_IO_ADDR(SPDR), r26
92:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	92b
	in	r0, _SFR_IO_ADDR(SPDR)
	dec	r27
	brne	5b
6:	sbi	_SFR_IO_ADDR(PORTA), PA4
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
