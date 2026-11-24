---
name: glance-proof
description: Prove your work in Glance Studio before saying it's done - run the project's checks in their environments, open and capture the result in the Glance browser, and record problems, pending items and a verdict with Glance's proof tools. Use only when the Glance proof tools (proof_setup, proof_note, proof_verdict) are available in this session and the project has .glance/proof.json, whenever you finish a change, or when the user asks how it was tested. Without those tools, ignore this skill.
---

# Prove the work

Glance shows the user a Proof panel for this session. **Seen by Glance** entries are the checks it watched run (command, environment, exit code, result) and the screenshots it captured. **Claude says** entries are what you record with the proof tools. A claim without a matching check run is flagged to the user, so run the checks; don't describe them.

First find the tools. If you can't see `proof_setup`, search for it (ToolSearch, when tools are deferred) before concluding it's missing. If the `proof_*` tools aren't available, this project isn't using Glance proof: carry on normally and say nothing about it. If a proof tool returns an error such as "this claude process isn't tracked" or "isn't in a git repository", relay that message to the user once and carry on rather than retrying.

1. **Read the setup.** Call `proof_setup`. If it says `missing`, there is no proof to record: carry on normally, and mention the glance-proof-setup skill only if the user asked about proof or testing. If it says `invalid`, tell the user and offer glance-proof-setup. Don't invent checks. Everything below uses the environments, checks and `required` list it returns.

2. **Run the checks.** Each `required` entry is `Check@Environment`: run that check in that environment, not in every environment. Also run any other check that fits what changed, and any check the user asked for (never skip one). If the change has nothing to test (a typo fix, a question answered), run nothing and say so with `proof_note`. Run each check **as its own command line**, exactly as its `match` expects, in the foreground, and let its exit code stand: don't pipe it (`| tail` hides the exit code), don't chain it with `;` or `||`, don't add a second command after it, and don't background it. If you must filter the output anyway, make the runner's own summary line (for example the pass and fail counts) appear in the output, so Glance can still read the result. For a check with `envFrom`, pass the environment's URL the way the check's `match` and `envFrom` say. If a check can't run (no preview yet, no credentials, a failing environment), record that with `proof_pending` instead of leaving it out.

3. **Look at the result, when the change shows in a browser.** For each environment that has a URL (the setup's `url`, or what its `urlScript` prints; run it yourself if you need it), open the changed page in the Glance browser (the claudes-browser skill). Glance already records the browser's screenshots by itself as testing evidence and sorts them into environments by URL. For the final state the user should see first, also save a screenshot (or a recording) to a file, then call `proof_capture` with `path` (absolute is best), `caption` (what it shows), `url` (the page) and `purpose: "outcome"`; the extra outcome copy is intended. Only images, videos and logs (log, txt) are accepted. For a backend change with nothing to see, capture a log, or nothing.

4. **Record what happened.** `proof_note` with `kind` tried, found, problem or resolved: what you tried, what you found, each problem and how it was resolved. Use one of the setup's `sections` (as `section`) when it fits.

5. **Record what's left.** `proof_pending` for anything not done or not checked; call it again with the same text and `done: true` when it is.

6. **Give the verdict before saying the work is done.** Call `proof_verdict` once, at the end, with `verdict` merge, hold or not-ready and `reasons` that match what Glance saw. If a required check failed or didn't run, the verdict isn't `merge`. Then tell the user the same in plain words.
