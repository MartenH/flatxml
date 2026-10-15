#!/usr/bin/env bash
# bench.sh — parse time and peak memory of flatxml against other parsers on one generated document.
#
#   tools/bench.sh <megabytes> [workdir]
#
# Builds the binaries (V3, no fallback to the old compiler), writes <workdir>/gen_<MB>.xml with
# cmd/genxml if it is not there, reads it once to warm the page cache, and parses it with the
# following, printing the parse time alone and the whole process's wall time and peak memory:
#   flatxml stats          flatxml (peak RSS includes the mapped file's clean, evictable pages)
#   python ElementTree     the standard library
#   lxml                   libxml2, if a python with lxml is found
set -euo pipefail
mb=${1:?usage: tools/bench.sh <megabytes> [workdir]}
work=$(realpath -m "${2:-/tmp/flatxml_bench}")
cd "$(dirname "$0")/.."
mkdir -p "$work" bin
export V_MACOS_V3_NO_FALLBACK=1
v -prod -o bin/flatxml cmd/cli
v -prod -o bin/genxml cmd/genxml
f="$work/gen_${mb}.xml"
# written aside and renamed, so an interrupted run never leaves a truncated document to reuse
[ -f "$f" ] || { ./bin/genxml "$f.part" "$mb" && mv "$f.part" "$f"; }
cat "$f" > /dev/null
t() { /usr/bin/time -f "  wall %e s   peak RSS %M KB" "$@"; }
echo "== flatxml"
t ./bin/flatxml stats "$f" | sed -n '2,4p'
echo "== python3 xml.etree.ElementTree"
t python3 -I -c 'import sys, time, xml.etree.ElementTree as ET; t = time.perf_counter(); ET.parse(sys.argv[1]); print(f"  parse {time.perf_counter() - t:.2f} s")' "$f"
for py in python3 python3.11; do
	if "$py" -c 'import lxml.etree' 2>/dev/null; then
		echo "== lxml ($py)"
		t "$py" -c 'import sys, time, lxml.etree as E; t = time.perf_counter(); E.parse(sys.argv[1]); print(f"  parse {time.perf_counter() - t:.2f} s")' "$f"
		break
	fi
done
