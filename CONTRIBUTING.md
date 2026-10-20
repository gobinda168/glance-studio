# Contributing to Glance Studio

Thanks for helping. Glance Studio is a macOS workspace for Claude Code, built on [Ghostty](https://ghostty.org).
The app is free software under the GPL-3.0 (`LICENSE`).

## Before you start

- **Bugs**: open an issue with your macOS version, the Glance Studio version (Glance Studio → About) and the steps
  that show it.
- **Features**: open an issue first and describe the problem. Glance has a strong design direction
  (`design-system/glance/MASTER.md`, `DESIGN.md`), so agreeing on the shape before you write code saves us both time.
- **Security issues**: don't open an issue. See `SECURITY.md`.

## Building

See *Setup* and *Development* in `README.md`. In short:

```sh
swift test                         # GlanceCore unit tests
scripts/build-terminal.sh build    # build/Glance Studio.app
```

## Pull requests

- One change per pull request, with a short description of what it changes and how you checked it.
- Keep to the style of the code around you. Swift files have no licence header; the repository-wide `LICENSE` applies.
- Add or update tests in `Tests/GlanceCoreTests` for logic in `Sources/GlanceCore`.
- Changes inside `terminal/` that aren't about Glance belong upstream in
  [Ghostty](https://github.com/ghostty-org/ghostty).

## Contributor License Agreement

The first time you open a pull request, a bot asks you to sign the Contributor License Agreement (`CLA.md`) by
replying with one sentence. You keep the copyright to your work. The CLA lets the maintainer offer Glance under other
licences too (for example, a commercial licence), which keeps the project sustainable.

## How changes land

Development happens in a private repository, and this repository is updated from it. When your pull request is
accepted, it is applied there with you as the author and appears here with the next sync, so GitHub shows it as
closed rather than merged. Your name stays in the history of the change.
