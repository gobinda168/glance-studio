#!/bin/sh
# Builds Glance Studio, the Ghostty fork in terminal/, as build/Glance Studio.app.
# Needs Xcode (selected with xcode-select), its Metal Toolchain and Zig 0.16 (brew install zig@0.16).
#   scripts/build-terminal.sh        → build/Glance Studio.app
#   scripts/build-terminal.sh run    → build, then launch it
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
zig="${ZIG:-/opt/homebrew/opt/zig@0.16/bin/zig}"
app="$root/build/Glance Studio.app"
log="$root/build/terminal-build.log"

models="$root/.models/kokoro"

# The command line helper, and Kokoro's model files: downloaded once into FluidAudio's cache by `glance kokoro-fetch`
# and kept in .models/kokoro (the Xcode build copies them into the app).
helper() {
  echo "Building the glance helper…"
  (cd "$root" && swift build -c release --product glance) >>"$log" 2>&1 || { tail -20 "$log" >&2; exit 1; }
}

fetch_models() {
  [ -d "$models" ] && return
  echo "Downloading Kokoro-82M (first build only)…"
  cache="$("$root/.build/release/glance" kokoro-fetch | tail -1)"
  [ -d "$cache/kokoro-82m-coreml" ] && [ -d "$cache/kokoro" ] || { echo "kokoro-fetch failed: $cache" >&2; exit 1; }
  rm -rf "$models.partial"
  mkdir -p "$models.partial"
  cp -R "$cache/kokoro" "$cache/kokoro-82m-coreml" "$models.partial/"
  mv "$models.partial" "$models"
}

build() {
  mkdir -p "$root/build"
  helper
  fetch_models
  { [ -f "$root/Web/editor/vendor/monaco.js" ] && [ -f "$root/Web/editor/vendor/prettier.js" ]; } || "$root/scripts/build-editor-assets.sh"
  echo "Packaging the Glance extension…"
  (cd "$root/vscode" && { [ -d node_modules ] || npm ci --silent; } && npm run package --silent) >>"$log" 2>&1 \
    || { tail -20 "$log" >&2; exit 1; }
  echo "Building libghostty (zig)…"
  (cd "$root/terminal" && "$zig" build -Demit-macos-app=false -Doptimize=ReleaseFast) >"$log" 2>&1 \
    || { tail -20 "$log" >&2; exit 1; }
  echo "Building the app (xcodebuild)…"
  # The Debug configuration carries Glance's bundle id, entitlements and DEBUG flag, but compiles Swift unoptimized
  # (-Onone, every view and model several times slower): build it optimized like Release. GLANCE_SWIFT_ONONE=1 keeps
  # the old quick incremental build for iterating on the code.
  optimize="SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s ENABLE_TESTABILITY=NO ENABLE_DEBUG_DYLIB=NO"
  [ "${GLANCE_SWIFT_ONONE:-0}" = 1 ] && optimize=""
  # Same environment as Ghostty's macos/build.nu: a clean PATH keeps Homebrew tools out of Xcode's build.
  # No get-task-allow (Xcode adds it to Debug builds): debuggers can't attach to Studio and read unlocked secrets.
  # shellcheck disable=SC2086
  (cd "$root/terminal/macos" && env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT="$PWD/build" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO $optimize build) >>"$log" 2>&1 \
    || { grep -E "error:" "$log" | sort -u | head -20 >&2; exit 1; }
  rm -rf "$app" "$root/build/Glance Terminal.app" # the app was called Glance Terminal first
  cp -R "$root/terminal/macos/build/Debug/Ghostty.app" "$app"
  # The helper, and what `glance setup` copies into ~/.claude (the hook and status line scripts, the output style).
  cp "$root/.build/release/glance" "$app/Contents/MacOS/glance"
  cp -R "$root/hooks" "$root/styles" "$app/Contents/Resources/"
  # Claude's browser broker (Resources.agentBrowserScript), without its test.
  mkdir -p "$app/Contents/Resources/agent-browser"
  cp "$root/agent-browser/agent-browser.mjs" "$app/Contents/Resources/agent-browser/"
  # Automation UIs' glance-automation://glance/tokens.css is the design system's own file (Resources.designTokens).
  mkdir -p "$app/Contents/Resources/design-system/glance"
  cp "$root/design-system/glance/tokens.css" "$app/Contents/Resources/design-system/glance/tokens.css"
  # The Claude Code mods every `claude` in Studio loads (ClaudeMods): their code, without tests or generated types.
  rsync -a --exclude tests --exclude .claude-plugin/types --exclude tsconfig.json --exclude vendor.sh \
    "$root/mods" "$app/Contents/Resources/"
  # The GPL-3.0 and the notices of the code Studio contains, opened from the About window (AboutView).
  cp "$root/LICENSE" "$app/Contents/Resources/LICENSE.txt"
  cp "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
  # The menu bar shows CFBundleName, which Xcode's generated Info.plist always sets to the target name ("Ghostty").
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Glance Studio" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright Copyright © 2026 Gobinda Das" "$app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Copyright © 2026 Gobinda Das" "$app/Contents/Info.plist"
  # Sparkle orders builds by CFBundleVersion, which Xcode leaves at 1.
  "$root/scripts/stamp-version.sh" --bundle-version "$app/Contents/Info.plist"
  "$root/scripts/sign-app.sh" "$app"
  echo "built $app"
}

case "${1:-build}" in
  build) build ;;
  run)
    build
    pkill -f "Glance Studio.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    # Launched from inside a Claude Code session (e.g. by Claude), the app would inherit its CLAUDE_CODE_* markers, and
    # every `claude` started in Glance Studio would think it's a child session and save no transcript for Glance.
    # shellcheck disable=SC2046
    env $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/-u \1/p') open "$app"
    ;;
  *) echo "usage: scripts/build-terminal.sh [build|run]" >&2; exit 2 ;;
esac
