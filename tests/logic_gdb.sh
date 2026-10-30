#!/bin/sh
# logic_pc_vs_avr.sh for Windows (MSYS2): the AVR build runs in the gdb emulator
# (cuzebox-esp8266-gdb) instead of the cuzebox-ex runner, the comparison needs no numpy.
#   sh logic_gdb.sh [TRACK] [TICKS] [GOLDEN]   GOLDEN: a pc.txt of an earlier run, to compare with
# env: EMU (the gdb emulator's cuzebox.exe), AVRGDB (avr-gdb), KERNEL_DIR, PORT (gdb port, 1320)
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
TRACK=${1:-0}; TICKS=${2:-3000}; GOLDEN=$3; PORT=${PORT:-1320}
EMU=${EMU:-$ROOT/../cuzebox-esp8266-gdb/cuzebox.exe}
AVRGDB=${AVRGDB:-"/c/Program Files (x86)/Microchip/Studio/7.0/toolchain/avr8/avr8-gnu-toolchain/bin/avr-gdb.exe"}
KERNEL_DIR=${KERNEL_DIR:-$ROOT/../uzebox/kernel}
W=$(mktemp -d); mkdir -p $W/card; cd "$ROOT/port"
# PC: long is 32-bit on Windows (LLP64) as on the AVR; no weak symbols in PE: scr_sfx_play stubbed
printf 'struct IDirectSoundBuffer8;\nvoid scr_sfx_play(const IDirectSoundBuffer8 *) {}\n' > $W/sfxstub.cpp
for f in Car_Behaviour Opponent_Behaviour 3D_Engine scr_track scr_math scr_io_pc harness host_main; do
	g++ -O1 -std=gnu++11 -Dlinux -DLINUX -I. -w -c $f.cpp -o $W/pc_$f.o; done
g++ -O1 -c $W/sfxstub.cpp -o $W/pc_sfxstub.o; g++ -o $W/scr_pc $W/pc_*.o
(cd "$ROOT/data" && $W/scr_pc $TRACK $TICKS) > $W/pc.txt
# AVR (as logic_pc_vs_avr.sh)
OPT="-Os -ffunction-sections -fdata-sections -mcall-prologues -flto -fno-gcse -fno-move-loop-invariants"
[ "$(avr-gcc -dumpversion | cut -d. -f1)" -ge 15 ] 2>/dev/null && OPT="$OPT -mno-fuse-move"
AVR="avr-g++ -mmcu=atmega644 $OPT -std=gnu++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics -Dlinux -DLINUX -DTRACK=$TRACK -DTICKS=$TICKS -DLOG_HASH -DSCR_SDBASE -DSCR_ROWS_ASM -DSCR_TRIG_ASM -I. -w"
PHYS=$(make -s -C "$ROOT/game" print-PHYS_OPT)
for f in Car_Behaviour Opponent_Behaviour harness; do $AVR $PHYS -c $f.cpp -o $W/avr_$f.o; done
for f in scr_io_avr avr_main; do $AVR -c $f.cpp -o $W/avr_$f.o; done
for f in scr_track scr_math 3D_Engine; do $AVR -mno-call-prologues -c $f.cpp -o $W/avr_$f.o; done
avr-gcc -mmcu=atmega644 -x assembler-with-cpp -I"$KERNEL_DIR" -c sdBase_scr.S -o $W/avr_sdBase.o
avr-gcc -mmcu=atmega644 -x assembler-with-cpp -c scr_rows.S -o $W/avr_rows.o
avr-gcc -mmcu=atmega644 -x assembler-with-cpp -c scr_trig.S -o $W/avr_trig.o
avr-g++ -g -mmcu=atmega644 $OPT -Wl,--gc-sections -o $W/scr_avr.elf $W/avr_*.o
avr-objcopy -O ihex $W/scr_avr.elf $W/scr_avr.hex
cp "$ROOT/data/SCRTRK.BIN" $W/card/
# run until `done` is 0xA5, then the log: SPI RAM from 64 K (the stub maps SPI RAM at 0x820000)
cat > $W/run.gdb <<G
set architecture avr
file scr_avr.elf
target remote localhost:$PORT
watch *(unsigned char *)&done
continue
while (*(unsigned char *)&done != 0xA5)
  continue
end
dump binary memory log.bin 0x830000 0x830000+$TICKS*8
detach
quit
G
cd $W; ("$EMU" scr_avr.hex --sdhost=card --gdb=$PORT --gdb-wait --gdb-nolimit > emu.log 2>&1 &); sleep 2
timeout 1800 "$AVRGDB" -batch -x run.gdb > gdb.log 2>&1 || true
sh "$ROOT/tools/killemu.sh" "--gdb=$PORT"
python3 - $W "$GOLDEN" <<'P'
import sys, struct, os
w, golden = sys.argv[1], sys.argv[2]
pc = [int(l.split()[14]) & 0xffffffff for l in open(w + '/pc.txt')]
d = open(w + '/log.bin', 'rb').read() if os.path.exists(w + '/log.bin') else b''
n = min(len(pc), len(d) // 8)
if n == 0: sys.exit('the AVR run did not finish (see ' + w + ')')
avr = [struct.unpack_from('<I', d, 8 * i)[0] for i in range(n)]
cyc = [struct.unpack_from('<I', d, 8 * i + 4)[0] for i in range(1, n)]
bad = [i for i in range(n) if pc[i] != avr[i]]
msg = f'ticks {n}: first mismatch {bad[0] if bad else "none"}, mismatching {len(bad)}; AVR cycles/tick mean {sum(cyc)/len(cyc):.0f} max {max(cyc)}'
if golden:
    g = [int(l.split()[14]) & 0xffffffff for l in open(golden)]
    gb = [i for i in range(min(len(g), len(pc))) if g[i] != pc[i]]
    msg += '; PC vs ' + golden + ': ' + ('identical' if not gb and len(g) == len(pc) else f'first mismatch {gb[0] if gb else "(length)"}')
print(msg)
P
[ -n "$KEEP" ] || rm -rf $W
