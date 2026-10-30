#!/bin/sh
# usage: killemu.sh <marker> [marker...]
# Stops only the emulators whose command line contains a marker (tests/logic_gdb.sh passes
# its "--gdb=PORT"). Never by image name -
# other emulators (other projects, test runners) keep running. Exits 0 when nothing matched.
[ -n "$1" ] || { echo "usage: killemu.sh <marker> [marker...]" >&2; exit 2; }
for m in "$@"; do
    powershell -NoProfile -Command 'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "cuzebox.exe" -and $_.CommandLine -like "*'"$m"'*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }' 2>/dev/null
done
exit 0
