#!/bin/sh
# PC build vs AVR build of the race logic, bit-exact: both run the same scripted race and log a
# hash of the whole logic state every tick; the AVR build runs in the cuzebox-ex runner.
#   sh logic_pc_vs_avr.sh [TRACK] [TICKS]
# env: KERNEL_DIR (default: uzebox/kernel next to this package), RUNTEST (default ../tools/cuzebox/runtest)
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
TRACK=${1:-0}; TICKS=${2:-3000}
KERNEL_DIR=${KERNEL_DIR:-$ROOT/../uzebox/kernel}; RUNTEST=${RUNTEST:-$ROOT/tools/cuzebox/runtest}
W=$(mktemp -d); cd "$ROOT/port"
# PC (32-bit build: the logic assumes 32-bit long, as on the AVR)
for f in Car_Behaviour Opponent_Behaviour 3D_Engine scr_track scr_math scr_io_pc harness host_main; do
	g++ -m32 -O1 -std=gnu++11 -I. -w -c $f.cpp -o $W/pc_$f.o; done
g++ -m32 -o $W/scr_pc $W/pc_*.o
(cd "$ROOT/data" && $W/scr_pc $TRACK $TICKS) > $W/pc.txt
# AVR
OPT="-Os -ffunction-sections -fdata-sections -mcall-prologues -flto -fno-gcse -fno-move-loop-invariants"   # (as the game)
# avr-gcc 15+: its fuse-move pass crashes on this code (as the game's Makefile)
[ "$(avr-gcc -dumpversion | cut -d. -f1)" -ge 15 ] 2>/dev/null && OPT="$OPT -mno-fuse-move"
AVR="avr-g++ -mmcu=atmega644 $OPT -std=gnu++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics -Dlinux -DLINUX -DTRACK=$TRACK -DTICKS=$TICKS -DLOG_HASH -DSCR_SDBASE -DSCR_ROWS_ASM -DSCR_TRIG_ASM -I. -w"   # (rows, coefficients in assembly, as the game)
for f in Car_Behaviour Opponent_Behaviour scr_io_avr harness avr_main; do $AVR -c $f.cpp -o $W/avr_$f.o; done
for f in scr_track scr_math 3D_Engine; do $AVR -mno-call-prologues -c $f.cpp -o $W/avr_$f.o; done
avr-gcc -mmcu=atmega644 -x assembler-with-cpp -I"$KERNEL_DIR" -c sdBase_scr.S -o $W/avr_sdBase.o
avr-gcc -mmcu=atmega644 -x assembler-with-cpp -c scr_rows.S -o $W/avr_rows.o
avr-gcc -mmcu=atmega644 -x assembler-with-cpp -c scr_trig.S -o $W/avr_trig.o
avr-g++ -mmcu=atmega644 $OPT -Wl,--gc-sections -o $W/scr_avr.elf $W/avr_*.o
avr-objcopy -O ihex $W/scr_avr.elf $W/scr_avr.hex
cp "$ROOT/data/SCRTRK.BIN" $W/
DONE=$(avr-nm $W/scr_avr.elf | awk '$3=="done"{print substr($1,3)}')
SPIR_DUMP=$W/spir.bin "$RUNTEST" $W/scr_avr.hex $DONE $W/sram.bin | grep "done after"
dd if=$W/spir.bin of=$W/log.bin bs=65536 skip=1 2>/dev/null       # the AVR's log: SPI RAM from 64 K
python3 "$HERE/compare_hash.py" $W/pc.txt $TICKS $W/log.bin
rm -rf $W
