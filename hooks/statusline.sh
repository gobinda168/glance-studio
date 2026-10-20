#!/bin/sh
# Claude Code statusLine command: keeps the latest plan limits for Glance, and runs the status line it wrapped, if any.
# Never blocks or fails Claude Code: errors are ignored, and with nothing wrapped it prints nothing and exits 0.
dir="${GLANCE_DIR:-$HOME/.claude/glance}"
# The sentinel keeps $(…) from stripping the payload's trailing newline: a wrapped `read`-style status line needs it.
payload=$(cat; echo x)
payload=${payload%x}

# Only a payload that has rate_limits replaces the saved one: a new session sends none until its first response.
case $payload in
  *'"rate_limits"'*)
    (
      umask 077
      mkdir -p "$dir" 2>/dev/null
      tmp="$dir/usage.json.tmp.$$"
      printf '%s' "$payload" >"$tmp" 2>/dev/null && mv -f "$tmp" "$dir/usage.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    ) 2>/dev/null
    ;;
esac

# The status line the user had before Glance: same stdin, its output and exit status pass through.
if [ -f "$dir/statusline.inner" ]; then
  inner=$(cat "$dir/statusline.inner" 2>/dev/null)
  if [ -n "$inner" ]; then
    printf '%s' "$payload" | /bin/sh -c "$inner"
    exit $?
  fi
fi
exit 0
