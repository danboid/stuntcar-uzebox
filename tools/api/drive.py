# Drives a race through the emulator API (closed-loop steering on the lateral road position),
# taking a screenshot every 150 frames.  python3 drive.py FRAMES path/to/scr.uze (scr.elf beside it)
import sys, os, time; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Emu
from PIL import Image
FR = int(sys.argv[1]) if len(sys.argv) > 1 else 1200
KP, KD, DEAD, TARGET = 1.0, 6.0, 3, 256
ROM = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.abspath('scr.uze')
e = Emu(ROM)
e.cmd(f'LOAD_SYMBOLS {ROM[:-4]}.elf')
e.run(70)
e.cmd('SET_INPUT 0 8 3'); e.run(6)                      # START: menu -> race
px = e.long('players_road_x_position'); f = 0; shots = []
while f < FR:
    x = e.long('players_road_x_position')
    s = KP * (x - TARGET) + KD * (x - px); px = x
    mask = 1                                             # B: accelerate
    if s > DEAD: mask |= 64                              # LEFT
    elif s < -DEAD: mask |= 128                          # RIGHT
    e.cmd(f'SET_INPUT 0 {mask} 3'); e.run(3); f += 3
    if f % 150 < 3:
        p = f'd{f:05d}.png'; e.cmd(f'SCREENSHOT {p}'); Image.open(p).save(p); shots.append(p)
        print(f'frame {f}: piece {e.long("player_current_piece")}  road_x {x}  lap {e.cmd(f"READ_MEM SRAM {e.addr('lapNumber') + 4} 1")['values'][0]}  '
              f'damage {e.long("new_damage")}  boost {e.long("boostReserve")}  ticks {e.long("ticks_done") & 0xFFFF}', flush=True)
e.close()
