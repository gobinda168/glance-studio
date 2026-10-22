# Maintainer notes

For the maintainer only: these depend on the release keys, `scripts/release.env` and the private landing site.
This file stays out of the public snapshot (`scripts/oss-exclude.txt`).

## Releasing

`scripts/release.sh terminal` builds, signs, zips, writes the Sparkle appcast, makes the DMG and publishes it as a release of the public source repo, `gobinda168/glance-studio`, tagged on the source snapshot it was built from (`scripts/oss-export.sh`). Until `LEGACY_RELEASES_REPO` is removed from `scripts/release.env`, it also updates the old `glance-releases` feed, which 0.1.0-beta.17 and earlier check. First-time setup, tester instructions and the key-backup warning are in `docs/testing.md` and the header of `scripts/release.sh`. Bump the version in `Info.plist`; the build number is the commit count.

## Landing page clips

The site (`../glance-site`) shows clips recorded from the real app. `scripts/record-demo.sh` plays a scripted reply
from `Fixtures/site/<scene>.jsonl` in Glance Studio (a tab in a demo project, the transcript written the way Claude
Code writes it), records the window with its sound (`scripts/record-window.swift`, ScreenCaptureKit), and encodes it
into the site's `public/media/` and `src/media/clips.json`. Re-record after UI changes and commit the site.

```sh
scripts/record-demo.sh cookie-fix 40         # a scene, recorded for 40 s
scripts/record-demo.sh live studio-tour 45   # record while you drive the app (Ctrl-C stops early)
```

Needs ffmpeg, the pane shown, and Screen Recording permission for your terminal.
