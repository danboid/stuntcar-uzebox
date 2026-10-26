#!/bin/sh
# Build the cycle-level test runners (prof, runtest) on the current cuzebox-ex.
#   sh build.sh /path/to/cuzebox-ex
# 1. applies cuzebox-ex_profiling_hook.patch (instruction hook + IT entry bookkeeping in cu_avr.c)
# 2. builds cuzebox-ex headless (its objects are reused)
# 3. links prof and runtest against all objects except main.o
set -e
CZ=$(cd "$1" && pwd); HERE=$(cd "$(dirname "$0")" && pwd)
cd "$CZ"; git apply --check "$HERE/cuzebox-ex_profiling_hook.patch" 2>/dev/null && git apply "$HERE/cuzebox-ex_profiling_hook.patch" || true
make -j8 FLAG_HEADLESS=1 >/dev/null
OBJS=$(ls "$CZ"/_obj_/*.o | grep -v "/main.o")
FL="-O2 -flto -std=gnu17 -DTARGET_LINUX $(sdl2-config --cflags) -DHEADLESS=1 -DENABLE_DEBUGGER=1 -DENABLE_API_SERVER=1 -I$CZ"
cd "$HERE"
for t in prof runtest; do gcc $FL -o $t $t.c $OBJS -lSDL2 -lasound -lm -ldl -lpthread; done
echo "built: $HERE/prof $HERE/runtest"
