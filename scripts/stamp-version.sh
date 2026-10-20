#!/bin/sh
# Stamps Glance's version into a built app's Info.plist, before it is signed:
#   GlanceVersion  the marketing version, from the repo's Info.plist (bump it there)
#   GlanceBuild    the build number: the commit count on HEAD, so it only goes up
#   GLANCE_BUILD=<digits>  overrides the build number, for building an "older" and a "newer" app to test updates
#   GlanceCommit   the short commit hash, with "-dirty" when the working tree has uncommitted changes
#   GlanceDevelopment  "1" on every build but a release (GLANCE_RELEASE=1, from scripts/release.sh): it has the
#                  features not GA yet and the Develop menu (GlanceCore's Feature). A release has no such key.
#   scripts/stamp-version.sh <Info.plist>                   → the Glance* keys only
#   scripts/stamp-version.sh --bundle-version <Info.plist>  → also sets CFBundleShortVersionString and CFBundleVersion
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_version=false
[ "${1:-}" = "--bundle-version" ] && { bundle_version=true; shift; }
plist="${1:?usage: scripts/stamp-version.sh [--bundle-version] <Info.plist>}"

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$root/Info.plist")"
build="${GLANCE_BUILD:-$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)}"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$commit-dirty"

set_key() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"
}
set_key GlanceVersion "$version"
set_key GlanceBuild "$build"
set_key GlanceCommit "$commit"
if [ -n "${GLANCE_RELEASE:-}" ]; then
  /usr/libexec/PlistBuddy -c "Delete :GlanceDevelopment" "$plist" 2>/dev/null || true
  kind=release
else
  set_key GlanceDevelopment 1
  kind=development
fi
if $bundle_version; then
  set_key CFBundleShortVersionString "$version"
  set_key CFBundleVersion "$build"
fi
echo "version $version ($build, $commit), $kind build"
