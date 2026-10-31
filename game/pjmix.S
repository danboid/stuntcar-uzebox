/* Engine sound: channels 1-3 of the PJ Mixer (Uze6666, uzebox/demos/pjmixer.s, notes in
 * pjmixer.md), mixed once per frame from the vsync callback (scr_game.c, sound_frame) instead
 * of inline: video mode 19's line interrupt has no cycles to spare.
 *
 * Per output sample, as the original (each product >> 8, arithmetic, before the next step):
 *   t1 = tri(pos1) * v12 >> 8,  t2 = tri(pos2) * v12 >> 8,  t3 = tri(pos3) * v3 >> 8
 *   out = clip((t1 + t2) * t3, -128, 127) + 128
 * Half rate: one sample per two lines (7867 Hz), written twice; the caller doubles the steps,
 * so sample j here is the original's sample 2j. The noise channel is left out (silent in the
 * demo); channels 1 and 2 share one volume (100 in the demo).
 *
 * tri() is the kernel's triangle wave (wave 2), computed: the phase is kept as q = pos + 64,
 * then tri = (2q mod 256) ^ 0x80, complemented when q >= 128.
 * v12 <= 127 keeps t1 + t2 within a byte (with v12 = 100: -100..98), so the ring product is
 * one muls: (t1 + t2) * t3 is at most 128 * 64.
 *
 * pj_mix writes the engine at a quarter of full scale (96..159, after its clip), so that the sound
 * effects can be added to it at three quarters: engine + effect * 3 / 4 fills 0..255 exactly, no
 * clipping - the engine's level the same whether an effect plays or not. pj_sfx: samples from SPI RAM (128 KB builds); pj_noise: noise
 * bursts (64 KB builds, SAMPLES=0).
 *
 * void pj_mix(uint8_t *dst, uint8_t pairs)  writes 2 * pairs bytes (pairs >= 1), ~47 cycles
 * per pair. Uses pj_step[3] (8.8 steps per mixed sample) and pj_v12, pj_v3 from the C side.
 * r5 belongs to the video interrupt: not used here. */
#include <avr/io.h>

	.section .data
pj_ph:	.byte	0, 64, 0, 64, 0, 64     ; frac, q per channel: all at pos 0, as the demo starts

	.macro	MIXFX                   ; r20 = *X - 96 + r23: the engine (96..159) plus an effect,
	ld	r20, X                  ; r23 = effect * 3 / 4 (0..192, 96: silence) - 0..255
	subi	r20, 96
	add	r20, r23
	.endm

	.section .text.pj_mix,"ax",@progbits
	.global pj_mix
pj_mix:
	push	r2
	push	r3
	push	r6
	push	r7
	push	r8
	push	r9
	push	r10
	push	r11
	push	r14
	push	r15
	push	r16
	push	r17
	movw	r26, r24                ; X = dst
	ldi	r30, lo8(pj_step)
	ldi	r31, hi8(pj_step)
	ld	r2, Z+                  ; steps: ch1 r3:r2, ch2 r25:r24, ch3 r7:r6
	ld	r3, Z+
	ld	r24, Z+
	ld	r25, Z+
	ld	r6, Z+
	ld	r7, Z+
	ldi	r30, lo8(pj_ph)
	ldi	r31, hi8(pj_ph)
	ld	r8, Z+                  ; phases (frac, q): ch1 r9:r8, ch2 r11:r10, ch3 r15:r14
	ld	r9, Z+
	ld	r10, Z+
	ld	r11, Z+
	ld	r14, Z+
	ld	r15, Z
	lds	r17, pj_v12
	lds	r18, pj_v3

1:	add	r8, r2                  ; channel 1: phase += step (8.8, wraps at 256)
	adc	r9, r3
	mov	r16, r9                 ; tri(q - 64)
	lsl	r16
	brcc	2f
	com	r16
2:	subi	r16, 0x80               ; (^ 0x80)
	mulsu	r16, r17                ; t1 = tri * v12 >> 8
	mov	r19, r1

	add	r10, r24                ; channel 2
	adc	r11, r25
	mov	r16, r11
	lsl	r16
	brcc	2f
	com	r16
2:	subi	r16, 0x80               ; (^ 0x80)
	mulsu	r16, r17
	add	r19, r1                 ; a = t1 + t2

	add	r14, r6                 ; channel 3: the modulator
	adc	r15, r7
	mov	r16, r15
	lsl	r16
	brcc	2f
	com	r16
2:	subi	r16, 0x80               ; (^ 0x80)
	mulsu	r16, r18
	mov	r20, r1                 ; t3

	muls	r19, r20                ; r1:r0 = a * t3
	mov	r21, r0
	subi	r21, 0x80               ; in range: out = r0 + 128
	tst	r1
	brmi	4f
	brne	3f                      ; >= 256: high rail
	sbrc	r0, 7                   ; 128..255: high rail
3:	ldi	r21, 255
	rjmp	5f
4:	inc	r1
	brne	6f                      ; < -256: low rail
	sbrs	r0, 7                   ; -256..-129: low rail
6:	ldi	r21, 0
5:	lsr	r21                     ; a quarter of full scale, centred: 96..159
	lsr	r21
	subi	r21, -96
	st	X+, r21
	st	X+, r21
	dec	r22
	brne	1b

	clr	r1
	sts	pj_ph + 0, r8
	sts	pj_ph + 1, r9
	sts	pj_ph + 2, r10
	sts	pj_ph + 3, r11
	sts	pj_ph + 4, r14
	sts	pj_ph + 5, r15
	pop	r17
	pop	r16
	pop	r15
	pop	r14
	pop	r11
	pop	r10
	pop	r9
	pop	r8
	pop	r7
	pop	r6
	pop	r3
	pop	r2
	ret

#ifndef SCR_SAMPLES
; void pj_noise(uint8_t *dst, uint8_t pairs): noise, each random value held for sfx_grain samples
; (full rate; set by scr_game.c), binary (as loud as the clipped engine, almost a square wave)
	.section .data
nz_rng:	.byte	1, 0                    ; 16-bit LFSR state (own: rand() stays the physics')
	.section .bss
	.global sfx_grain
sfx_grain: .skip 1                      ; samples per random value
nz_g:	.skip 1                         ; samples left of the current value
nz_v:	.skip 1                         ; the current value

	.section .text.pj_noise,"ax",@progbits
	.global pj_noise
pj_noise:
	movw	r26, r24
	lds	r18, nz_g
	lds	r19, sfx_grain
	lds	r24, nz_rng
	lds	r25, nz_rng + 1
	lds	r23, nz_v
1:	rcall	nz_byte
	rcall	nz_byte
	dec	r22
	brne	1b
	sts	nz_g, r18
	sts	nz_rng, r24
	sts	nz_rng + 1, r25
	sts	nz_v, r23
	ret
nz_byte:
	subi	r18, 1                  ; the value's samples used up: a new one
	brcc	2f
	mov	r18, r19
	dec	r18
	lsr	r25                     ; Galois LFSR, taps 0xB400: period 65535 (the 8-bit
	ror	r24                     ; xorshift used before repeated every 17 values: a tone,
	brcc	3f                      ; not noise - the effects beeped)
	ldi	r20, 0xB4
	eor	r25, r20
3:	ldi	r23, 0                  ; noise * 3 / 4: 0 or 192 (binary: values spread over
	sbrc	r24, 7                  ; 0..192 were half as loud)
	ldi	r23, 192
2:	MIXFX
	st	X+, r20
	ret

#else
; ---- the sampled effects (128 KB builds, sounds/<effect>.wav, tools/mksfx.py): SPI RAM from 0x5200,
; 'S' 'X' count 0, then per effect its offset (from 0x5200) and length (samples, 0: none), each
; 16-bit; the samples unsigned, 7867 Hz (one per pair). scr_game.c: sfx_run, sfx_late.
	.section .bss
	.global smp_new, smp_cur, smp_left
smp_new:	.skip 1                 ; effect + 1 to start (its directory entry is read first)
smp_cur:	.skip 1                 ; the effect playing (+ 1)
smp_left:	.skip 2                 ; its samples left
smp_pos:	.skip 2                 ; the next one, from 0x5200

; void pj_sfx(uint8_t *dst, uint8_t pairs): the playing effect's next samples, each added to a
; pair that pj_mix wrote (engine + sample * 3 / 4), until it ends. The caller holds the SPI
; bus (spi_lock). ~45 cycles a pair.
	.section .text.pj_sfx,"ax",@progbits
	.global pj_sfx
pj_sfx:
	movw	r26, r24                ; X = dst
	lds	r20, smp_new
	tst	r20
	breq	1f
	sts	smp_new, r1             ; start effect r20: its directory entry (at 4 * r20)
	sts	smp_cur, r20
	lsl	r20
	lsl	r20
	mov	r24, r20
	ldi	r25, 0
	rcall	sfx_open
	rcall	spix                    ; offset
	mov	r24, r23
	rcall	spix
	mov	r25, r23
	rcall	spix                    ; length
	mov	r18, r23
	rcall	spix
	mov	r19, r23
	sbi	_SFR_IO_ADDR(PORTA), PA4
	rjmp	2f
1:	lds	r24, smp_pos
	lds	r25, smp_pos + 1
	lds	r18, smp_left
	lds	r19, smp_left + 1
2:	cp	r18, r1
	cpc	r19, r1
	breq	9f                      ; (none playing)
	rcall	sfx_open
3:	rcall	spix                    ; the sample * 3 / 4
	mov	r20, r23
	lsr	r20
	lsr	r20
	sub	r23, r20
	MIXFX                           ; + the engine
	st	X+, r20
	st	X+, r20
	adiw	r24, 1
	subi	r18, 1
	sbci	r19, 0
	breq	4f                      ; (the end of the effect)
	dec	r22
	brne	3b
4:	sbi	_SFR_IO_ADDR(PORTA), PA4
	sts	smp_pos, r24
	sts	smp_pos + 1, r25
9:	sts	smp_left, r18
	sts	smp_left + 1, r19
	ret

; open a read of SPI RAM at 0x5200 + r25:r24 (kept): chip select, command 3, 24-bit address
sfx_open:
	cbi	_SFR_IO_ADDR(PORTA), PA4
	ldi	r23, 3
	rcall	spix
	ldi	r21, 0x52               ; (0x5200 + r25:r24 < 0x14000: bit 16 is the carry)
	add	r21, r25
	ldi	r23, 0
	adc	r23, r23
	rcall	spix
	mov	r23, r21
	rcall	spix
	mov	r23, r24                ; (the last byte: into spix)
spix:	out	_SFR_IO_ADDR(SPDR), r23   ; send r23, receive into r23 (polled, ~20 cycles)
1:	in	r0, _SFR_IO_ADDR(SPSR)
	sbrs	r0, SPIF
	rjmp	1b
	in	r23, _SFR_IO_ADDR(SPDR)
	ret
#endif
