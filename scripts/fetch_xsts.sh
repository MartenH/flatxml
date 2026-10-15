#!/usr/bin/env bash
# fetch_xsts.sh <dir> — put the W3C XML Schema test suite (w3c/xsdtests) at the commit
# .xsts-version names into <dir>, without the NIST datatype tests (128 MB, nearly all of them
# outside the supported subset). Nothing is fetched when <dir> is already at the pin. The suite
# is W3C's, under the W3C Document Notice and License; it is fetched, never committed.
set -euo pipefail
dir=${1:?usage: scripts/fetch_xsts.sh <dir>}
pin=$(tr -d '[:space:]' < "$(dirname "$0")/../.xsts-version")
if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$pin" ]; then
	exit 0
fi
mkdir -p "$dir"
git -C "$dir" init -q
git -C "$dir" config core.sparseCheckout true
printf '/*\n!/nistMeta/\n!/nistData/\n' > "$dir/.git/info/sparse-checkout"
git -C "$dir" fetch -q --depth=1 --filter=blob:none https://github.com/w3c/xsdtests "$pin"
git -C "$dir" checkout -q FETCH_HEAD
