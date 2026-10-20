#!/bin/sh
# Rebuilds hooks/vendor/mermaid-ascii.js: beautiful-mermaid's ASCII renderer alone (about 80 KB: the whole package
# pulls in elkjs, over the 1 MiB a hooks module may be).
#   mods/glance-replies/vendor.sh [version]
set -eu
version="${1:-1.1.3}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
npm init -y >/dev/null
npm install --silent "beautiful-mermaid@$version" esbuild >/dev/null
echo "export { renderMermaidASCII } from './node_modules/beautiful-mermaid/src/ascii/index.ts'" >entry.ts
./node_modules/.bin/esbuild entry.ts --bundle --format=esm --minify --platform=neutral --legal-comments=inline \
  --banner:js="// beautiful-mermaid $version (MIT, https://github.com/lukilabs/beautiful-mermaid): its ASCII renderer only, bundled by mods/glance-replies/vendor.sh. See LICENSE.beautiful-mermaid." \
  --outfile="$here/hooks/vendor/mermaid-ascii.js"
cp node_modules/beautiful-mermaid/LICENSE "$here/hooks/vendor/LICENSE.beautiful-mermaid"
