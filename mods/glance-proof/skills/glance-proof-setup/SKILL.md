---
name: glance-proof-setup
description: Set up or update Glance proof of work for this project - writes .glance/proof.json (environments, checks, what must pass) and any helper scripts under .glance/scripts/. Use when the user asks to set up Glance proof or proof of work for a project, when Glance's Proof panel says the project isn't set up or its proof.json has a problem, or when the user wants to change what counts as a check ("also check the admin app").
---

# Set up proof of work for this project

Glance Studio records proof of this project's work by itself: which checks ran where and whether they passed, and screenshots from the Glance browser. What counts as a check and which environments exist come from **`.glance/proof.json`** at the repository root. **You write that file; Glance never does** and knows nothing about this project until you do.

This skill needs the `proof_setup` tool (Glance MCP). If you can't see it, search for it first (ToolSearch, when tools are deferred) before concluding it's missing. If it really isn't there, stop and tell the user: Command Center is off in Glance Studio (Develop menu), or Claude needs a restart (the tool list is read when a session starts), or this isn't a Glance Studio terminal. Don't write the file without a way to check it. If `proof_setup` returns an error such as "this claude process isn't tracked" or "isn't in a git repository", relay that message to the user once rather than retrying.

## 1. Read the repository

Find out how this project is tested and deployed from the repository itself, never from assumptions about what projects usually do:
- build and task files (package manifests and their scripts, Makefile, justfile, Taskfile, and the like);
- test configs for whatever test runners are in use;
- CI workflows (`.github/workflows/*`) and deploy config (hosting, container and cluster files);
- the README and any docs on testing or deploying.

If a `.glance/proof.json` exists, read it first and change only what was asked.

## 2. Ask what the repository can't tell you

Use your question tool for each thing that is unclear, at most 4 questions, offering the options you found:
- how preview deploys are made and how to find a preview's URL (a script, a PR comment, GitHub deployments, none);
- whether there is a staging environment and its URL;
- which checks must pass before merging, and where;
- how to sign in for end-to-end tests (never put secrets in the file).

## 3. Write `.glance/proof.json`

The sample below shows the **format only**. Every name, command, URL and pattern in it is a placeholder: derive each real value from this repository and the user's answers, and don't keep any placeholder you didn't confirm.

    {
      "version": 1,
      "environments": [
        { "name": "Local",   "url": "http://localhost:<port>", "match": ["localhost:*", "127.0.0.1:*"] },
        { "name": "Preview", "urlScript": ".glance/scripts/<script>.sh", "match": ["<preview host glob>"] }
      ],
      "checks": [
        { "name": "Unit", "match": "^<the command line that runs the unit tests>", "env": "Local" },
        { "name": "E2E",  "match": "<the command line that runs the end-to-end tests>", "envFrom": "<ENV_VAR_OR_FLAG>" }
      ],
      "required": ["Unit@Local", "E2E@Preview"],
      "sections": ["<a heading the project wants in its proof>"]
    }

- **version**: always `1`.
- **environments**: any names. Each needs `url` or `urlScript`. A `urlScript` is a path inside the repository (under `.glance/scripts/`) to a script that prints the URL; it gets `GLANCE_BRANCH`, `GLANCE_PR` and `GLANCE_WORKTREE` in its environment. The special value `"urlScript": "gh-deployments"` reads the PR's GitHub deployments. `match` is a list of host globs (`*` is a wildcard; add `:port` or `:*` to match ports) that classify a browser URL into this environment.
- **checks**: `match` is a regular expression over the Bash command line that will actually be run (JSON-escape backslashes). Each check needs either a fixed `env` (an environment's name) or `envFrom`, the environment variable or flag whose value is the target URL (`NAME=https://... command` or `--flag=https://...`), which Glance classifies through the environments' `match` lists.
- **required**: `Check@Environment` pairs that must pass for "Ready to merge". Both names must be defined. Optional.
- **sections**: extra headings Claude fills with `proof_note(section:)`. Optional.
- **assets**: leave out unless the user asks.
- **explainer**: leave out unless the user wants Make explainer to run the project's own tool instead of Claude. `"explainer": { "command": "<command line>" }` is a command line, not a path: Studio runs it through `zsh -lc` (a login shell, so arguments, `&&` and your PATH work) in the session's folder, with a 30 minute limit. It gets these environment variables: `GLANCE_EXPLAINER_OUT` (the folder to write into), `GLANCE_RECORD` (the path to the session's `record.json`), `GLANCE_BASE` (the ref the work is compared with; empty when there is none) and `GLANCE_BRANCH`. It must leave **`explainer.mp4`** in `GLANCE_EXPLAINER_OUT` and exit 0; anything it prints is shown if it fails. Without `explainer.command`, Make explainer asks Claude to write the scenes and Studio renders them on this Mac.

## 4. Scripts

Write any `urlScript` as a small POSIX sh script, `chmod +x` it, and **run it once** to show it prints exactly one URL and nothing else. It must finish within 30 seconds. If it needs a secret, read it from the environment and tell the user which variable; never write a secret into the repository. If a script fails or prints more than a URL, fix it and run it again; report what each script printed.

## 5. Check and report

Call `proof_setup`. It returns `status: valid` with the parsed setup, or `invalid` with the problems and their line numbers. Fix every problem and call it again. Then tell the user in a few lines: the environments (and how each URL is found), the checks and where they run, what's required, what the scripts printed when you ran them, and any question left open. Whether to commit `.glance/` is the user's call: ask.
