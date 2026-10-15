#!/usr/bin/env bash
# bench.sh — parse time and peak memory of flatxml against other parsers on one generated document.
#
#   tools/bench.sh <megabytes> [workdir]
#
# Builds the binaries (V3, no fallback to the old compiler), writes <workdir>/gen_<MB>.xml with
# cmd/genxml if it is not there, reads it once to warm the page cache, and parses it with:
#   flatxml stats          flatxml (peak RSS includes the mapped file's clean, evictable pages)
#   python ElementTree     the standard library
#   lxml                   libxml2, if a python with lxml is found
set -euo pipefail
cd "$(dirname "$0")/.."
mb=${1:?usage: tools/bench.sh <megabytes> [workdir]}
work=${2:-/tmp/flatxml_bench}
mkdir -p "$work" bin
export V_MACOS_V3_NO_FALLBACK=1
v -prod -o bin/flatxml cmd/cli
v -prod -o bin/genxml cmd/genxml
f="$work/gen_${mb}.xml"
[ -f "$f" ] || ./bin/genxml "$f" "$mb"
cat "$f" > /dev/null
t() { /usr/bin/time -f "  wall %e s   peak RSS %M KB" "$@"; }
echo "== flatxml"
t ./bin/flatxml stats "$f" | sed -n '2,4p'
echo "== python3 xml.etree.ElementTree"
t python3 -I -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$f"
for py in python3 python3.11; do
	if "$py" -c 'import lxml.etree' 2>/dev/null; then
		echo "== lxml ($py)"
		t "$py" -c 'import sys, lxml.etree as E; E.parse(sys.argv[1])' "$f"
		break
	fi
done
