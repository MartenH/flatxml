#!/usr/bin/env bash
# run.sh <file> [runs] [workdir] — parse one file with flatxml, quick-xml and pugixml, several
# times each, and print each one's median parse time and peak memory. Every harness reads the file first and
# times only the parse. quick-xml (pinned in quickxml/Cargo.toml) and pugixml (the tag below) are
# fetched and built in <workdir>; nothing third-party is committed here.
#
#   flatxml     a tree of the whole document, in place in the mapped file, attributes indexed
#   quick-xml   a pull parser: every event and every attribute visited, no tree kept
#   pugixml     a tree of the whole document, in place in the buffer (parse_default)
set -euo pipefail
file=${1:?usage: tools/compare/run.sh <file> [runs] [workdir]}
runs=${2:-5}
work=$(realpath -m "${3:-/tmp/flatxml_compare}")
pugixml_tag=v1.16
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
mkdir -p "$work" "$repo/bin"
export V_MACOS_V3_NO_FALLBACK=1
v -prod -o "$repo/bin/flatxml" "$repo/cmd/cli"
cargo build -q --release --manifest-path "$here/quickxml/Cargo.toml" --target-dir "$work/quickxml"
if [ ! -d "$work/pugixml-${pugixml_tag#v}" ]; then
	curl -sSL "https://github.com/zeux/pugixml/releases/download/$pugixml_tag/pugixml-${pugixml_tag#v}.tar.gz" \
		| tar xz -C "$work"
fi
src="$work/pugixml-${pugixml_tag#v}/src"
g++ -O2 -std=c++17 -I"$src" -o "$work/pugixml-bench" "$here/pugixml/bench.cpp" "$src/pugixml.cpp"
cat "$file" > /dev/null
# each parser's runs: the median parse time it reports, and its peak memory (whole process, the
# file's bytes included)
measure() {
	local name=$1 pattern=$2
	shift 2
	local times=() rss=0
	for _ in $(seq "$runs"); do
		out=$( { /usr/bin/time -f 'rss %M' "$@"; } 2>&1 )
		times+=("$(sed -n "s/$pattern/\1/p" <<< "$out" | head -1)")
		rss=$(sed -n 's/^rss //p' <<< "$out")
	done
	med=$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
	printf '%-10s %8.1f ms  %6d MB peak\n' "$name" "$med" "$((rss / 1024))"
}
measure flatxml '.*parsed in \([0-9.]*\) ms.*' "$repo/bin/flatxml" stats --parse-only "$file"
measure quick-xml 'quick-xml: \([0-9.]*\) ms.*' "$work/quickxml/release/quickxml-bench" "$file"
measure pugixml 'pugixml: \([0-9.]*\) ms.*' "$work/pugixml-bench" "$file"
