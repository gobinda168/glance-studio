#!/bin/sh
# Builds Monaco and Prettier for the Glance editor into Web/editor/vendor (gitignored, about 15 MB). Needs Node 20+.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
tool="$root/tools/editor-bundle"
out="$root/Web/editor/vendor"
command -v node >/dev/null || { echo "node is needed to build the editor (brew install node)" >&2; exit 1; }
(cd "$tool" && { [ -f package-lock.json ] && npm ci --silent || npm install --silent; })
rm -rf "$out"
mkdir -p "$out"
(cd "$tool" && node build.mjs "$out")
echo "built $out ($(du -sh "$out" | cut -f1))"
