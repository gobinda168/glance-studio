#!/bin/sh
# Claude Code hook (UserPromptSubmit, Stop): forwards the hook's JSON to Glance.
# Never blocks or fails Claude Code: the POST runs in the background with a 1s cap, and errors are ignored.
payload=$(cat)
(printf '%s' "$payload" | curl -s -m 1 -X POST -H 'Content-Type: application/json' --data-binary @- \
  "http://127.0.0.1:${GLANCE_PORT:-47823}/event" >/dev/null 2>&1 &)
exit 0
