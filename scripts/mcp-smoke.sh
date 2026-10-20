#!/bin/sh
# Pipes JSON-RPC into `glance mcp` with no Studio listening, and checks the answers (spec 2026-10-09-orb-channel,
# "Testing"). Usage: scripts/mcp-smoke.sh [path to glance]
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
glance="${1:-$root/.build/debug/glance}"
out="$(mktemp)"
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Ship?"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nudge","arguments":{}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"ping"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"resources/list"}'
} | GLANCE_ORB_SOCKET="$(mktemp -d)/none.sock" perl -e 'alarm 20; exec @ARGV' "$glance" mcp >"$out"
fail=0
check() { grep -q -- "$2" "$out" || { echo "✗ $1"; fail=1; }; }
check "initialize answers with the channel capability" '"id":1,.*claude/channel'
check "tools/list lists ask" '"id":2,.*"name":"ask"'
check "a call without Studio says so" '"id":3,.*Glance Studio isn.t running'
check "bad arguments name the field" '"id":4,.*title is required'
check "ping answers" '"id":5,"jsonrpc":"2.0","result":{}'
check "unknown methods are errors" '-32601.*"id":6'
[ "$(wc -l <"$out")" -eq 6 ] || { echo "✗ expected 6 lines, got $(wc -l <"$out")"; fail=1; }
[ $fail -eq 0 ] && echo "✓ glance mcp smoke test passed"
rm -f "$out"
exit $fail
