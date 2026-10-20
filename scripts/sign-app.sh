#!/bin/sh
# Signs an app bundle inside-out with the stable "Glance Local Signing" certificate, so macOS keeps Accessibility,
# Microphone and Keychain grants across rebuilds and updates. Nested code (Sparkle's XPC services, Autoupdate,
# Updater.app, frameworks) is signed first; the app last.
#   scripts/sign-app.sh <App.app>
# Falls back to ad hoc signing with a note; with GLANCE_RELEASE=1 a missing certificate is an error.
set -eu
identity="Glance Local Signing" # created by: scripts/build.sh signing-identity
app="${1:?usage: scripts/sign-app.sh <App.app>}"
[ -d "$app/Contents" ] || { echo "error: $app is not an app bundle" >&2; exit 1; }

if security find-certificate -c "$identity" >/dev/null 2>&1; then
  id="$identity"
elif [ -n "${GLANCE_RELEASE:-}" ]; then
  echo "error: no \"$identity\" certificate; run scripts/build.sh signing-identity" >&2
  exit 1
else
  echo "note: no \"$identity\" certificate, signing ad hoc (run: scripts/build.sh signing-identity)" >&2
  id="-"
fi

sign() { codesign --force --sign "$id" --preserve-metadata=entitlements,requirements,flags,runtime "$@" >/dev/null; }

# Deepest first, so a bundle is signed after everything inside it. Sparkle's Autoupdate helper and Glance's `glance` helper are bare executables.
find "$app/Contents" \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.dylib" -o -name Autoupdate \
    -o \( -type f -name glance \) \) \
  -not -path "*/Versions/Current/*" -print \
  | awk '{ print gsub("/", "/") " " $0 }' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r nested; do sign "$nested"; done
sign "$app"
codesign --verify --deep --strict "$app"
