Cycle-level test runners on cuzebox-ex (headless build; the profiling hook is made for commit
bd55361 of 26 October 2026 - if a later version changed the code it patches, build.sh stops with
a message)

prof GAME.hex SKIP FRAMES PREFIX   runs SKIP frames, then records FRAMES frames:
    PREFIX.trace  every instruction (pc, cycles, IT vector, IT entry cycles)
    PREFIX.video  every video row (2032 pixels per line, cycle-exact)
    PREFIX.audio  the sound output register, once per line
    PREFIX.sram   SRAM at the end
  stderr: deepest stack pointer (sampled only after push/call/out SPL/IT entry, so frame
  prologues do not count), per-phase depth (PHASE=addr of a phase byte in RAM; also
  writes pc_minsp.bin), overflow-interrupt latency histogram (TOV1 rise -> IT entry),
  WATCH=addr reports writers of a RAM byte, CROSS=sp reports a backtrace when the stack
  first goes below sp, ISLATE=word address of is_late prints the timer state at late
  entries, SPIR_DUMP=file dumps the SPI RAM.
runtest GAME.hex DONE_ADDR SRAM_DUMP   runs until RAM[DONE_ADDR] == 0xA5 (RT_LIMIT=chunks
  to stop earlier: SRAM and SPI RAM are dumped on timeout too), SPIR_DUMP as above.
Both install a 128 KB SPI RAM (cu_spir_set_size(2), as the cuzebox-ex front end does - the
emulator core has none by default); SPIR_BANKS=1 installs a 64 KB one (for SPIRAM=64 builds) and point the emulated SD card at the program's folder.

What moving to the current cuzebox-ex changed (all found by tests that passed before):
  - SPI RAM must be installed explicitly by a runner (see above).
  - Interrupt entry is ~2 cycles faster than on the older cuzebox: video mode 19's latency
    window was calibrated at 15..22 (TCNT1L in the prologue); entries now read 13..19, so
    the fastest were "early" (counted as late, output 1-2 cycles early). The window is now
    LAT_MIN 13, SLED 10 (13..22: both emulators), same total latency, nothing else moves.
  - The sync-fall handler was too long for the sync-rise event 136 cycles later once the
    sample routine grew (variable loop end): SND_PAD 12 -> 0 (the kernel's sample offset;
    a 12-cycle shift is inaudible).
  - SD card start-up: sdBase_scr.S polled CMD1 2048 times; with SPI2X left set by the game
    that is ~0.5 s, the emulated card's start-up time: now 8192 polls (real cards can take
    up to ~1 s anyway).
  - SPSR/SPIF now behave as on hardware (cleared by reading SPSR, then accessing SPDR):
    all SPI code here already does write SPDR -> poll SPSR -> read SPDR.
Results on the current cuzebox-ex: SPI rasterizer 16/16 frames identical to the model; the
GROG kernel test pixel-exact with 0 late entries and 0 underruns (also on the old cuzebox);
the game: 0 late entries (was ~650 per frame), boots from the SD card, races.
