#!/bin/sh
# Every row of every piece of every track: the C row generator (PC) against the assembly one
# (scr_rows.S, AVR in the cuzebox-ex runner), corner by corner.
#   sh rows_c_vs_asm.sh          env: KERNEL_DIR, RUNTEST as logic_pc_vs_avr.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
KERNEL_DIR=${KERNEL_DIR:-$ROOT/../uzebox/kernel}; RUNTEST=${RUNTEST:-$ROOT/tools/cuzebox/runtest}
W=$(mktemp -d); cd "$ROOT/port"; cp "$HERE/rows_dump.cpp" $W/
for t in 0 1 2 3 4 5 6 7; do
	g++ -m32 -O1 -std=gnu++11 -I. -w -DTRK=$t -o $W/pc $W/rows_dump.cpp scr_track.cpp scr_math.cpp scr_io_pc.cpp 3D_Engine.cpp
	(cd "$ROOT/data" && $W/pc) > $W/pc.txt
	AVR="avr-g++ -mmcu=atmega644 -Os -ffunction-sections -fdata-sections -flto -std=gnu++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics -Dlinux -DLINUX -DSCR_SDBASE -DSCR_ROWS_ASM -DTRK=$t -I. -w"
	for f in scr_track scr_math scr_io_avr 3D_Engine; do $AVR -c $f.cpp -o $W/a_$f.o; done
	$AVR -c $W/rows_dump.cpp -o $W/a_rows_dump.o
	avr-gcc -mmcu=atmega644 -x assembler-with-cpp -I"$KERNEL_DIR" -c sdBase_scr.S -o $W/a_sdBase.o
	avr-gcc -mmcu=atmega644 -x assembler-with-cpp -c scr_rows.S -o $W/a_rows.o
	avr-g++ -mmcu=atmega644 -Os -flto -Wl,--gc-sections -o $W/r.elf $W/a_*.o
	avr-objcopy -O ihex $W/r.elf $W/r.hex; cp "$ROOT/data/SCRTRK.BIN" $W/
	SPIR_DUMP=$W/spir.bin RT_LIMIT=60000 "$RUNTEST" $W/r.hex $(avr-nm $W/r.elf | awk '$3=="done"{print substr($1,3)}') $W/sram.bin > /dev/null 2>&1
	python3 - $t $W <<'P'
import struct, sys
t, w = int(sys.argv[1]), sys.argv[2]
pc = [tuple(map(int, l.split())) for l in open(w + '/pc.txt')]
d = open(w + '/spir.bin', 'rb').read()
n = struct.unpack('<I', d[0x10000 - 4:0x10000])[0] // 16
avr = [struct.unpack('<iiii', d[0x10000 + 16 * i:0x10000 + 16 * i + 16]) for i in range(n)]
bad = sum(a != b for a, b in zip(pc, avr)) + abs(len(pc) - len(avr))
print(f'track {t}: {len(pc)} corners, differing {bad}')
P
done
rm -rf $W
