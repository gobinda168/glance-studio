# Glance browser broker

`agent-browser.mjs` runs the headless Chromium browsers behind Glance Studio's "Glance browser" panel (spec
`docs/superpowers/specs/2026-10-14-agent-browser-design.md`). Studio starts it with the user's `node`; it has no
dependencies of its own and installs Playwright on first use into `~/Library/Application Support/Glance/agent-browser`.
`scripts/build-terminal.sh` copies it into the app (`Resources.agentBrowserScript`).

Test: `node --test agent-browser/test.mjs` (needs the network the first time).
