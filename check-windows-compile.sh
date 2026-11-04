#!/bin/bash
# Checks on macOS or Linux that the project compiles for Windows x64: the app
# and its unittests are cross-compiled with ldc2, without linking or running.
# A full check (link, tests) needs Windows: see test-windows.bat.
#
# Usage: ./check-windows-compile.sh
set -euo pipefail
cd "$(dirname "$0")"

describe() {
    dub describe --compiler=ldc2 --data="$1" --data-list 2>/dev/null
}

imports=()
while IFS= read -r path; do imports+=("-I$path"); done < <(describe import-paths)
while IFS= read -r path; do imports+=("-J$path"); done < <(describe string-import-paths)
dflags=()
while IFS= read -r flag; do dflags+=("$flag"); done < <(describe dflags)
sources=()
while IFS= read -r file; do
    [[ "$file" == *.d ]] && sources+=("$file") # not resources/app.rc
done < <(describe source-files)

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

status=0
for mode in app unittest; do
    flags=()
    [[ $mode == unittest ]] && flags+=(-unittest)
    if ldc2 -c -mtriple=x86_64-windows-msvc "${dflags[@]}" ${flags[@]+"${flags[@]}"} \
        "${imports[@]}" -oq -od="$out/$mode" "${sources[@]}"; then
        echo "Windows compile ($mode): OK"
    else
        echo "Windows compile ($mode): FAILED"
        status=1
    fi
done
exit $status
