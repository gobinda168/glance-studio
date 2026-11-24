---
name: claudes-browser
description: Use a real browser from Claude Code in Glance Studio. Use when a task needs a browser: checking a page or a dev server, clicking through a flow, filling a form, taking a screenshot, reading a page's console, or running Playwright end-to-end tests. The user watches it live in its own Chromium window.
---

Glance Studio gives you a real Chromium window ("Glance browser") through the `glance-browser` MCP server: the
Playwright MCP tools (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_take_screenshot`,
`browser_console_messages`, `browser_network_requests`, …). The user sees every page you open in that window, which comes
forward when you open one, so prefer it over curl-ing HTML when how the page looks or behaves matters.

- It has its own lasting profile, separate from the user's browsers: sites the user signed into there stay signed in.
  Never sign in yourself; when a page needs an account, ask the user to sign in in the Glance browser window.
- With Command Center on, each Claude session has its own browser window. Pages another session opened are in its
  window and aren't listed to you (`browser_tabs` shows yours only). That's tidiness, not a security boundary: all
  sessions share the same sign-ins.
- Prefer `browser_snapshot` to read the page and find elements; take a screenshot when the user asked for one or the
  layout itself is the question.
- If a call fails with "The user stopped the Glance browser", stop using the browser and ask the user what they want.
- The user can switch Claude's browser to Lightpanda (Settings → Browser): headless, no window, no screenshots, and not
  every site works. If screenshots fail or a page misbehaves there, say so instead of retrying.

Playwright tests: in Studio's terminals `PW_TEST_CONNECT_WS_ENDPOINT` points at the Glance browser, so run tests the usual
way (`npx playwright test`) and the user watches them in Chromium windows. Only Chromium projects can run there; for
others, or to run without it, unset the variable for that command: `env -u PW_TEST_CONNECT_WS_ENDPOINT npx playwright test`.
