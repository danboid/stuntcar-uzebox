# Stunt Car Racer for the Uzebox

A port of the race logic of [*Stunt Car Racer Remake*](https://github.com/ptitSeb/stuntcarremake) (the PC remake of Geoff Crammond's
1989 game by ptitSeb) to the Uzebox by Dan MacDonald with the assistance of Claude Opus 5.5.

<img src="Stunt_Car_Racer_Uzebox.png" alt="Stunt Car Racer cuzebox-ex screenshot" />

SCR is made possible on the Uzebox by two new components introduced by this game:

* **Uzebox video mode 19** (`videoMode19/`) - run-length-encoded scanlines: 256 x 110 pixels,
  256 colours, the CPU free during long runs. It's called 19 because S is the 19th letter of the 
  alphabet and the first letter of both Stunt Car Racer and Sega. It was initially inspired by 
  CunningFellow's RLE video mode.
  
* **Model S** (`modelS/`) - the polygon renderer and the scanline rasterizer that feed mode 19,
  named in tribute to Sega's Model series of arcade hardware which began with Model 1 and
  Virtua Racing. 
  
## Requirements

Requires a Uzebox with at least **64 KB SPI RAM** and the **Uzebox bootloader 5.0.06 or later**

### 128 KB or 64 KB SPI RAM?

The two chips are addressed differently: the 128 KB 23LC1024 takes a 24-bit address after each
command, the 64 KB 23LC512 a 16-bit one. A build sends one or the other on every transfer, and
its SPI RAM layout must fit the chip, so each size needs its own build. 128 KB is the default,
as most Uzeboxes have it; `SPIRAM=64` makes the 64 KB one.

The game itself needs only 64 KB (track data 21 KB, edge slots 4 KB, the edge stream, two
pictures of 16 KB). On a 64 KB chip every transfer is one byte shorter - the renderer, the
rasterizer and the video copy task make thousands per picture - so the 64 KB build runs about
**4% faster** (in cuzebox-ex: 6.92 instead of 7.20 display frames per game tick; rendering a
picture 1.8% faster). Its pictures are identical. Which build to use is decided by the chip in
the Uzebox: a build for the other size does not run (in cuzebox-ex the `.uze` header's
`spiram=` sets the chip).

You should be able to run the 128 KB build on Uzeboxes with more SPI RAM when that becomes an option.

## Running

Copy `scr.uze` or `scr_64k.uze` and `data/SCRTRK.BIN` to the root of your Uzebox SD card or load
one of these files in [**cuzebox-ex**.](https://github.com/weber21w/cuzebox-ex)

## Controls

* Left and right cursor keys = dpad (steering)
* Enter = Start (Start / pause / resume race)
* A = B button (accelerate) 
* Q = Y button (brake)
* S = A button (boost)
* Space = Select (mute sound)

## Game interface

When you start the game you are presented with the track selection screen.
Pushing left or right chooses the track, their number is indicated by the row of brown squares
displayed on the track selection screen. One brown square = track #1 etc.

* In game HUD: red bar = damage, yellow bar = boost, violet squares = laps begun.

* When the race is over you will see a large green (won) or red (lost) square before you are
  returned to the track selection screen.
  
* Start-up failures: solid **blue** screen = the SPI RAM failed a write/read test; solid **red**
  screen = SD card / FAT / `SCRTRK.BIN` / bootloader problem.

## Building

Building SCR requires avr-gcc 7.3 or later; 16.2 is recommended.

```sh
# 1. Prepare the Uzebox kernel with the patch (registers video mode 19; sound buffer size)
git clone https://github.com/Uzebox/uzebox.git
cd uzebox && git checkout 384ceb3 && git apply ../scr_uzebox/kernel/uzebox_kernel.patch && cd ..

# 2. Build packrom (packs the .hex into a .uze): version 1.6 or later
#    (the kernel above stays at 384ceb3)
git -C uzebox show origin/master:tools/packrom/packrom.cpp > packrom.cpp
g++ -O2 -o packrom packrom.cpp

# 3. Build the game (128 KB SPI RAM version)
cd stuntcar-uzebox/game
make KERNEL_DIR=../../uzebox/kernel                     # -> scr.hex
make uze KERNEL_DIR=../../uzebox/kernel PACKROM=../../packrom   # -> scr.uze

# or build the 64 KB SPI RAM version
make clean
make SPIRAM=64 KERNEL_DIR=../../uzebox/kernel
make uze SPIRAM=64 KERNEL_DIR=../../uzebox/kernel PACKROM=../../packrom
```

`KERNEL_DIR` defaults to `../../uzebox/kernel`: in the layout above, `uzebox/` is next to 
`stuntcar-uzebox/`. The game builds with `-DVIDEO_MODE=19`; the kernel finds `videoMode19/` 
through the include path (`-I` the package root), so nothing has to be copied into the kernel 
tree.

## Build options (`make ... EXTRA="..."`)

| | |
|---|---|
| `TRACK=n` | the track first shown in the menu (0..7) |
| `EXTRA=-DAUTOPILOT` | scripted input, starts racing (emulator tests) |
| `EXTRA=-DDEBUG_STATS FLASH_LIMIT=65536` | boot stage, phase, counters and stack painting in RAM (too large for the bootloader: emulator only) |
| `SPIRAM=64` | the build for a 64 KB SPI RAM (23LC512), ~4% faster (see "128 KB or 64 KB SPI RAM") |
| `FAST=0` | the C edge setup that sorts on insertion (default `FAST=1`: edge lists sorted once per picture, edge setup in assembly) |
| `FASTDIV=0` | the compact (loop) 32/16 division instead of the unrolled one (~320 bytes less, ~2% slower) |
| `TRASM=0` | the vertex transform in C (~100 bytes larger, ~1% slower) |
| `SDBASE=sdBase.o EXTRA=-DSCR_SDBASE` | SD loading without the v5 bootloader (standard-capacity FAT16 cards; plain emulator runs) |

## Repository contents

| Folder | |
|---|---|
| `game/` | the main program (C), the C++ glue, fixed-address buffers, the copy task's row loop (`scr_copy.S`), Makefile, `gameinfo.properties` |
| `videoMode19/` | Uzebox video mode 19 (`videoMode19.s`, `.h`, `.def.h`), in the kernel's layout |
| `modelS/` | Model S: `modelS_render.cpp/.h` (polygon renderer), `modelS_rast.S` (rasterizer), and in assembly `modelS_emit.S` (edge setup), `modelS_clip.S` (clipping), `modelS_emitclip.S` (clipped polygons to edges), `modelS_transform.S` (vertex transform), `modelS_loadrows.S` (track rows to the screen), `modelS_car.S` (the opponent's car) |
| `port/` | the remake's race logic (ported to integer arithmetic), track module, I/O, assembly helpers |
| `data/` | `SCRTRK.BIN` (track data for the SD card), its generator and sources |
| `kernel/uzebox_kernel.patch` | registers video mode 19 in the kernel's `defines.h`, and lets a game size the sound buffer |
| `tests/` | PC-vs-AVR logic test; `reference/`: comparison with the original remake |
| `tools/cuzebox/` | cycle-level test runners for cuzebox-ex (`runtest`, `prof`) |
| `tools/api/` | a client for the cuzebox-ex TCP API and a scripted driver |

## How it works

Per game tick (main program): controls -> physics (the remake's logic) -> Model S renderer
(edge lists into SPI RAM) -> Model S rasterizer (the whole picture as run-length rows into SPI
RAM, double-buffered).
Per display frame (background task in video mode 19's line interrupt): the shown picture's
rows are copied from SPI RAM into the 256-byte ring that mode 19 plays out, 256 x 110 pixels
(each row shown on two scanlines), 256 colours. Mode 19 resynchronises at every frame start.

Internal RAM (4 KB): ring 0x100, Model S workspace 0x200 (688 bytes, shared in turn by the
renderer, the rasterizer's edge pool and output row, and the SD loader), the renderer's row heads
0x4B0 (220 bytes, also the rasterizer's extra edge slots), data/bss from 0x58C, ~850 bytes of
stack. SPI RAM (128 KB build): track data 0x00000, edge slots 0x14000, edge stream 0x15000,
pictures 0x18000 / 0x1C000; 64 KB build: 0x0000, 0x6000, 0x7000, 0x8000 / 0xC000.

Sound: the engine note is a sawtooth loop written into the kernel's sample buffer; the remake's
effects (Grounded, OffRoad, Wreck, Smash, Creak, HitCar) replace it with noise loops for a few
ticks (one voice).

The crane comes when the car is stuck in front of a wall - a steep segment the road climbs,
in this piece or the next three: in one of Stepping Stones' or Draw Bridge's pits, or Big Ramp's
gaps (ramp, steep drop, road on the ground, steep wall up to the landing). Stuck: on the road,
the player holding accelerate or brake for about six seconds without the car reaching a new
piece - against the wall or bouncing off it. It then puts the car past the wall (never across
the finish line). The pieces with such a wall are recognized by their height profiles
(scr_track.cpp, wall_ids); away from them - sliding back down a steep climb, reversing for a
run-up - only the original's rules apply, and falling off the road gets the original's crane, on
the same piece (or the one after a pit).

Piece limits: at most 48 visible pieces are drawn - the nearest (the culling pass meets pieces in
track order, and used to drop the newest: on a track's second half, Roller Coaster's banked right
turn, the road under the car went missing). When the renderer runs out of regions (128) or edge
slots (440), or the rasterizer of active-edge slots (71), the next pictures draw fewer of the
farthest pieces, and recover them one by one.

Keeping video mode 19 fed: a copy task (bg_task, in the line interrupt) moves the finished
picture's rows from SPI RAM into the mode's 256-byte ring. If it falls behind, the mode shows
black lines (underruns) - on busy views, such as Roller Coaster's banked corners, it used to.
Now: the copy task reads consecutive rows in one SPI transaction, at the bus's pace
(game/scr_copy.S); every other SPI transfer holds the bus for at most 32 bytes (or one edge, in
the rasterizer), and a copy task that waited for the bus runs as soon as it is free; and a row
keeps at most scr_short_budget pixels in runs shorter than 28 - which the mode draws inside its
interrupt - beyond that, short runs are merged into blocks of 28 (modelS_rast.S, emitb). The
budget adapts full detail (254) while the mode keeps up; after a picture with underruns 64, which 
kept 150 views around those corners free of them; then 8 more after every 64 pictures without. 
So a striped wall keeps its stripes (the track 8 preview in the menu), and entering a really busy 
stretch costs one picture with a few black lines.

The rasterizer keeps up to 71 edges active in a row: 48 slots in the shared workspace plus 24 in
the renderer's row heads (`scr_bucket`, 220 bytes), placed right after them in `scr_bufs.S` - free
while a picture is rasterized. If a picture still needs more (`rast_overflow` counts dropped
edges; an unclosed region would show as a bar to the right edge), the next pictures draw 6 fewer
of the farthest track pieces and recover one at a time.

Assembly routines run in the main program alongside video mode 19's interrupt: they must never
use r5 (the whole program is built with `-ffixed-r5`; saving and restoring it is not enough).
Their internal labels are assembler-local (`.L...`): only the entry points are symbols (the test
scripts find variables such as `done` by name).

In assembly, each bit-identical to the C it replaces (kept, and selectable, for the PC builds and
the tests): edge setup (`modelS_emit.S`), clipping (`modelS_clip.S`, `modelS_emitclip.S`), the vertex transform
(`modelS_transform.S`), loading a chunk of rows (`modelS_loadrows.S`), the track rows
(`port/scr_rows.S`) and the rotation coefficients (`port/scr_trig.S`) - both used by the renderer
and the physics - plus the camera transform, divisions and SPI RAM transfers. Rendering a picture
went from 1.48 M to 1.22 M cycles (the game path, without the opponent).
`scr_vtx` is 11 bytes on the AVR (no padding): the assembly steps through its arrays that way.

**The opponent's car** is the remake's model (Car.cpp): a tapered body of six faces and four
wheels, 24 points, in the remake's colours, oriented by the opponent's three angles as the remake
places it (Rz Rx Ry, using the physics' own CalcYXZTrigCoefficients, whose coefficients are kept),
with back faces culled and the wheels drawn behind or in front of the body by depth. It costs ~4-5%
of the tick rate while the opponent is on screen. `EXTRA=-DSCR_OPP_RECT` draws the old rectangle.

The game is compiled with
`-fno-gcse -fno-move-loop-invariants`, which make the AVR code ~1.2 KB smaller at the same speed.

packrom takes the `.uze` header from `gameinfo.properties`, including `spiram=2` (the SPI RAM
size in 64 KB banks) and `sd=fast` (the SD timing hint). For a `SPIRAM=64` build the Makefile
passes it a copy with `spiram=1`.

## Tests

```sh
cd tests
# PC and AVR builds of the race logic, bit-exact (needs tools/cuzebox/runtest, see below)
sh logic_pc_vs_avr.sh 0 3000        # -> "ticks 3000: first mismatch none, mismatching 0; ..."
sh rows_c_vs_asm.sh                 # -> "track n: ... corners, differing 0" (track rows: C vs scr_rows.S)

# the port vs the ORIGINAL remake's logic, tick for tick, all 8 tracks
cd reference
sh build_reference.sh               # clones the remake at commit 9f0f8e6, builds it headless
sh compare_with_original.sh 3000    # -> "track n: 3000 ticks, first difference: none"
```

`compare_with_original.sh` builds the port with `SCR_EXACT_SIN` and `SCR_EXACT_CURVE` (the
remake's sine table and its double-precision curve maths). The game itself keeps integer
versions of these (a smaller sine table with interpolation, integer atan/sqrt), which differ by
rounding and make the races drift apart slowly; everything else is identical.

The test runners: `sh tools/cuzebox/build.sh /path/to/cuzebox-ex-checkout` applies a small
profiling hook, builds cuzebox-ex headless and links `runtest` and `prof` (details in
`tools/cuzebox/README.txt`: `prof` records every instruction, video line and sound sample).

## Regenerating the track data

`data/SCRTRK.BIN` and `port/scr_trackdata.h` come from `data/gen_trackdata.py`:

```sh
cd data && python3 gen_trackdata.py source/orig_tracks.json source/Tracks
```

`source/orig_tracks.json` is dumped from the remake (`tests/reference/build/scr_dump`);
`source/Tracks/*.bin` are the remake's track files. Both regenerate byte-identically.

## Known limitations

* One sound voice: during an effect the engine note is silent.
* Flash: 280 bytes free with avr-gcc 7.3.0, 62 bytes free with avr-gcc 16.2 (below the 61,352-byte limit).
* About 7-8 display frames per game tick while racing (the Amiga version ran at 6). Rendering a
  picture takes ~1.22 M cycles (game path), plus the opponent's car when it is in view.
  
## Credits and licensing

* *Stunt Car Racer*: Geoff Crammond / MicroStyle (1989). The track files in
  `data/source/Tracks` and the data derived from them are from the original game.
* The race logic in `port/` (`Car_Behaviour.cpp`, `Opponent_Behaviour.cpp`, `3D_Engine.cpp`,
  `Track` data handling) is derived from the *Stunt Car Racer Remake* source as published at
  https://github.com/ptitSeb/stuntcarremake (commit 9f0f8e6), as are the reference files in
  `tests/reference/src`.
* The Uzebox kernel and the original code in this game are licensed under the GNU GPL v3.0.
