#!/bin/sh
# Cuts a release of Glance Studio (the one app) and publishes it for Sparkle.
#   scripts/release.sh keys                    → create the Sparkle EdDSA key pair in the login keychain (once)
#   scripts/release.sh public-key              → print the public key (goes in Info.plist as SUPublicEDKey)
#   scripts/release.sh export-keys <file>      → back the private key up to a file outside the repo
#   scripts/release.sh terminal                → build, sign, zip, appcast, DMG, publish
# Config: scripts/release.env (see release.env.example). Losing the keychain key or the signing certificate strands
# every installed tester, so run export-keys and keep the file somewhere safe.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle_version="2.9.6"
tools="$root/.tools/sparkle-$sparkle_version"
dmgbuild_version="1.6.5"
dmgbuild="$root/.tools/dmgbuild-$dmgbuild_version/bin/dmgbuild"
[ -f "$root/scripts/release.env" ] && . "$root/scripts/release.env"
target="${RELEASE_TARGET:-github}"

die() { echo "error: $*" >&2; exit 1; }

# Sparkle's command line tools (generate_keys, sign_update), downloaded once and pinned to the framework's version.
fetch_tools() {
  [ -x "$tools/bin/sign_update" ] && return 0
  echo "Downloading Sparkle $sparkle_version tools (first run only)…"
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
    | tar -xJ -C "$tmp" || die "could not download Sparkle $sparkle_version"
  [ -x "$tmp/bin/sign_update" ] || die "the Sparkle tarball has no bin/sign_update"
  mkdir -p "$tools"
  cp -R "$tmp/bin" "$tools/bin"
  rm -rf "$tmp"
}

# dmgbuild lays out the installer window (background, icon positions) by writing its .DS_Store directly, so it needs no
# Finder automation. Installed once into its own venv, pinned.
fetch_dmgbuild() {
  [ -x "$dmgbuild" ] && return 0
  echo "Installing dmgbuild $dmgbuild_version (first run only)…"
  venv="$root/.tools/dmgbuild-$dmgbuild_version"
  python3 -m venv "$venv" && "$venv/bin/pip" install -q --disable-pip-version-check "dmgbuild==$dmgbuild_version" \
    || { rm -rf "$venv"; die "could not install dmgbuild $dmgbuild_version"; }
}

min_system="15.0"
certificate="Glance Local Signing"

configure() {
  slug="$1"
  case "$slug" in
    terminal)
      name="Glance Studio"; file="Glance-Studio"; build_script="build-terminal.sh"
      bundle="$root/build/Glance Studio.app"; app_plist="$root/terminal/macos/Ghostty-Info.plist" ;;
    *) die "unknown app: $slug" ;;
  esac
}

base_url() {
  if [ "$target" = github ]; then echo "https://github.com/$RELEASES_REPO/releases/download"; else echo "$RELEASE_BASE_URL"; fi
}

local_dir() { echo "${target#local:}"; }

# Checks everything that can be checked before anything is built or uploaded.
preflight() {
  case "$target" in
    github)
      [ -n "${RELEASES_REPO:-}" ] || die "set RELEASES_REPO in scripts/release.env"
      gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
      ;;
    local:*)
      [ -n "${RELEASE_BASE_URL:-}" ] || die "a local target needs RELEASE_BASE_URL (where the directory is served)"
      ;;
    *) die "RELEASE_TARGET must be github or local:<dir>" ;;
  esac
  if [ "$target" = github ] && [ -n "${RELEASE_ALLOW_DIRTY:-}${RELEASE_INSECURE_TEST:-}" ]; then
    die "RELEASE_ALLOW_DIRTY and RELEASE_INSECURE_TEST are for local targets only"
  fi
  if [ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ] && [ -z "${RELEASE_ALLOW_DIRTY:-}" ]; then
    die "uncommitted changes: commit them first, so the build number and commit mean something"
  fi
  security find-certificate -c "$certificate" >/dev/null 2>&1 \
    || die "no \"$certificate\" certificate (run: scripts/build.sh signing-identity); releases are never signed ad hoc"
  fetch_tools
  fetch_dmgbuild
}

# The build number of the appcast currently published for this app, or empty if there is none yet.
published_build() {
  if [ "$target" = github ]; then
    feed="$(curl -fsSL "$(base_url)/feed-$slug/appcast.xml" 2>/dev/null || true)"
  else
    feed="$(cat "$(local_dir)/feed-$slug/appcast.xml" 2>/dev/null || true)"
  fi
  printf '%s' "$feed" | sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' | head -1
}

write_appcast() { # <file> <version> <build> <url> <signature attributes>
  date_rfc="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
  notes=""
  [ -n "${RELEASE_NOTES:-}" ] && notes="<description><![CDATA[<p>$RELEASE_NOTES</p>]]></description>"
  cat >"$1" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$name</title>
    <item>
      <title>Version $2</title>
      <pubDate>$date_rfc</pubDate>
      <sparkle:version>$3</sparkle:version>
      <sparkle:shortVersionString>$2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_system</sparkle:minimumSystemVersion>
      $notes
      <enclosure url="$4" type="application/octet-stream" $5 />
    </item>
  </channel>
</rss>
EOF
}

publish_local() { # <tag> <zip> <appcast> <dmg>
  out="$(local_dir)"
  mkdir -p "$out/$1" "$out/feed-$slug"
  cp "$2" "$out/$1/"
  cp "$3" "$4" "$out/feed-$slug/"
}

publish_github() { # <tag> <zip> <appcast> <dmg>
  gh release view "$1" --repo "$RELEASES_REPO" >/dev/null 2>&1 && die "release $1 already exists on $RELEASES_REPO"
  # The zip first: nobody should see an appcast that points at a file that isn't there yet.
  # A version with a suffix (0.1.0-beta.1) is a pre-release on GitHub; Sparkle still offers it (it orders by build).
  prerelease=""
  case "$version" in *-*) prerelease="--prerelease" ;; esac
  gh release create "$1" "$2" --repo "$RELEASES_REPO" --title "$name $version ($build)" --notes "${RELEASE_NOTES:-}" $prerelease
  gh release view "feed-$slug" --repo "$RELEASES_REPO" >/dev/null 2>&1 \
    || gh release create "feed-$slug" --repo "$RELEASES_REPO" --title "$name feed" --latest=false \
         --notes "The stable update feed and installer for $name. Do not delete."
  gh release upload "feed-$slug" "$3" "$4" --repo "$RELEASES_REPO" --clobber
}

release_app() {
  configure "$1"
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$root/Info.plist")"
  build="${GLANCE_BUILD:-$(git -C "$root" rev-list --count HEAD)}"
  tag="$slug-v$version-$build"

  # The key in the app's plist must be the one this Mac signs with (not Ghostty's, not a typo), or no tester can update.
  plist_key="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app_plist" 2>/dev/null || true)"
  keychain_key="$("$tools/bin/generate_keys" -p 2>/dev/null || true)"
  [ -n "$keychain_key" ] || die "no Sparkle key in the keychain (run: scripts/release.sh keys)"
  [ "$plist_key" = "$keychain_key" ] || die "$app_plist has SUPublicEDKey \"$plist_key\", but the keychain's key is \"$keychain_key\""

  # An update Sparkle would never offer is worse than no update.
  published="$(published_build)"
  if [ -n "$published" ] && [ "$build" -le "$published" ]; then
    die "build $build is not newer than the published build $published (releasing from a branch with fewer commits?)"
  fi

  echo "Releasing $name $version ($build) as $tag"
  export GLANCE_BUILD="$build" GLANCE_RELEASE=1
  "$root/scripts/$build_script"
  [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$bundle/Contents/Info.plist")" = "$build" ] \
    || die "the built app's CFBundleVersion is not $build"
  if [ -n "${RELEASE_INSECURE_TEST:-}" ]; then
    # Lets a test build fetch its update from a local http server. Never for a published build.
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$bundle/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$bundle/Contents/Info.plist" 2>/dev/null || true
    "$root/scripts/sign-app.sh" "$bundle"
  fi

  stage="$root/build/release/$tag"
  rm -rf "$stage"
  mkdir -p "$stage"
  zip="$stage/$file-$version-$build.zip"
  dmg="$stage/$file.dmg"
  ditto -c -k --keepParent "$bundle" "$zip"
  signature="$("$tools/bin/sign_update" "$zip")" # sparkle:edSignature="…" length="…"
  case "$signature" in *edSignature=*length=*) ;; *) die "sign_update gave no signature: $signature" ;; esac
  write_appcast "$stage/appcast.xml" "$version" "$build" "$(base_url)/$tag/$(basename "$zip")" "$signature"
  # The installer: the app, an Applications link and an arrow between them (scripts/dmg-settings.py).
  "$dmgbuild" -s "$root/scripts/dmg-settings.py" -D app="$bundle" -D background="$root/assets/dmg/background.tiff" \
    "$name" "$dmg" >"$stage/dmgbuild.log" 2>&1 || die "dmgbuild could not make $dmg (see $stage/dmgbuild.log)"

  if [ "$target" = github ]; then publish_github "$tag" "$zip" "$stage/appcast.xml" "$dmg"
  else publish_local "$tag" "$zip" "$stage/appcast.xml" "$dmg"; fi
  echo "published $tag"
  echo "  first install:  $(base_url)/feed-$slug/$file.dmg"
  echo "  update feed:    $(base_url)/feed-$slug/appcast.xml"
}

case "${1:-}" in
  keys)
    fetch_tools
    "$tools/bin/generate_keys"
    ;;
  public-key)
    fetch_tools
    "$tools/bin/generate_keys" -p
    ;;
  export-keys)
    out="${2:?usage: scripts/release.sh export-keys <file outside the repo>}"
    case "$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" in
      "$root"/*) die "write the backup outside the repo" ;;
    esac
    fetch_tools
    "$tools/bin/generate_keys" -x "$out"
    chmod 600 "$out"
    echo "private key written to $out; store it somewhere safe and off this Mac"
    ;;
  terminal) preflight; release_app "$1" ;;
  *) echo "usage: scripts/release.sh [keys|public-key|export-keys <file>|terminal]" >&2; exit 2 ;;
esac
