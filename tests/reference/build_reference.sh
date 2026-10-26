#!/bin/sh
# Builds the ORIGINAL Stunt Car Racer Remake race logic (headless) as a reference:
#   build/scr_ref    races like port/host_main (same harness, inputs, random numbers)
#   build/scr_dump   dumps the remake's converted track tables (-> data/source/orig_tracks.json)
# The remake is cloned at the commit the port was made from (or REMAKE_DIR=/path/to/a/copy).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
REMAKE=${REMAKE_DIR:-$HERE/stuntcarremake}
if [ ! -d "$REMAKE" ]; then
	git clone -q https://github.com/ptitSeb/stuntcarremake "$REMAKE"
	git -C "$REMAKE" checkout -q 9f0f8e6e0aca08b715a0f9291ba21c3dc3cab39d
fi
B=$HERE/build; rm -rf "$B"; mkdir -p "$B/src"
cp "$REMAKE"/*.h "$REMAKE/Car_Behaviour.cpp" "$REMAKE/Opponent_Behaviour.cpp" "$B/src/"
for h in "$HERE"/stub/*.h; do rm -f "$B/src/$(basename "$h")"; done   # (stubs instead: no SDL/DirectX)
cat "$HERE/test_hooks.inc" >> "$B/src/Car_Behaviour.cpp"      # test hooks (forced reset, probes)
cp "$HERE"/src/*.cpp "$B/src/"                               # the remake's logic without graphics
cp -r "$ROOT/data/source/Tracks" "$B/"
cd "$B"
CXX="g++ -m32 -O1 -std=gnu++11 -I$HERE/stub -Isrc -w"
# rand(): the port's generator (randshim.h), so opponents choose the same speeds as in the port
for f in Car_Behaviour Opponent_Behaviour; do $CXX -include "$HERE/randshim.h" -c src/$f.cpp -o $f.o; done
for f in Track_logic 3D_Engine_logic Track_dump; do $CXX -c src/$f.cpp -o $f.o; done
for f in harness host_main dump_main; do $CXX -c "$HERE/$f.cpp" -o $f.o; done
g++ -m32 -o scr_ref harness.o host_main.o Track_logic.o 3D_Engine_logic.o Car_Behaviour.o Opponent_Behaviour.o
g++ -m32 -o scr_dump dump_main.o Track_dump.o 3D_Engine_logic.o Car_Behaviour.o Opponent_Behaviour.o harness.o
echo "built $B/scr_ref and $B/scr_dump"
