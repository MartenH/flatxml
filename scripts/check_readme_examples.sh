#!/usr/bin/env bash
# Type-check every V example in README.md that is a whole program (a ```v block starting with
# `import`), so the README cannot drift from the API. Run from the repository root.
set -euo pipefail
dir=.readme_examples
rm -rf "$dir" && mkdir -p "$dir"
trap 'rm -rf "$dir"' EXIT
awk -v dir="$dir" '
	/^```v$/ { inblock = 1; n++; file = dir "/example_" n ".v"; first = 1; next }
	/^```$/ && inblock { inblock = 0; next }
	inblock {
		if (first && $0 !~ /^import /) { inblock = 0; next }
		first = 0
		print > file
	}
' README.md
count=0
for f in "$dir"/*.v; do
	[ -e "$f" ] || continue
	v -check "$f"
	count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "no README examples found" >&2; exit 1; }
echo "$count README example(s) type-check"
