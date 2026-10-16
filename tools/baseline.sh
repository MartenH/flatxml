#!/usr/bin/env bash
# baseline.sh — flatxml's own performance baseline, for catching regressions (docs/performance.md).
#
#   tools/baseline.sh [--against REV] [--runs N] [--workdir DIR]
#
# Builds the working tree with -prod (V3, no fallback to the old compiler) and measures, on
# documents from cmd/genxml written into DIR once and reused:
#   parse      500 MB, the bytes already in memory (tools/compare/flatxml_harness)
#   ns         namespace resolution on the same document (flatxml stats)
#   validate   8 MB and 500 MB against testdata/inventory.xsd, the whole process
#   merge      10 files (5 x 8 MB, 5 x 1 MB, the same ids, so every node has several
#              contributions) merged by keyed rules
# Each prints the best and the median of N runs, and the largest peak memory. With --against REV
# the same measurements run for REV too, built from a temporary worktree, and the merged output of
# the two is compared byte for byte. The exit status is nonzero when a measurement fails, when
# this build cannot write the merged view, or when the two merged views differ. The two builds take turns, in the opposite order each round:
# under WSL2 one process's time depends on the one before it (the 500 MB parse alternates between
# about 0.95 s and 1.25 s with the same binary), and a fixed order puts every slow run on one build.
# Absolute numbers move with the compiler and the machine; compare two builds measured together.
set -euo pipefail
against='' runs=7 work=/tmp/flatxml_baseline
while [ $# -gt 0 ]; do
	case $1 in
	--against) against=$2; shift 2 ;;
	--runs) runs=$2; shift 2 ;;
	--workdir) work=$2; shift 2 ;;
	*) echo "usage: tools/baseline.sh [--against REV] [--runs N] [--workdir DIR]" >&2; exit 2 ;;
	esac
done
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(realpath -m "$work")
mkdir -p "$work"
export V_MACOS_V3_NO_FALLBACK=1

# build <name> <tree>: the CLI and the parse harness of one tree, as <work>/<name>-{cli,harness}
build() {
	(cd "$2" && v -prod -o "$work/$1-cli" cmd/cli && v -prod -o "$work/$1-harness" tools/compare/flatxml_harness)
}
builds=(now)
build now "$root"
if [ -n "$against" ]; then
	old_tree="$work/tree-$(git -C "$root" rev-parse --short "$against")"
	[ -d "$old_tree" ] || git -C "$root" worktree add -q --detach "$old_tree" "$against"
	trap 'git -C "$root" worktree remove --force "$old_tree"' EXIT
	build then "$old_tree"
	builds=(then now)
fi

# the documents, written aside and renamed so an interrupted run never leaves one truncated
v -prod -o "$work/genxml" "$root/cmd/genxml"
for mb in 1 8 500; do
	f="$work/gen_$mb.xml"
	[ -f "$f" ] || { "$work/genxml" "$f.part" "$mb" > /dev/null && mv "$f.part" "$f"; }
	cat "$f" > /dev/null
done
mkdir -p "$work/parts"
for i in 1 2 3 4 5; do
	cp "$work/gen_8.xml" "$work/parts/a$i.xml"
	cp "$work/gen_1.xml" "$work/parts/b$i.xml"
done
cat > "$work/rules.txt" <<'EOF'
inventory site key=@id merge
site device key=@id merge
device settings single merge
settings setting key=@key merge
device * single merge
EOF
xsd="$root/testdata/inventory.xsd"

# one <build> <what>: run it once, print "<ms> <peak KB>"; the time is the one the tool reports,
# or the wall time for a whole-process measurement
one() {
	local b=$1 what=$2 out
	case $what in
	parse) out=$( { /usr/bin/time -f 'rss %M' "$work/$b-harness" "$work/gen_500.xml"; } 2>&1 ) ;;
	ns) out=$( { /usr/bin/time -f 'rss %M' "$work/$b-cli" stats "$work/gen_500.xml"; } 2>&1 ) ;;
	validate8 | validate500)
		out=$( { /usr/bin/time -f 'wall %e rss %M' "$work/$b-cli" validate "$xsd" "$work/gen_${what#validate}.xml"; } 2>&1 ) ;;
	merge) out=$( { /usr/bin/time -f 'rss %M' "$work/$b-cli" merge --rules "$work/rules.txt" --problems 3 "$work/parts/"; } 2>&1 ) ;;
	esac
	local ms
	case $what in
	parse) ms=$(sed -n 's/^flatxml: \([0-9.]*\) ms.*/\1/p' <<< "$out") ;;
	ns) ms=$(sed -n 's/.*namespaces resolved in \([0-9.]*\) ms.*/\1/p' <<< "$out") ;;
	validate*) ms=$(sed -n 's/^wall \([0-9.]*\) .*/\1/p' <<< "$out" | awk '{print $1 * 1000}') ;;
	merge) ms=$(sed -n 's/^merged in \([0-9.]*\) ms.*/\1/p' <<< "$out") ;;
	esac
	if [ -z "$ms" ]; then
		printf '%s %s failed:\n%s\n' "$b" "$what" "$out" >&2
		return 1
	fi
	echo "$ms $(sed -n 's/.*rss \([0-9]*\).*/\1/p' <<< "$out")"
}

printf '%-12s' 'ms'
for b in "${builds[@]}"; do printf '%30s' "$b: best / median (peak MB)"; done
echo
for what in parse ns validate8 validate500 merge; do
	declare -A times=() peaks=()
	for r in $(seq "$runs"); do
		order=("${builds[@]}")
		[ $((r % 2)) -eq 1 ] || order=($(printf '%s\n' "${builds[@]}" | tac))
		for b in "${order[@]}"; do
			res=$(one "$b" "$what") || exit 1
			read -r ms kb <<< "$res"
			times[$b]+="$ms "
			[ "${peaks[$b]:-0}" -ge "$kb" ] || peaks[$b]=$kb
		done
	done
	printf '%-12s' "$what"
	for b in "${builds[@]}"; do
		read -r best med < <(tr ' ' '\n' <<< "${times[$b]}" | grep . | sort -g | awk '{a[NR]=$1} END{m = NR % 2 ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1]) / 2; print a[1], m}')
		printf '%30s' "$(printf '%.0f / %.0f (%d)' "$best" "$med" $((peaks[$b] / 1024)))"
	done
	echo
	unset times peaks
done

if [ -n "$against" ]; then
	rm -f "$work"/merged-*.xml
	# an older build may not write a merged view at all; this one must, and the same bytes
	if ! out=$("$work/now-cli" merge --rules "$work/rules.txt" -o "$work/merged-now.xml" "$work/parts/" 2>&1); then
		printf 'merged output: this build failed to write it:\n%s\n' "$out" >&2
		exit 1
	fi
	if ! "$work/then-cli" merge --rules "$work/rules.txt" -o "$work/merged-then.xml" "$work/parts/" > /dev/null 2>&1; then
		echo 'merged output: not compared (that build cannot write a merged view)'
	elif cmp -s "$work/merged-then.xml" "$work/merged-now.xml"; then
		echo 'merged output: the same'
	else
		echo 'merged output: DIFFERS' >&2
		exit 1
	fi
fi
