---
name: claudes-browser
description: Use a real browser from Claude Code in Glance Studio. Use when a task needs a browser: checking a page or a dev server, clicking through a flow, filling a form, taking a screenshot, reading a page's console, or running Playwright end-to-end tests. The user watches it live in a floating window.
---

Glance Studio gives you a headless Chromium ("Glance browser") through the `glance-browser` MCP server: the
Playwright MCP tools (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_take_screenshot`,
`browser_console_messages`, `browser_network_requests`, …). The user sees every page you open in a floating window above
their terminal, so prefer it over curl-ing HTML when how the page looks or behaves matters.

- It is a clean profile: no cookies or sign-ins of the user's. Ask before signing in anywhere.
- Prefer `browser_snapshot` to read the page and find elements; take a screenshot when the user asked for one or the
  layout itself is the question.
- If a call fails with "The user stopped the Glance browser", stop using the browser and ask the user what they want.

Playwright tests: in Studio's terminals `PW_TEST_CONNECT_WS_ENDPOINT` points at the Glance browser, so run tests the usual
way (`npx playwright test`) and the user watches them in the same window. Only Chromium projects can run there; for
others, or to run without it, unset the variable for that command: `env -u PW_TEST_CONNECT_WS_ENDPOINT npx playwright test`.
