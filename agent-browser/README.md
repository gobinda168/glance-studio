# Glance browser broker

`agent-browser.mjs` runs the Chromium windows of Glance Studio's "Glance browser" (spec
`docs/superpowers/specs/2026-10-14-agent-browser-design.md`, real windows since 2026-10-29): Claude's browser is Chromium
itself on a lasting profile (`…/agent-browser/profile`), test browsers are Playwright servers. Studio starts it with the user's `node`; it has no
dependencies of its own and installs Playwright on first use into `~/Library/Application Support/Glance/agent-browser`.
`--session-windows` (Command Center) also keeps windows another window covers painting. `session-mcp.mjs` is the
per-session Playwright MCP wrapper `glance agent-browser mcp` runs when `options.json` has `sessionWindows`.
`scripts/build-terminal.sh` copies both into the app (`Resources.agentBrowserScript`, `Resources.sessionMcpScript`).

Test: `node --test agent-browser/test.mjs` (needs the network the first time; runs the browsers headless); the wrapper has `session-mcp.test.mjs`.
