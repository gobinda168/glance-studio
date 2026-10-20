---
name: web-logs
description: Read the browser console and network requests of a page open in Glance Studio's Browser. Use when debugging a frontend: a blank or broken page, a console error, a failed or slow API call, a wrong response, or when the user says "check the console" or "look at the network tab".
---

Glance Studio records the console and the fetch and XHR requests of every page open in its Browser tabs (a dev server's
page opens there on its own). Read them with `glance-browser`, which Studio puts on `PATH` in its terminals. Do not guess
at what the page printed or what the server answered; look.

```
glance-browser tabs                      # the tabs being logged; * is the one in front
glance-browser console --errors          # console errors and uncaught exceptions
glance-browser network --errors          # failed requests: 4xx, 5xx, no answer
glance-browser network -n 20             # the latest 20 requests, one row each, with their #id
glance-browser request 12                # request #12 in full: headers, payload, response
glance-browser watch                     # console and network together, following (a person's view; it never ends)
```

Options: `--tab <match>` picks a tab by key (`tab:3`) or part of its address or title (default: the one in front),
`--level warn` raises the console floor, `--method POST`, `--grep <text>` searches messages, addresses and bodies,
`-n <count>` (0 for all), `-x` expands every request, `--json` prints one JSON object per line.

How to use it:
1. Start with `glance-browser console --errors` and `glance-browser network --errors`. Ask for more only when they are empty.
2. Take a request's `#id` from a row and run `glance-browser request <id>` to see what was sent and what came back.
3. After you change code and the page reloads, run the same command again. Rows are timestamped; a line `──── <address> ────`
   marks each page load.
4. Never run `watch` or `-f` yourself: they follow forever. Use a plain command and `-n`.

Limits to keep in mind:
- Only fetch and XHR requests and the page's own document are listed. Images, scripts, stylesheets, WebSockets and
  server-sent events are not, except that a script, stylesheet or image that failed to load shows as a console error.
- Passwords, tokens, cookies and `Authorization` headers are masked as `[masked]`. Never ask the user for the real values.
- Bodies are cut at 16 000 characters, and a response is only recorded when it is text, JSON or XML.
- Only pages in Glance's own Browser are logged, not Chrome or Safari. If `glance-browser` is not found, or says no tab is
  logged, Studio is not running, the page is not open in its Browser, or the setting is off (Settings → Browser →
  Developer). Say so rather than working around it.
