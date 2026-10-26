#!/bin/sh
# The port's race logic vs the original remake's, tick for tick (all logged state: player and
# opponent position, angles, laps, piece, boost). The port is built with SCR_EXACT_SIN and
# SCR_EXACT_CURVE (the remake's sine table and double-precision curve maths; the AVR build keeps
# its integer versions, which drift by rounding only). Run build_reference.sh first.
#   sh compare_with_original.sh [TICKS]
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
TICKS=${1:-3000}; W=$(mktemp -d)
cd "$ROOT/port"
for f in Car_Behaviour Opponent_Behaviour 3D_Engine scr_track scr_math scr_io_pc harness host_main; do
	g++ -m32 -O1 -std=gnu++11 -I. -w -DSCR_EXACT_SIN -DSCR_EXACT_CURVE -c $f.cpp -o $W/$f.o; done
g++ -m32 -o $W/port_exact $W/*.o
for t in 0 1 2 3 4 5 6 7; do
	(cd "$HERE/build" && ./scr_ref $t $TICKS) > $W/ref.txt
	(cd "$ROOT/data" && SCR_REFINPUT=1 $W/port_exact $t $TICKS) > $W/port.txt
	python3 - $t $W/ref.txt $W/port.txt <<'P'
import sys
a=[l.split()[:14] for l in open(sys.argv[2])]; b=[l.split()[:14] for l in open(sys.argv[3])]
n=min(len(a),len(b)); first=next((i for i in range(n) if a[i]!=b[i]), None)
print(f'track {sys.argv[1]}: {n} ticks, first difference:', 'none' if first is None else f'tick {first}')
P
done
rm -rf "$W"
