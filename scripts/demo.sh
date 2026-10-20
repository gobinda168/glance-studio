#!/bin/sh
# Plays a sample reply in a running Glance without Claude: copies a fixture transcript to where Claude Code keeps
# transcripts (Glance only reads from there) and sends the same events the hooks would.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$HOME/.claude/projects/glance-demo"
mkdir -p "$dir"
cp "$root/Fixtures/demo.jsonl" "$dir/demo.jsonl"
port="${GLANCE_PORT:-47823}"

post() {
  curl -s -m 2 -X POST -H 'Content-Type: application/json' "http://127.0.0.1:$port/event" -d "$1" >/dev/null
}
post "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$root\"}"
sleep "${DEMO_THINK:-2}"
post "{\"hook_event_name\":\"Stop\",\"cwd\":\"$root\",\"transcript_path\":\"$dir/demo.jsonl\"}"
echo "sent demo reply to Glance on :$port"
