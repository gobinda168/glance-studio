#!/bin/sh
# Tests Glance and sets up its signing identity. Glance Studio is built by scripts/build-terminal.sh.
#   scripts/build.sh test              → swift test
#   scripts/build.sh signing-identity  → create the local "Glance Local Signing" certificate (once)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="Glance Local Signing"

# A self-signed code-signing certificate in the login keychain. It never leaves this Mac.
# macOS ties Accessibility, Microphone and Keychain "Always Allow" to the app's signing identity; scripts/sign-app.sh
# signs every build with this one, so the grants survive rebuilds.
make_identity() {
  if security find-certificate -c "$identity" >/dev/null 2>&1; then echo "\"$identity\" already exists"; return; fi
  tmp="$(mktemp -d)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 \
    -subj "/CN=$identity" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$identity" \
    -out "$tmp/id.p12" -passout pass:glance
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P glance -T /usr/bin/codesign
  rm -rf "$tmp"
}

case "${1:-}" in
  test)
    shift
    # Command Line Tools ship Swift Testing's macro plugin in host/plugins/testing, which SwiftPM doesn't pass on.
    plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
    if [ -d "$plugins" ]; then
      (cd "$root" && swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@")
    else
      (cd "$root" && swift test "$@")
    fi
    ;;
  signing-identity) make_identity ;;
  *) echo "usage: scripts/build.sh [test|signing-identity]" >&2; exit 2 ;;
esac
