# Stunt Car Racer for the Uzebox (video mode 19, Model S renderer) - see ../README.md
#   make KERNEL_DIR=/path/to/uzebox/kernel          -> scr.hex
#   make uze PACKROM=/path/to/packrom               -> scr.uze (the file to run)
#   options: EXTRA="-DDEBUG_STATS"  diagnostics in RAM (too big for the bootloader: emulator only)
#            EXTRA="-DAUTOPILOT"    scripted input, starts racing (emulator tests)
#            SDBASE=sdBase.o EXTRA="-DSCR_SDBASE"   SD loading without the v5 bootloader
#            TRACK=n                first track shown in the menu (0..7)
#            FLASH_LIMIT=65536      allow a build too big for the bootloader (DEBUG_STATS, emulator only)
#            FAST=0 / FASTDIV=1     rendering speed options (see below)
KERNEL_DIR ?= ../../uzebox/kernel
SRC        ?= ../port
MODELS     ?= ../modelS
# the package root: holds videoMode19/, which the kernel finds through -I$(ROOT)
ROOT       := $(abspath ..)
MCU        := atmega644
TRACK      ?= 0
GCCMAJOR := $(firstword $(subst ., ,$(shell avr-gcc -dumpversion)))
# rendering speed options:
#   FAST=1 (default)  edge lists sorted once per picture, edge setup in assembly (modelS_emit.S):
#                     rendering ~6% faster than FAST=0 (the C edge setup sorting on insertion)
#   FASTDIV=1 (default, but 0 with avr-gcc 5.x and 15+: it would not fit) the unrolled division:
#                     ~2% faster, ~320 bytes more flash
#   TRASM=1 (default) the vertex transform in assembly (modelS_transform.S): ~1% faster, ~100 bytes
#   (FAST=0, FASTDIV=0, TRASM=0: the C / compact versions - same results)
# SPIRAM=64: for a 64 KB SPI RAM (23LC512: 16-bit addresses, one byte less per transfer)
SPIRAM  ?= 128
SPIRDEF := $(if $(filter 64,$(SPIRAM)),-DSCR_SPIRAM_64K)
FAST    ?= 1
FASTDIV ?= $(if $(filter 5,$(GCCMAJOR)),0,$(if $(shell test 0$(GCCMAJOR) -ge 15 && echo 1),0,1))
TRASM   ?= 1
# flash for the game, below the bootloader (0xF000): up to 0xEFA8 - a build whose initialized data
# (copied from the end of the image at start-up) reached 0xEFB8-0xEFDA lost it on an Uzebox Omega
# (the pictures' SPI RAM addresses among it: the picture rolled); one ending at 0xEFA8 ran
# (65536: emulator-only builds)
FLASH_LIMIT ?= 61352
KOPTS  := -DVIDEO_MODE=19 -DSOUND_MIXER=0 -DINTRO_LOGO=0 -DENABLE_MIXER=0 \
          -DMIX_BANK_SIZE=96 -DMIX_END -DBGTASK -DRING_SECTION -DRESYNC -DNO_EEPROM_FORMAT=1 $(EXTRA)
KCFLAGS := -mmcu=$(MCU) -DF_CPU=28636360UL -Os -std=gnu99 -fsigned-char -ffunction-sections \
          -fno-toplevel-reorder -ffixed-r5 $(KOPTS) -I$(KERNEL_DIR) -I$(ROOT)
ASFLAGS := $(KCFLAGS) $(SPIRDEF) -x assembler-with-cpp
# code size: -fno-gcse -fno-move-loop-invariants make the AVR code ~1.2 KB smaller at the same speed;
# avr-gcc 5.x (Debian 12, Ubuntu 22.04) generates ~0.8 KB more and needs three more flags
SIZEOPT  := -fno-gcse -fno-move-loop-invariants
GCCNEW   := $(shell test 0$(GCCMAJOR) -ge 15 && echo 1)
ifeq ($(GCCMAJOR),5)
SIZEOPT  += -fno-tree-loop-optimize -fno-inline-small-functions -fno-split-wide-types
endif
# avr-gcc 15+ (16.2 tested: ~2.5% faster than 5.4; recommended): its fuse-move pass crashes
# (internal compiler error) on this code, and it needs the size flags to fit. (5.x: no longer fits)
ifeq ($(GCCNEW),1)
SIZEOPT  += -mno-fuse-move -fno-tree-loop-optimize -fno-inline-small-functions -fno-split-wide-types
endif
GOPT   := -mmcu=$(MCU) -Os -ffunction-sections -fdata-sections -flto -ffixed-r5 -mcall-prologues -mstrict-X \
          $(SIZEOPT) $(GOPT_EXTRA)
GCFLAGS := $(GOPT) -std=gnu99 $(SPIRDEF) -DTRACK=$(TRACK) $(KOPTS) -I$(KERNEL_DIR) -I$(ROOT)
GXXFLAGS := $(GOPT) -std=gnu++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics -Dlinux -DLINUX \
          -DSCR_GAME -DSCR_XRAM_OUT -DSCR_WS_EXTERN -DSCR_XRAM_ASM -DSCR_CAM3_ASM -DSCR_CAM_TRIG -DSCR_MAX_EDGES=254 $(SPIRDEF) $(if $(filter 1,$(FAST)),-DSCR_FAST_EDGES -DSCR_EMIT_ASM -DSCR_EMITCLIP_ASM) -DSCR_CLIP_ASM -DSCR_ROWS_ASM -DSCR_TRIG_ASM $(if $(filter 1,$(TRASM)),-DSCR_TRANSFORM_ASM -DSCR_CARV_ASM -DSCR_LOADROWS_ASM) $(EXTRA) -I$(SRC) -I$(MODELS) -w
KSOUND := uzeboxSoundEngine.o uzeboxSoundEngineCore.o
KOBJS := uzeboxVideoEngineCore.o uzeboxCore.o uzeboxVideoEngine.o $(KSOUND)
GXX   := Car_Behaviour Opponent_Behaviour 3D_Engine scr_track scr_math scr_io_avr harness scr_palette
# SDBASE=sdBase.o (with EXTRA=-DSCR_SDBASE in the C++ flags) adds the no-bootloader fallback
SDBASE ?=
GOBJS := scr_game.o scr_shim.o $(addsuffix .o,$(GXX)) modelS_render.o modelS_rast.o $(SDBASE) fastmath.o scr_bufs.o scr_xram.o scr_copy.o scr_cam3.o modelS_clip.o scr_rows.o scr_trig.o $(if $(filter 1,$(FAST)),modelS_emit.o modelS_emitclip.o) $(if $(filter 1,$(TRASM)),modelS_transform.o modelS_car.o modelS_loadrows.o)

scr.hex: scr.elf
	avr-objcopy -O ihex -R .eeprom $< $@
	avr-size $<
	@n=$$(avr-size $< | awk 'NR==2{print $$1+$$2}'); if [ $$n -gt $(FLASH_LIMIT) ]; then \
		echo "ERROR: $$n bytes of flash: more than the $(FLASH_LIMIT) below the bootloader"; rm -f $@; exit 1; fi
scr.elf: $(KOBJS) $(GOBJS)
	avr-g++ $(GOPT) -Wl,--gc-sections -Wl,--relax -Wl,-Map=scr.map \
		-Wl,--section-start=.ringbuf=0x800100 -Wl,--section-start=.wsbuf=0x800200 -Wl,-Tdata=0x80058C -o $@ $^
%.o: $(KERNEL_DIR)/%.s
	avr-gcc $(ASFLAGS) -c $< -o $@
%.o: $(KERNEL_DIR)/%.c
	avr-gcc $(KCFLAGS) -c $< -o $@
scr_game.o: scr_game.c
	avr-gcc $(GCFLAGS) -c $< -o $@
scr_shim.o: scr_shim.cpp
	avr-g++ $(GXXFLAGS) -c $< -o $@
%.o: $(SRC)/%.cpp
	avr-g++ $(GXXFLAGS) -c $< -o $@
modelS_render.o: $(MODELS)/modelS_render.cpp
	avr-g++ $(GXXFLAGS) -c $< -o $@
modelS_loadrows.o: $(MODELS)/modelS_loadrows.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
modelS_car.o: $(MODELS)/modelS_car.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
modelS_transform.o: $(MODELS)/modelS_transform.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
scr_trig.o: $(SRC)/scr_trig.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
scr_rows.o: $(SRC)/scr_rows.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
modelS_clip.o: $(MODELS)/modelS_clip.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
modelS_emitclip.o: $(MODELS)/modelS_emitclip.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
modelS_emit.o: $(MODELS)/modelS_emit.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
modelS_rast.o: $(MODELS)/modelS_rast.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) $(EXTRA) -x assembler-with-cpp -DRAST_TO_BUF -c $< -o $@
scr_copy.o: scr_copy.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) $(EXTRA) -x assembler-with-cpp -c $< -o $@
scr_cam3.o: $(SRC)/scr_cam3.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
scr_xram.o: $(SRC)/scr_xram.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
scr_bufs.o: scr_bufs.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
sdBase.o: $(SRC)/sdBase_scr.S
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -I$(KERNEL_DIR) -c $< -o $@
FASTMATH := $(if $(filter 1,$(FASTDIV)),fastmath_fast.S,fastmath.S)
fastmath.o: $(SRC)/$(FASTMATH)
	avr-gcc -mmcu=$(MCU) $(SPIRDEF) -x assembler-with-cpp -c $< -o $@
clean:
	rm -f *.o scr.elf scr.hex scr.map stuntcar.uze stunt64k.uze gameinfo_64k.properties

.PHONY: clean uze

# distributable ROM: make uze PACKROM=/path/to/packrom (packrom 1.6+, current Uzebox master:
# it writes the gameinfo.properties keys spiram= (64 KB banks) and sd= (SD timing hint))
PACKROM ?= packrom
# the .uze: stuntcar.uze (128 KB SPI RAM) or stunt64k.uze (SPIRAM=64)
UZE := $(if $(filter 64,$(SPIRAM)),stunt64k.uze,stuntcar.uze)
uze: scr.hex
	$(if $(filter 64,$(SPIRAM)),sed 's/^spiram=.*/spiram=1/' gameinfo.properties > gameinfo_64k.properties &&) \
	$(PACKROM) scr.hex $(UZE) $(if $(filter 64,$(SPIRAM)),gameinfo_64k.properties,gameinfo.properties)
	@# the track data at the end (the game finds it there): padding to a whole sector, SCRTRK.BIN
	n=$$(wc -c < $(UZE)); dd if=/dev/zero bs=1 count=$$(( (512 - n % 512) % 512 )) 2>/dev/null >> $(UZE)
	cat $(ROOT)/data/SCRTRK.BIN >> $(UZE)
