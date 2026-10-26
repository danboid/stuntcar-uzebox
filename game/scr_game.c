/* Stunt Car Racer for the Uzebox - main program (C: kernel side).
 *
 * Per game tick (main loop): controls -> physics -> the Model S renderer (edge lists into SPI
 * RAM) -> the Model S rasterizer (modelS_rast.S: the whole picture as run-length rows into
 * SPI RAM, double-buffered) -> publish. Per display frame, a background task inside video
 * mode 19's line interrupt (bg_task below) copies the shown picture's rows into the mode's
 * ring; it switches to a newly published picture at row 0. One tick per FRAME_GAP display
 * frames at most (the Amiga's pacing).
 * Whole program built with -ffixed-r5 (r5 belongs to the video interrupt). */
#include <avr/io.h>
#include <avr/interrupt.h>
#include <avr/pgmspace.h>
#include <string.h>
#include <uzebox.h>

#define FRAME_GAP 6
#define NROWS 110
#ifndef ASLOTS
#define ASLOTS 71                                     /* active-edge slots: the pool and the renderer's row heads after it (scr_bufs.S) */
#endif
#define BG_ROOM 32
#define STREAM_COLOURS 0
#define STREAM_MASK 128
#define STREAM_RECORDS (128 + 14)
#ifdef SCR_SPIRAM_64K
#define EDGE_STREAM 0x07000UL                         /* the renderer's output (edges, colours) */
#define XRAM_TOP    0x0FFFCUL                         /* (the presence test at boot) */
static const uint32_t pic_base[2] = {0x08000UL, 0x0C000UL};
#else
#define EDGE_STREAM 0x15000UL                         /* the renderer's output (edges, colours) */
#define XRAM_TOP    0x1FFFCUL
static const uint32_t pic_base[2] = {0x18000UL, 0x1C000UL};   /* rasterized pictures: per row
                                                     a length byte, then the row's RLE bytes */
#endif

/* ---- rasterizer state (modelS_rast.S) */
extern uint8_t pool[(ASLOTS + 1) * 9];               /* scr_bufs.S */
uint8_t rowmask[14], rs_ptr[3], free_head, rast_overflow;
uint8_t colours[128];
uint8_t istack[16];
uint8_t act_head, ring_w;
uint8_t rast_buf_w;                                   /* rasterizer output index into rast_buf */
extern uint8_t rast_buf[];                            /* 256-aligned (scr_bufs.S) */
extern uint8_t ring[];
extern void rast_row(uint8_t row);
register uint8_t r5_ring asm("r5");
extern volatile uint8_t bg_enable, spi_lock, bg_pending, bg_active, m19_video_on;

/* ---- the game (scr_shim.cpp) */
int game_init(long track);
int game_start(long track);
/* physics state (Car_Behaviour.cpp; C++ variables are not name-mangled) */
extern long new_damage, boostReserve, lapNumber[2];
extern _Bool raceFinished, raceWon;                   /* (C++ bool = C99 _Bool) */
#define SCR_HUD_MAX 12                                /* (as modelS_render.h, which is C++) */
typedef struct { uint8_t x0, x1, y0, y1, colour; } scr_rect_t;
extern scr_rect_t scr_hud[SCR_HUD_MAX];
extern uint8_t scr_hud_n;
void game_tick(unsigned int input);
void game_render(uint32_t stream);
extern uint8_t scr_draw_limit, scr_overflow;
extern uint8_t scr_mute;                              /* sound off (SELECT); the renderer shows a symbol */
uint16_t game_engine_hz(void);
unsigned int game_autopilot(void);

static volatile uint8_t front = 0xFF, pending = 0xFF;  /* picture shown / published */
static uint8_t cp_row;                                 /* copy task: next row */
static uint32_t cp_ptr;                                /* copy task: its position in the picture */
#ifdef DEBUG_STATS
volatile uint16_t frames_rastered, ticks_done, late_ticks;
#define COUNT(v) ((v)++)
#else
#define COUNT(v) ((void)0)
#endif
#ifdef DEBUG_STATS
volatile uint8_t boot_stage;
#define STAGE(n) (boot_stage = (n))
#define PHASE(n) (run_phase = (n))
#else
#define STAGE(n) ((void)0)
#define PHASE(n) ((void)0)
#endif
#ifdef DEBUG_STATS
volatile uint8_t run_phase;
#endif                           /* 1 physics, 2 rendering, 4 rasterizing, 3 boot */
volatile uint8_t render_frames;

static uint8_t spi(uint8_t b) { SPDR = b; while (!(SPSR & (1 << SPIF))); return SPDR; }
static void xbegin(uint8_t cmd, uint32_t a)
{
	PORTA &= ~(1 << PA4);
	spi(cmd);
#ifndef SCR_SPIRAM_64K
	spi((uint8_t)(a >> 16));                               /* (64 KB chips take 16-bit addresses) */
#endif
	spi((uint8_t)(a >> 8)); spi((uint8_t)a);
}
static void xend(void) { PORTA |= (1 << PA4); }
void spi_unlock(void);
/* main program: SPI RAM access under the lock */
/* main-program transfers: scr_xram.S's (the bus held per chunk of at most 32 bytes, the copy
 * task, which feeds the video mode, run as soon as it is free again) */
void xram_read(uint32_t addr, void *dst, uint16_t n);
void xram_write(uint32_t addr, const void *src, uint16_t n);
#define lread(a, d, n) xram_read((a), (d), (n))
#define lwrite(a, d, n) xram_write((a), (d), (n))

/* background task: called from the line interrupt (or spi_unlock) with interrupts enabled.
 * Copies the rows of the picture being shown from SPI RAM into the ring, one complete row
 * at a time, while there is room. At row 0 it switches to a newly published picture and
 * publishes where row 0 starts in the ring (the mode resyncs there at each frame start). */
extern volatile uint8_t frame_start_w, frame_start_valid, rast_abort;
static volatile uint8_t err_colour;                    /* boot failure: a solid screen of this */
uint8_t scr_copy_row(uint8_t w, uint8_t n);           /* scr_copy.S */
void bg_task(void)
{
	uint8_t open = 0;            /* rows lie one after another in SPI RAM: within one run of the task
	                              * the read stays open across rows (no command and address per row) */
	for (;;) {
		uint8_t n, w, room;
		if (err_colour) {                              /* (needs no SPI RAM) */
			if (open) { xend(); open = 0; }
			if ((uint8_t)(ring_w - r5_ring) > 254 - 6) return;
			w = ring_w;
			ring[w++] = err_colour; ring[w++] = 126 << 1;   /* 128 + 128 pixels, end of line */
			ring[w++] = err_colour; ring[w++] = 126 << 1;
			ring[w++] = 1; ring[w++] = 0xFE;
			if (cp_row == 0) { frame_start_w = ring_w; frame_start_valid = 1; }
			ring_w = w;
			m19_video_on = 1;
			if (++cp_row == NROWS) cp_row = 0;
			continue;
		}
		if (rast_abort) { rast_abort = 0; cp_row = 0; }  /* the mode is resyncing */
		if (cp_row == 0) {
			if (open) { xend(); open = 0; }            /* (a new picture: another address) */
			if (pending != front) front = pending;
			cp_ptr = pic_base[front];
			frame_start_w = ring_w;
			frame_start_valid = 1;
		}
		room = (uint8_t)(254 - (uint8_t)(ring_w - r5_ring));
		if (!open) { xbegin(3, cp_ptr); open = 1; }
		n = spi(0xFF);                                 /* the row's length */
		if (n > room) { xend(); return; }              /* not enough room yet (re-read next time) */
		w = scr_copy_row(ring_w, n);                   /* (scr_copy.S: at the bus's pace) */
		ring_w = w;                                    /* publish the complete row */
		cp_ptr += 1 + n;
		m19_video_on = 1;
		if (++cp_row == NROWS) { cp_row = 0; COUNT(frames_rastered); }
	}
}

/* rasterize the picture in EDGE_STREAM into pic_base[buf] (main program, once per picture) */
static void rast_reset(void)
{
	for (uint8_t s = 1; s < ASLOTS; s++) pool[9 * s] = s + 1;
	pool[9 * ASLOTS] = 0;
	free_head = 1; act_head = 0;
}
static void __attribute__((noinline)) rasterize_picture(uint8_t buf)
{
	uint32_t w = pic_base[buf], p = EDGE_STREAM + STREAM_RECORDS;
	lread(EDGE_STREAM + STREAM_COLOURS, colours, 128);
	lread(EDGE_STREAM + STREAM_MASK, rowmask, 14);
	rs_ptr[0] = (uint8_t)p; rs_ptr[1] = (uint8_t)(p >> 8); rs_ptr[2] = (uint8_t)(p >> 16);
	rast_reset();
	for (uint8_t r = 0; r < NROWS; r++) {
		rast_buf_w = 0;
		rast_row(r);
		uint8_t n = rast_buf_w;
		lwrite(w, &n, 1);
		lwrite(w + 1, rast_buf, n);
		w += 1 + n;
	}
}

/* release the SPI bus; run the task now if the line interrupt wanted it meanwhile (no cli:
 * a task started by the interrupt always finishes before this code continues) */
void spi_unlock(void)
{
	spi_lock = 0;
	if (!bg_pending) return;
	bg_pending = 0;
	if (bg_active || !bg_enable) return;
	bg_active = 1;
	bg_task();
	bg_active = 0;
}

/* ---- sound: one waveform loop of whole periods in the 256-byte sample buffer */
extern uint8_t mix_buf[];
extern uint8_t *volatile mix_end;
extern volatile uint8_t mix_len;
#define SND_BUF 192                                  /* MIX_BANK_SIZE 96 x 2: lowest note 15734/148 = 106 Hz */
#define LINE_HZ 15734UL
static uint16_t snd_hz;
static void __attribute__((noinline)) sound_tone(uint16_t hz, uint8_t vol)
{
	uint16_t step, ph = 0, i, len;
	uint8_t k;
	if (hz < 107) hz = 107;
	if (hz == snd_hz) return;
	snd_hz = hz;
	k = (uint8_t)(((uint32_t)hz * (SND_BUF - 44)) / LINE_HZ);
	if (k == 0) k = 1;
	len = (uint16_t)(((uint32_t)k * LINE_HZ + hz / 2) / hz);
	if (len > SND_BUF - 44) len = SND_BUF - 44;
	step = (uint16_t)(((uint32_t)k << 16) / len);
	for (i = 0; i < SND_BUF; i++, ph += step)
		mix_buf[i] = 128 + (int8_t)(((int16_t)(int8_t)((ph >> 8) - 128) * vol) >> 8);
	mix_len = (uint8_t)len;
	mix_end = mix_buf + len;
}

/* ---- sound effects (Grounded, OffRoad, Wreck, Smash, Creak, HitCar): a noise loop instead
 * of the engine tone for a few ticks; "grain" = samples each random value is held (low = hiss,
 * high = rumble). Own generator: the game's rand() sequence stays the physics' alone. */
volatile uint8_t sfx_req;                            /* effect + 1, set by the physics (scr_shim.cpp) */
static const uint8_t sfx_tab[6][2] = {{8, 1}, {6, 1}, {2, 6}, {1, 3}, {12, 1}, {3, 2}};   /* grain, ticks */
static uint8_t sfx_left, sfx_grain, sfx_rng = 1;
static void __attribute__((noinline)) sound_update(void)
{
	uint8_t r = sfx_req;
	if (r) { sfx_req = 0; sfx_grain = sfx_tab[r - 1][0]; sfx_left = sfx_tab[r - 1][1]; }
	if (!sfx_left) { sound_tone(game_engine_hz(), 160); return; }
	sfx_left--;
	snd_hz = 0;                                      /* (the engine tone is rebuilt afterwards) */
	uint8_t v = 128, g = 0;
	for (uint8_t i = 0; i < SND_BUF; i++) {
		if (!g--) {
			g = sfx_grain - 1;
			sfx_rng ^= sfx_rng << 3; sfx_rng ^= sfx_rng >> 5; sfx_rng ^= sfx_rng << 1;   /* xorshift */
			v = 64 + (sfx_rng & 0x7F);
		}
		mix_buf[i] = v;
	}
	mix_len = SND_BUF;
	mix_end = mix_buf + SND_BUF;
}

/* the rasterizer holds 47 active edges per row: when a picture lost edges (rast_overflow
 * counts them; a region left open shows as a bar to the right edge), the next ones draw 6
 * fewer of the farthest pieces - the crowded horizon - and recover one at a time later */
/* after each picture: the draw limit - 6 fewer far pieces after the renderer or the rasterizer ran
 * out of room, then one more every 8 pictures; and the rasterizer's budget of pixels in short runs
 * per row (modelS_rast.S, emitb) - full detail while the video mode keeps up, after a picture with
 * underruns 64 (no underruns on 150 views of Roller Coaster's busiest stretch) or, if already
 * there, 32, after 64 pictures without 8 more */
uint8_t scr_short_budget = 254;
extern volatile uint16_t m19_underruns;
static void __attribute__((noinline)) draw_limit_adapt(void)
{
	static uint8_t seen, calm, useen, ucalm;
	uint8_t u = (uint8_t)m19_underruns;
	if (rast_overflow != seen || (scr_overflow & 3)) {     /* (the renderer ran out of edges or regions) */
		seen = rast_overflow;
		calm = 0;
		if (scr_draw_limit > 12) scr_draw_limit -= 6;
	} else if (++calm >= 24) {
		calm = 16;                                     /* then one more every 8 pictures */
		if (scr_draw_limit < 48) scr_draw_limit++;
	}
	if (u != useen) {
		useen = u; ucalm = 0;
		scr_short_budget = scr_short_budget > 64 ? 64 : 32;
	} else if (++ucalm >= 64) {
		ucalm = 0;
		if (scr_short_budget < 246) scr_short_budget += 8;
	}
}

/* the menu and the result screen are silent: no engine, no effect (snd_hz 1: never a tone, sound_tone() clamps to 107) */
static void __attribute__((noinline)) sound_silence(void)
{
	if (snd_hz == 1) return;
	snd_hz = 1;
	sfx_left = 0; sfx_req = 0;
	for (uint8_t i = 0; i < SND_BUF; i++) mix_buf[i] = 128;
	mix_len = SND_BUF;
	mix_end = mix_buf + SND_BUF;
}

/* buttons pressed since the last game tick, latched once per frame (a loop iteration takes
 * several frames: quick taps would otherwise be missed) */
static volatile uint8_t pad_latch;                    /* (START, LEFT, RIGHT are in the low byte) */
static void pad_cb(void) { pad_latch |= (uint8_t)ReadJoypad(0); }

/* ---- HUD: a few rectangles in front of the scene (two edges each) */
enum { STATE_MENU, STATE_RACE, STATE_OVER };
#define C_RED    0x06
#define C_YELLOW 0x3E
static uint8_t paused;                                /* the race is paused (START) */
#define C_WHITE  0xFE
#define C_BROWN  0x15                                 /* (182, 72, 0): the track select squares, against the sky */
#define C_VIOLET 0xC5                                 /* (182, 0, 255): the lap markers, against the road */
#define C_GREEN  0x38
static void hud_rect(uint8_t x0, uint8_t x1, uint8_t y0, uint8_t y1, uint8_t c)
{
	if (x1 < x0 || scr_hud_n >= SCR_HUD_MAX) return;
	scr_rect_t *r = &scr_hud[scr_hud_n++];
	r->x0 = x0; r->x1 = x1; r->y0 = y0; r->y1 = y1; r->colour = c;
}
static void __attribute__((noinline)) build_hud(uint8_t state, uint8_t track)
{
	uint8_t i;
	long v;
	scr_hud_n = 0;
	if (state == STATE_MENU) {                             /* track number: 1..8 squares */
		for (i = 0; i <= track; i++) hud_rect(96 + i * 8, 101 + i * 8, 4, 7, C_BROWN);
		return;
	}
	v = new_damage >> 1; if (v > 120) v = 120;             /* damage: red bar, top left */
	if (v) hud_rect(4, 3 + (uint8_t)v, 2, 3, C_RED);
	v = boostReserve; if (v > 120) v = 120;                /* boost: yellow bar, top right */
	if (v) hud_rect(252 - (uint8_t)v, 251, 2, 3, C_YELLOW);
	for (i = 0; i < 3 && i < lapNumber[1]; i++)            /* laps begun: violet squares, bottom left */
		hud_rect(4 + i * 8, 9 + i * 8, 104, 107, C_VIOLET);
	if (state == STATE_OVER)                               /* result: green won, red lost */
		hud_rect(96, 159, 40, 69, raceWon ? C_GREEN : C_RED);
	if (state == STATE_RACE && paused) {                  /* paused: two white bars, mid-screen */
		hud_rect(119, 124, 46, 62, C_WHITE);
		hud_rect(131, 136, 46, 62, C_WHITE);
	}
}

static unsigned int __attribute__((noinline)) controls(unsigned int j)
{
#ifdef AUTOPILOT
	(void)j;
	return game_autopilot();
#else
	unsigned int in = 0;
	if (j & BTN_LEFT) in |= 0x01;
	if (j & BTN_RIGHT) in |= 0x02;
	if (j & (BTN_B | BTN_UP)) in |= 0x04;                /* accelerate */
	if (j & (BTN_Y | BTN_DOWN)) in |= 0x08;              /* brake */
	if (j & BTN_A) in |= 0x10;                           /* boost */
	return in;
#endif
}

#ifdef DEBUG_STATS
/* stack painting: free RAM filled with 0xA5 at boot; stack_free() counts the bytes never used */
extern uint8_t __bss_end;
static void __attribute__((naked, used, section(".init3"))) paint_stack(void)
{
	uint8_t *p = &__bss_end;
	while (p < (uint8_t *)SP - 16) *p++ = 0xA5;
}
volatile uint16_t stack_unused;
static void __attribute__((noinline)) stack_free(void)
{
	uint8_t *p = &__bss_end;
	uint16_t n = 0;
	while (*p == 0xA5 && p < (uint8_t *)SP) { p++; n++; }
	stack_unused = n;
}

#endif

int main(void)
{
	uint8_t back, track = TRACK, over = 0;
#ifdef AUTOPILOT
	uint8_t state = STATE_RACE;
#else
	uint8_t state = STATE_MENU;
#endif
	unsigned int pad_prev = 0;
	uint16_t next;
	PORTA |= (1 << PA4); DDRA |= (1 << PA4);           /* SPI RAM chip select */
	DDRB |= (1 << PB7) | (1 << PB5) | (1 << PB4);
	SPCR = (1 << SPE) | (1 << MSTR); SPSR = (1 << SPI2X);
	STAGE(1);
	sound_tone(100, 0);
	STAGE(2);
	PHASE(3);
#ifdef LOAD_CLI
	cli();
#endif
	{	/* SPI RAM present? (write, read back) - else a blue screen; no SD data: red */
		static const uint8_t pat[4] = {0x5A, 0xC3, 0x0F, 0xA5};
		uint8_t back[4];
		lwrite(XRAM_TOP, pat, 4);
		lread(XRAM_TOP, back, 4);
		uint8_t fail = (back[0] != 0x5A || back[1] != 0xC3 || back[2] != 0x0F || back[3] != 0xA5) ? 0xC0
		             : !game_init(TRACK) ? 0x07 : 0;
		if (fail) {
			err_colour = fail;
			bg_enable = 1;
			for (;;) ;
		}
	}   /* SD card -> SPI RAM, start the race */
#ifdef LOAD_CLI
	sei();
#endif
	PHASE(0);
	STAGE(3);
#ifndef AUTOPILOT
	game_start(track);   /* menu view: the start line */
#endif
	SetUserPostVsyncCallback(pad_cb);
	ring_w = 0;
	game_render(EDGE_STREAM);
	rasterize_picture(0);
	STAGE(4);
	pending = 0;
	back = 1;
	bg_enable = 1;
	STAGE(5);
	next = GetVsyncCounter();
	for (;;) {
		while ((int16_t)(GetVsyncCounter() - next) < 0) ;
		if ((int16_t)(GetVsyncCounter() - next) >= FRAME_GAP) { next = GetVsyncCounter(); COUNT(late_ticks); }
		next += FRAME_GAP;
		{
			unsigned int pad = ReadJoypad(0), press;
			uint8_t l;
			cli(); l = pad_latch; pad_latch = 0; sei();   /* (two instructions with interrupts off) */
			press = (pad | l) & ~pad_prev;
			pad_prev = pad;
			if (press & BTN_SELECT) scr_mute ^= 1;         /* sound on / off, anywhere */
			if (state == STATE_MENU) {                     /* choose a track, start */
				if (press & (BTN_RIGHT | BTN_LEFT)) {
					track = (track + ((press & BTN_RIGHT) ? 1 : 7)) & 7;
					game_start(track);
				}
				if (press & BTN_START) { state = STATE_RACE; paused = 0; }
			} else if (state == STATE_RACE) {
				if (press & BTN_START) paused ^= 1;             /* pause / resume */
				if (!paused) {
					PHASE(1);
					game_tick(controls(pad));
					PHASE(0);
					if (raceFinished) { state = STATE_OVER; over = 0; }
				}
			} else if (++over >= 30) {                     /* result shown ~4 s */
				game_start(track);
				state = STATE_MENU;
			}
			build_hud(state, track);
		}
		STAGE(6);
		COUNT(ticks_done);
		if (state != STATE_RACE || scr_mute || paused) sound_silence(); else sound_update();   /* menu, result, muted, paused: silent */
		while (front != pending) ;                     /* the copy task took the last picture */
		PHASE(2);
		game_render(EDGE_STREAM);
		PHASE(4);
		rasterize_picture(back);
		draw_limit_adapt();
		PHASE(0);
		pending = back;
		back ^= 1;
		render_frames++;
#ifdef DEBUG_STATS
		stack_free();
#endif
	}
}
