#!/usr/bin/env bash
# run.sh <file> [runs] [workdir] — parse one file with flatxml, quick-xml, pugixml, lxml and
# ElementTree, several times each, and print each one's median parse time and peak memory. Every
# harness reads the file into memory first and times the parse of those bytes alone. quick-xml
# (pinned in quickxml/Cargo.toml and Cargo.lock) and pugixml (the tag below) are fetched and
# built in <workdir>, all native code with full optimisation; nothing third-party is committed.
#
#   flatxml      a read-only tree of the whole document, in place in the buffer, attributes indexed
#   quick-xml    a pull parser: every event and every attribute visited, no tree kept
#   pugixml      a mutable tree of the whole document, in place in the buffer (parse_default)
#   lxml         a libxml2 tree (python3.11, where lxml is installed here)
#   ElementTree  a tree of Python objects (the system python3)
set -euo pipefail
file=${1:?usage: tools/compare/run.sh <file> [runs] [workdir]}
runs=${2:-5}
work=$(realpath -m "${3:-/tmp/flatxml_compare}")
pugixml_tag=v1.16
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$work"
export V_MACOS_V3_NO_FALLBACK=1
v -prod -o "$work/flatxml-bench" "$here/flatxml_harness"
cargo build -q --release --manifest-path "$here/quickxml/Cargo.toml" --target-dir "$work/quickxml"
if [ ! -d "$work/pugixml-${pugixml_tag#v}" ]; then
	curl -sSL "https://github.com/zeux/pugixml/releases/download/$pugixml_tag/pugixml-${pugixml_tag#v}.tar.gz" \
		| tar xz -C "$work"
fi
src="$work/pugixml-${pugixml_tag#v}/src"
g++ -O3 -flto -DNDEBUG -std=c++17 -I"$src" -o "$work/pugixml-bench" "$here/pugixml/bench.cpp" "$src/pugixml.cpp"
cat "$file" > /dev/null
# each parser's runs: the median parse time it reports, and the largest peak memory of the runs
# (the whole process, the file's bytes included)
measure() {
	local name=$1
	shift
	local times=() peak=0 out t rss
	for _ in $(seq "$runs"); do
		if ! out=$( { /usr/bin/time -f 'rss %M' "$@"; } 2>&1 ); then
			printf '%s failed:\n%s\n' "$name" "$out" >&2
			return 1
		fi
		t=$(sed -n 's/^[a-zA-Z-]*: \([0-9.]*\) ms.*/\1/p' <<< "$out" | head -1)
		if [ -z "$t" ]; then
			printf '%s printed no time:\n%s\n' "$name" "$out" >&2
			return 1
		fi
		times+=("$t")
		rss=$(sed -n 's/^rss //p' <<< "$out")
		[ "$rss" -gt "$peak" ] && peak=$rss
	done
	med=$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
	printf '%-12s %8.1f ms  %6d MB peak\n' "$name" "$med" "$((peak / 1024))"
}
measure flatxml "$work/flatxml-bench" "$file"
measure quick-xml "$work/quickxml/release/quickxml-bench" "$file"
measure pugixml "$work/pugixml-bench" "$file"
measure lxml python3.11 "$here/python/parse.py" lxml "$file"
measure ElementTree python3 -I "$here/python/parse.py" elementtree "$file"
