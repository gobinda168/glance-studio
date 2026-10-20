#!/bin/sh
# Glance Studio: which Claude Code session runs in this terminal (spec 2026-10-11-humanize-summaries-design.md,
# "Session isolation"). Claude Code passes the SessionStart JSON on stdin; it goes to $GLANCE_SESSION_LINKS/<surface>.json,
# written whole (temp file, then mv). Prints nothing: SessionStart output would become Claude's context. Outside a
# Studio terminal the variables aren't set and it does nothing.
[ -n "$GLANCE_SURFACE_ID" ] && [ -n "$GLANCE_SESSION_LINKS" ] || exit 0
case "$GLANCE_SURFACE_ID" in *[!0-9A-Fa-f-]*) exit 0 ;; esac
mkdir -p "$GLANCE_SESSION_LINKS" 2>/dev/null || exit 0
tmp="$GLANCE_SESSION_LINKS/.$GLANCE_SURFACE_ID.$$"
cat >"$tmp" 2>/dev/null && mv -f "$tmp" "$GLANCE_SESSION_LINKS/$GLANCE_SURFACE_ID.json" 2>/dev/null
rm -f "$tmp" 2>/dev/null
exit 0
