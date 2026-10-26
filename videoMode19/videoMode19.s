/*
 * Uzebox video mode 19 - run-length-encoded scanlines.
 * (19: S is the 19th letter - Stunt Car Racer, and Sega, whose Model series inspired the
 * Model S renderer that feeds this mode.)
 *
 * 256 x 110 pixels (each row shown on two scanlines), any of the 256 colours per run. The
 * picture is not stored as pixels: the mode plays rows of (colour, run length) pairs from a
 * 256-byte ring, timing every run boundary with Timer1, so the CPU is free during long runs.
 * Build options (game/Makefile): BGTASK (background task in the line interrupt), RING_SECTION
 * (ring at a fixed address), RESYNC (frame resynchronisation), MIX_END (variable sound loop),
 * SLED / LAT_MIN (interrupt latency window). M19_KERNEL (videoMode19.def.h) selects the kernel
 * build; without it the file builds standalone with its own sync, for test harnesses.
 *
 * Development notes follow.
 *
 * Step 1b: clean-room video mode core, standalone (no kernel).
 *
 * Timer1 in CTC mode: each event handler writes OCR1A = delta-1 for the next event.
 * The interrupt removes its entry jitter (computed jump into a NOP sled), so every
 * handler starts a fixed time H after its compare match. Sync events: see step 1a.
 *
 * Render lines read byte pairs from a 256-byte ring buffer (256-aligned):
 *   (c, n<<1)   run of n+2 pixels of colour c      (n <= 126)
 *   (a, b|1)    two single pixels a, b
 *   (0, 0xFE)   end of line: output colour 0 (border), next event = the next line's sync
 * A pixel is 5 cycles. Runs with n < LONG are output inside the handler with exact
 * 5-cycle-per-pixel loops; longer runs reprogram Timer1 (OCR1A computed from TCNT1,
 * the exact time since this interrupt's event) and return the CPU to the main program.
 * The next sync is scheduled from `lt` (time of the current event since the line's sync
 * event), so sync timing never depends on the stream contents.
 *
 * One source for both builds: standalone (test harness, own sync) and -DM19_KERNEL (Uzebox
 * kernel video mode 19; see the end of file).
 *
 * Step 3 (kernel-ready timing): Timer1 runs in normal mode and events use the OVERFLOW
 * interrupt (TIMER1_OVF_vect, free in the Uzebox kernel; its COMPA/COMPB vectors are taken).
 * tset() writes TCNT1 so the next overflow is exactly `delta` cycles after the current event
 * (TCNT1 still equals the time since the event, so the de-jitter is unchanged). Each line also
 * outputs one sound sample from the kernel-format mix buffer (mix_buf/mix_pos -> OCR2A):
 * 262 per frame (one per line, one per two vsync pulses).
 *
 * Step 2: rows come live from the rasterizer (the Model S rasterizer, modelS_rast.S) through the ring buffer; each row is
 * shown on two lines. The interrupt keeps a private read pointer `m19_rd`; after the first line
 * of a row it rewinds `rd` to r5, and only after the second line does r5 (the committed read
 * index the rasterizer checks before writing) move on. So a row can't be overwritten while it
 * is still to be replayed.
 *
 * The only register reserved for the interrupt is r5 (C code: -ffixed-r5); everything else it
 * uses is saved and restored.
 */
#include <avr/io.h>
	.extern ring_w

#define RL_COUNT  220               /* picture lines (110 rows x 2) */
#ifdef M19_KERNEL
#define RL_FIRST  0                 /* our line 0 = the line after the kernel's render call */
#ifndef C_IN
#define C_IN      (99 + SLED_X)     /* handover in:  calibrated (lines stay 1820 cycles) */
#endif
#ifndef C_OUT
#define C_OUT     (150 - SLED_X)    /* handover out: calibrated */
#endif
#ifndef SND_PAD
#define SND_PAD   0                 /* (was 12: the kernel's sample offset after the sync; a 12-cycle
                                       shift is inaudible and the sync-fall handler needs the time:
                                       with 12 the sync-rise event 136 cycles later was entered late) */
#endif
#else
#define LINES     253
#define RL_FIRST  22
#endif
#ifndef SND_PAD
#define SND_PAD   4                 /* standalone: same offset as its own vsync handlers */
#endif
#define PX0       379               /* first pixel, cycles after the sync fall */
#define PXW       1280
#define SYNC      0
#ifndef LAT_MIN
#define LAT_MIN   13                /* TCNT1L read in the prologue, fastest entry (13 on the current
                                       cuzebox-ex, 15 on the older cuzebox: both inside the window) */
#endif
#ifndef TW
#define TW        11                /* tset: TCNT1 sample -> write effective (calibrated) */
#endif
#ifndef MIX_BUF_SIZE
#define MIX_BUF_SIZE 524            /* kernel: 2 x 262 samples */
#endif
#ifndef SLED
#define SLED      10                /* jitter range absorbed: TCNT1L LAT_MIN .. LAT_MIN + SLED - 1 */
#endif
#define SLED_X    (LAT_MIN + SLED - 23)   /* fixed latency beyond the calibration (15 + 8) */
#ifndef V0
#define V0        (43 + SLED_X)     /* TCNT1L that an lds at a handler's start would read */
#endif
#define K_OUT     9                 /* h_run start -> first `out` */
#define D_LONG    12                /* that `out` -> the TCNT1L read in r_long */
#ifndef LONG
#define LONG      (26 + (SLED_X + 4) / 5)   /* runs of LONG+2 pixels and more use the timer (the
                                         fixed entry latency grows with the sled) */
#endif

	.macro SETNEXT delta, handler
	ldi	r16, lo8(\delta)
	ldi	r17, hi8(\delta)
	rcall	tset
	ldi	r30, lo8(pm(\handler))
	ldi	r31, hi8(pm(\handler))
	sts	m19_ev, r30
	sts	m19_ev + 1, r31
	.endm

#ifdef RING_SECTION
	; the ring must be 256-aligned: in its own section, placed at the start of RAM by the
	; linker (--section-start=.ringbuf=0x800100, -Tdata=0x800200), so that no padding is
	; wasted around it (.balign in .bss pads the section on both sides)
	.section .ringbuf,"aw",@nobits
	.global ring
ring:	.skip 256
	.section .bss
#else
	.section .bss
	.balign	256
	.global ring
ring:	.skip 256
#endif
m19_ev:	.skip 2
m19_lt:	.skip 2                         ; time of the current event since the line's sync event
m19_rd:	.skip 1                         ; the interrupt's read index into the ring
	.global m19_video_on, m19_underruns
m19_video_on: .skip 1                       ; set by the main program when rows are coming
m19_vis:	.skip 1                         ; m19_video_on latched at the start of each frame
m19_underruns: .skip 2                      ; lines shown blank because no row was ready
	.global m19_line, m19_frames, m19_late, m19_v0cal
m19_line:	.skip 1
m19_vsk:	.skip 1
m19_frames:	.skip 2
m19_late:	.skip 2                         ; interrupts entered later than the sled covers
	.global m19_late_pc
m19_late_pc:	.skip 2
#ifdef LAT_ALLHIST
	.global m19_lat_hist
m19_lat_hist:	.skip 32
#endif
#ifdef LATE_PC
	.global m19_late_ring
m19_late_ring:	.skip 128
#endif
#ifdef LATE_HIST
	.global m19_late_hist
m19_late_hist:	.skip 16
#endif
m19_v0cal:	.skip 1
	.global latlo, lathi
latlo:	.skip 1
lathi:	.skip 1

	.section .text
#ifndef M19_KERNEL
	.section .bss                   ; standalone: own mix buffer (the kernel provides one)
	.global mix_buf, mix_pos
mix_buf: .skip MIX_BUF_SIZE
mix_pos: .skip 2
	.section .text
#endif
; next overflow `delta` (r17:r16) cycles after the current event. TW = cycles from the TCNT1
; sample to the write taking effect (calibrated). Uses r30, r31.
tset:	lds	r30, TCNT1L
	lds	r31, TCNT1H
	sub	r30, r16
	sbc	r31, r17
	subi	r30, lo8(-(TW))
	sbci	r31, hi8(-(TW))
	sts	TCNT1H, r31
	sts	TCNT1L, r30
	ret

; one sound sample per line, kernel format (uses r16, r30, r31)
snd:	lds	r30, mix_pos
	lds	r31, mix_pos + 1
	ld	r16, Z+
	sts	OCR2A, r16
#ifdef MIX_END
	lds	r16, mix_end            ; past the game's loop end (a whole number of periods)?
	cp	r30, r16
	lds	r16, mix_end + 1
	cpc	r31, r16
	brlo	1f
	lds	r16, mix_len            ; back by one loop: keeps the phase even when the kernel's
	sub	r30, r16                ; lines left the position in the continuation beyond the end
	sbci	r31, 0
	rjmp	1f
#else
	cpi	r30, lo8(mix_buf + MIX_BUF_SIZE)
	ldi	r16, hi8(mix_buf + MIX_BUF_SIZE)
	cpc	r31, r16
#endif
	brlo	1f
	ldi	r30, lo8(mix_buf)
	ldi	r31, hi8(mix_buf)
1:	sts	mix_pos, r30
	sts	mix_pos + 1, r31
	ret

	.global TIMER1_OVF_vect
TIMER1_OVF_vect:
	push	r30
	push	r31
	in	r30, _SFR_IO_ADDR(SREG)
	push	r30
	lds	r30, TCNT1L             ; cycles since the event (overflow)
#ifdef LAT_ALLHIST
	push	r31                     ; diagnostics: histogram of TCNT1L at every entry (0..31)
	push	r29
	push	r28
	andi	r30, 31
	ldi	r28, lo8(m19_lat_hist)
	ldi	r29, hi8(m19_lat_hist)
	add	r28, r30
	brcc	91f
	inc	r29
91:	ld	r31, Y
	inc	r31
	st	Y, r31
	pop	r28
	pop	r29
	pop	r31
	lds	r30, TCNT1L             ; (re-read: the histogram took 17 cycles)
	subi	r30, 17
#endif
	subi	r30, LAT_MIN
	cpi	r30, SLED
	brlo	1f
	rjmp	is_late
1:	ldi	r31, 0
	subi	r30, lo8(-(pm(sled)))
	sbci	r31, hi8(-(pm(sled)))
	ijmp
sled:	.rept	SLED - 1
	nop
	.endr
dispatch:
	push	r16
	push	r17
	lds	r30, m19_ev
	lds	r31, m19_ev + 1
	ijmp
is_late:                                ; diagnostics only: count, then dispatch m19_late
#ifdef LATE_PC
	push	r16                     ; ring of the last 64 interrupted PCs (return address)
	push	r17
	push	r28
	push	r29
	in	r28, _SFR_IO_ADDR(SPL)
	in	r29, _SFR_IO_ADDR(SPH)
#ifdef LATE_EV
	lds	r17, m19_ev             ; the handler about to run instead of the interrupted PC
	lds	r16, m19_ev + 1
#else
	ldd	r16, Y+8                ; above r29, r28, r17, r16, r30, r31, SREG: PC high, low
	ldd	r17, Y+9
#endif
	lds	r30, m19_late_pc
	andi	r30, 63
	mov	r31, r30
	inc	r31
	sts	m19_late_pc, r31
	lsl	r30
	ldi	r28, lo8(m19_late_ring)
	ldi	r29, hi8(m19_late_ring)
	add	r28, r30
	brcc	1f
	inc	r29
1:	st	Y+, r16
	st	Y, r17
	pop	r29
	pop	r28
	pop	r17
	pop	r16
#endif
#ifdef LATE_HIST
	push	r16                     ; histogram of the raw TCNT1L read at entry, in buckets of 16
	mov	r16, r30
	subi	r16, -(LAT_MIN)         ; back to the TCNT1L value
	swap	r16
	andi	r16, 15
	ldi	r30, lo8(m19_late_hist)
	ldi	r31, hi8(m19_late_hist)
	add	r30, r16
	brcc	1f
	inc	r31
1:	ld	r16, Z
	inc	r16
	st	Z, r16
	pop	r16
#endif
	lds	r30, m19_late
	lds	r31, m19_late + 1
	adiw	r30, 1
	sts	m19_late, r30
	sts	m19_late + 1, r31
	rjmp	dispatch

;------------------------------------------------------------------ sync events
h_hsfall:
#ifdef CAL
	lds	r16, TCNT1L             ; calibration build: measures V0 (r16 is saved)
	sts	m19_v0cal, r16
#endif
	cbi	_SFR_IO_ADDR(PORTB), SYNC
	.rept	SND_PAD                 ; same sample offset as the vsync handlers / kernel
	nop
	.endr
	rcall	snd
	lds	r30, m19_line
	inc	r30
	sts	m19_line, r30
	ldi	r30, 136
	sts	m19_lt, r30
	clr	r30
	sts	m19_lt + 1, r30
	SETNEXT	136, h_hsrise
	rjmp	done

h_hsrise:
	sbi	_SFR_IO_ADDR(PORTB), SYNC
	lds	r30, m19_vis
	tst	r30
	brne	4f
	rjmp	2f                      ; (long jump: the resync code below)
4:
	lds	r30, m19_line
	subi	r30, RL_FIRST
	cpi	r30, RL_COUNT
	brlo	4f
	rjmp	2f
4:
	sbrc	r30, 0                  ; second line of a row: the data is there (replay)
	rjmp	1f
#ifdef RESYNC
	; frame resync: at the frame's first line (or while one is pending) start reading at
	; the ring position where the rasterizer began row 0 (frame_start_w), dropping what is
	; left of the previous frame; not published yet: blank lines until it is
	tst	r30
	breq	5f
	lds	r31, m19_resync
	tst	r31
	breq	6f
5:	lds	r31, frame_start_valid
	tst	r31
	breq	7f
	lds	r31, frame_start_w
	sts	m19_rd, r31
	mov	r5, r31
	clr	r31
	sts	frame_start_valid, r31
	sts	m19_resync, r31
	rjmp	6f
7:	ldi	r31, 1
	sts	m19_resync, r31
	rjmp	8f
6:
#endif
	lds	r30, m19_rd                 ; first line: a complete row must be waiting
	lds	r31, ring_w             ; (the rasterizer publishes ring_w per finished row)
	cp	r30, r31
	brne	1f
8:	lds	r30, m19_underruns          ; none: show a blank line, keep sync
	lds	r31, m19_underruns + 1
	adiw	r30, 1
	sts	m19_underruns, r30
	sts	m19_underruns + 1, r31
	rjmp	2f
1:
	ldi	r30, lo8(PX0 - K_OUT)   ; lt of the first run event
	ldi	r31, hi8(PX0 - K_OUT)
	sts	m19_lt, r30
	sts	m19_lt + 1, r31
	SETNEXT	PX0 - 136 - K_OUT, h_run
#ifdef BGTASK
	rjmp	bg_check
#else
	rjmp	done
#endif
2:	lds	r30, m19_line
#ifdef M19_KERNEL
	cpi	r30, RL_COUNT           ; the line after the picture: give Timer1 back
	brne	3f
	rjmp	handback
#else
	cpi	r30, LINES - 1
	brne	3f
	SETNEXT	1820 - 136, h_vseq
	rjmp	done
#endif
3:	SETNEXT	1820 - 136, h_hsfall
#ifdef BGTASK
	rjmp	bg_check
#else
	rjmp	done
#endif

#ifndef M19_KERNEL
h_vseq:                                 ; equalisation pulse: low for 68 cycles, in one event
	cbi	_SFR_IO_ADDR(PORTB), SYNC       ; t
	lds	r30, m19_vsk                ; t+2
	sbrc	r30, 0                  ; t+4   sound sample on even pulses (one per line)
	rjmp	5f
	rcall	snd                     ; t+6..31  sample written at the same offset as in h_hsfall
	ldi	r30, 11                 ; sample path (cycle counts verified by measurement)
	nop
	rjmp	.+0
	rjmp	6f
5:	ldi	r30, 20                 ; no-sample path
	nop
6:	dec	r30
	brne	6b
	sbi	_SFR_IO_ADDR(PORTB), SYNC       ; t+68
	lds	r30, m19_vsk
	inc	r30
	sts	m19_vsk, r30
	cpi	r30, 6
	brne	2f
	SETNEXT	910, h_vsser            ; pulses 6..11 are serration pulses
	rjmp	done
2:	cpi	r30, 18
	breq	3f
	SETNEXT	910, h_vseq
	rjmp	done
3:	clr	r30                     ; vsync done: next is normal line 0, 910 after this fall
	sts	m19_vsk, r30
	ldi	r30, 0xFF
	sts	m19_line, r30
	lds	r30, m19_video_on           ; rendering starts/stops only at frame boundaries
	sts	m19_vis, r30
	lds	r30, m19_frames
	lds	r31, m19_frames + 1
	adiw	r30, 1
	sts	m19_frames, r30
	sts	m19_frames + 1, r31
	SETNEXT	910, h_hsfall
	rjmp	done

h_vsser:                                ; serration pulse: low for 774 cycles
	cbi	_SFR_IO_ADDR(PORTB), SYNC
	lds	r30, m19_vsk                ; t+2
	nop                             ; t+4
	sbrs	r30, 0                  ; t+5 (no skip: 1 cycle)
	rcall	snd                     ; t+6
	SETNEXT	774, h_vsserr
	rjmp	done

h_vsserr:
	sbi	_SFR_IO_ADDR(PORTB), SYNC
	lds	r30, m19_vsk
	inc	r30
	sts	m19_vsk, r30
	cpi	r30, 12
	brne	4f
	SETNEXT	910 - 774, h_vseq
	rjmp	done
4:	SETNEXT	910 - 774, h_vsser
	rjmp	done

#endif

;------------------------------------------------------------------ runs
h_run:                                  ; +0  (normal mode: nothing can fire mid-chain)
	lds	r30, m19_rd
	ldi	r31, hi8(ring)
	rjmp	r_next                  ; +8..9
r_single:                               ; second single pixel: tau + 5
	out	_SFR_IO_ADDR(PORTC), r17
r_next:	ld	r16, Z+
	ld	r17, Z+
r_loop:	out	_SFR_IO_ADDR(PORTC), r16 ; tau (handler start + K_OUT on entry)
	ldi	r31, hi8(ring)          ; tau+1  (ring wrap)
	sbrc	r17, 0                  ; tau+2
	rjmp	r_single                ; tau+3..4
	lsr	r17                     ; tau+4  n
	cpi	r17, LONG               ; tau+5
	brsh	r_long                  ; tau+6 (taken: tau+6..7)
	nop                             ; tau+7
r_wait:	dec	r17                     ; 5 cycles per pixel: total out->out = 5(n+2)
	breq	r_next
	nop
	rjmp	r_wait

r_long:                                 ; tau+8
	sts	m19_rd, r30                 ; tau+8..9   save the read pointer
	cpi	r17, 0x7F               ; tau+10  end of line?
	breq	r_eol                   ; tau+11
	lds	r30, TCNT1L             ; tau+12 = D_LONG
	lds	r31, TCNT1H
	push	r24
	push	r25
	subi	r17, -2                 ; x = n+2 pixels
	mov	r24, r17
	clr	r25
	lsl	r24
	rol	r25
	lsl	r24
	rol	r25
	add	r24, r17
	clr	r16
	adc	r25, r16                ; 5x
	add	r24, r30                ; + T
	adc	r25, r31
	subi	r24, lo8(D_LONG + K_OUT + V0)   ; = delta
	sbci	r25, hi8(D_LONG + K_OUT + V0)
	movw	r16, r24
	rcall	tset
	lds	r16, m19_lt                 ; lt += delta  (still h_run next)
	lds	r17, m19_lt + 1
	add	r16, r24
	adc	r17, r25
	sts	m19_lt, r16
	sts	m19_lt + 1, r17
	rjmp	done2

r_eol:                                  ; the border colour was output at tau
	push	r24
	push	r25
	lds	r24, m19_line               ; line doubling: rewind after the first line of a row,
	subi	r24, RL_FIRST           ; commit after the second
	sbrc	r24, 0
	rjmp	10f
	sts	m19_rd, r5                  ; first line: replay this row
	rjmp	11f
10:	lds	r5, m19_rd                  ; second line: the row is consumed
11:	lds	r24, m19_lt                 ; next sync event at 1820 after this line's
	lds	r25, m19_lt + 1
	ldi	r16, lo8(1820)
	ldi	r17, hi8(1820)
	sub	r16, r24
	sbc	r17, r25
	rcall	tset
#ifndef M19_KERNEL
	lds	r30, m19_line
	cpi	r30, LINES - 1
	brne	8f
	ldi	r30, lo8(pm(h_vseq))
	ldi	r31, hi8(pm(h_vseq))
	rjmp	9f
#endif
8:	ldi	r30, lo8(pm(h_hsfall))
	ldi	r31, hi8(pm(h_hsfall))
9:	sts	m19_ev, r30
	sts	m19_ev + 1, r31
	rjmp	done2

#ifdef BGTASK
;------------------------------------------------------------------ background task
; Run the C function bg_task() with interrupts enabled, nested inside this interrupt, once per
; line when: it is not already running, the main program allows it (bg_enable), does not hold
; the SPI bus (spi_lock), and the ring has at least BG_ROOM bytes free. Interrupts are off only
; for the checks (~20 cycles): the mode's events preempt the task like any main-program code.
#ifndef BG_ROOM
#define BG_ROOM 96
#endif
	.section .bss
#ifdef MIX_END
	.global mix_end
mix_end:	.skip 2                 ; sound loop end (set by the game before video starts)
	.global mix_len
mix_len:	.skip 1                 ; loop length (mix_end - mix_buf)
#endif
#ifdef RESYNC
	.global frame_start_w, frame_start_valid, m19_resync, rast_abort
frame_start_w:	.skip 1             ; ring index where the rasterizer began row 0
frame_start_valid: .skip 1          ; set by the rasterizer, cleared when the mode jumps there
m19_resync:	.skip 1                 ; a frame start is pending (blank lines until published)
rast_abort:	.skip 1                 ; mode -> rasterizer: abandon the frame, start row 0
#endif
	.global bg_active, bg_enable, spi_lock, bg_pending
bg_active:	.skip 1
bg_enable:	.skip 1
spi_lock:	.skip 1
bg_pending:	.skip 1                 ; skipped because of spi_lock: the main program runs the
					; task when it releases the lock (see spi_unlock in C)
	.section .text
bg_check:
	lds	r30, bg_active          ; (no use of r1: it is not 0 right after a mul)
	tst	r30
	brne	done
	lds	r30, bg_enable
	tst	r30
	breq	done
	lds	r30, spi_lock
	tst	r30
	breq	1f
	sts	bg_pending, r30         ; (r30 = 1)
	rjmp	done
1:
	lds	r30, ring_w             ; used = ring_w - r5; room = 254 - used
	sub	r30, r5
	cpi	r30, 254 - BG_ROOM + 1
	brsh	done
	ldi	r30, 1
	sts	bg_active, r30
	sei                             ; from here on the task is preemptible
	push	r0
	push	r1
	clr	r1                      ; C ABI zero register for bg_task
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
	call	bg_task
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
	sts	bg_active, r1           ; r1 = 0 here (C code returned)
	pop	r1
	pop	r0
	rjmp	done                    ; (done restores SREG: interrupts off for its last 8 cycles)
#endif

done:	pop	r17
	pop	r16
	pop	r30
	out	_SFR_IO_ADDR(SREG), r30
	pop	r31
	pop	r30
	reti
done2:	pop	r25                     ; exit from paths that also used r24/r25
	pop	r24
	rjmp	done

;------------------------------------------------------------------ setup / producer
#ifndef M19_KERNEL
	.global m19_start
m19_start:
	ldi	r30, lo8(pm(h_vseq))
	ldi	r31, hi8(pm(h_vseq))
	sts	m19_ev, r30
	sts	m19_ev + 1, r31
	clr	r30
	sts	m19_vsk, r30
	sts	m19_rd, r30
	clr	r5
	ldi	r30, lo8(mix_buf)
	sts	mix_pos, r30
	ldi	r30, hi8(mix_buf)
	sts	mix_pos + 1, r30
	ret

#else
;------------------------------------------------------------------ Uzebox kernel interface
; The kernel generates vsync and the non-picture lines (sound, controllers, music). At its
; first render line it calls VMODE_FUNC (m19_render) from its TIMER1_COMPA interrupt, at
; TCNT1 ~ 0x234, after that line's sync (cbi at TCNT1 0x68) and sound sample. m19_render
; leaves that line blank, takes Timer1 (normal mode, overflow interrupt only) and schedules
; the next line's sync exactly 1820 cycles after the kernel's. The mode then draws RL_COUNT
; lines and, at the sync rise of the following line, hands Timer1 back (handback below).
	.section .bss
m19_p0:	.skip 1                         ; kernel sync_pulse at the render call
	.section .text

	.global m19_render
m19_render:
	lds	r24, sync_pulse
	sts	m19_p0, r24
	ldi	r24, 0xFF
	sts	m19_line, r24
	ldi	r24, 1                  ; Timer1 normal mode, clk/1 (TCNT1 keeps counting)
	sts	TCCR1B, r24
	ldi	r24, (1 << TOV1) | (1 << OCF1A) | (1 << OCF1B)
	out	_SFR_IO_ADDR(TIFR1), r24
	ldi	r24, (1 << TOIE1)       ; only the mode's overflow interrupt
	sts	TIMSK1, r24
	ldi	r16, lo8(1820 + 0x68 - C_IN)    ; next sync 1820 after the kernel's (TCNT1 0x68)
	ldi	r17, hi8(1820 + 0x68 - C_IN)
	rcall	tset
	ldi	r30, lo8(pm(h_hsfall))
	ldi	r31, hi8(pm(h_hsfall))
	sts	m19_ev, r30
	sts	m19_ev + 1, r31
	ret

; in the mode's interrupt, right after the sync rise of the line after the picture
handback:
#ifdef RESYNC
	lds	r16, frame_start_valid  ; the rasterizer has not begun the next frame: make it
	tst	r16                     ; abandon this one (it starts row 0 at its next row boundary)
	brne	1f
	ldi	r16, 1
	sts	rast_abort, r16
1:
#endif
	ldi	r16, (1 << WGM12) | (1 << CS10) ; CTC again (OCR1A is still the kernel's HDRIVE_CL)
	sts	TCCR1B, r16
	lds	r30, TCNT1L             ; v = time since this event
	lds	r31, TCNT1H
	subi	r30, lo8(-(C_OUT))      ; kernel's next match makes its sync 1820 after ours
	sbci	r31, hi8(-(C_OUT))
	sts	TCNT1H, r31
	sts	TCNT1L, r30
	lds	r16, m19_p0             ; the kernel's line counter, as if it had made our lines
	subi	r16, RL_COUNT + 1
	sts	sync_pulse, r16
	ldi	r16, (1 << TOV1) | (1 << OCF1A) | (1 << OCF1B)
	out	_SFR_IO_ADDR(TIFR1), r16
	ldi	r16, (1 << OCIE1A)
	sts	TIMSK1, r16
	rjmp	done

	.global InitializeVideoMode, DisplayLogo, VideoModeVsync, ClearVram
InitializeVideoMode:
	ldi	r24, 0xFE               ; PORTC bit 0 is the stream's single-pixel flag
	out	_SFR_IO_ADDR(DDRC), r24
	clr	r24
	sts	m19_rd, r24
	sts	m19_video_on, r24
	sts	m19_vis, r24
	clr	r5
	ret
VideoModeVsync:                         ; called by the kernel in each vsync
	lds	r24, m19_video_on       ; rendering starts/stops only at frame boundaries
	sts	m19_vis, r24
	lds	r24, m19_frames
	lds	r25, m19_frames + 1
	adiw	r24, 1
	sts	m19_frames, r24
	sts	m19_frames + 1, r25
	ret
DisplayLogo:
ClearVram:
	ret
#endif
