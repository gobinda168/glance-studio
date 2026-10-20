# Glance: a voice-orb explainer panel for Claude Code in Warp (native Swift)

## Context
Reading Claude Code's answers in the terminal is hard. The user runs Claude Code inside **Warp**. Warp's right-hand pane is its Code Review (diff) panel, which has no extension API.

We build a **standalone native macOS app** at `~/Code/glance`, unrelated to Kata. It docks a panel over the right side of the Warp window. When Claude finishes a reply, the panel:
- renders it properly: Markdown, highlighted code, real Mermaid diagrams;
- reads the prose aloud with a system voice while a **voice orb** reacts to the real audio level;
- draws diagrams step by step in sync with the speech.

The panel never takes keyboard focus away from Warp.

The user asked for seamless performance and polish, so the app is **native Swift** instead of Electron:
- a non-activating `NSPanel`;
- event-driven Accessibility (AX) docking;
- `AVSpeechSynthesizer` + `AVAudioEngine` for the voice;
- about 40 MB of memory instead of about 250 MB.

## Toolchain (verified)
- Swift 6.4 and the Command Line Tools only, no Xcode.
- `swift build` and `swift test` with Swift Testing both work.
- There is no `metal` compiler, so the orb uses SwiftUI `Canvas`.
- Warp's bundle ID is `dev.warp.Warp-Stable`.

## Architecture
```
claude (Warp) ─UserPromptSubmit/Stop hooks─▶ hooks/notify.sh ─curl -m1 (backgrounded, || true)─▶ 127.0.0.1:47823/event
Glance.app (LSUIElement, menu-bar item)
  EventServer (NWListener) → TranscriptReader → Blocks (markdown split) → Narrator (AVSpeechSynthesizer.write → AVAudioEngine, RMS tap)
  Docker (AXObserver on Warp window move/resize + NSWorkspace activation) → GlancePanel frame
  GlancePanel (NSPanel .nonactivatingPanel) → SwiftUI: OrbView (Canvas) + WKWebView (markdown-it, highlight.js, mermaid, reveal animation)
```

## Package layout (`~/Code/glance`, SwiftPM)
- `GlanceCore` (pure, unit-tested):
  - `Transcript.swift`: the last real user prompt, then the assistant `text` blocks after it. It skips `thinking`, `tool_use`, `tool_result`, meta entries and sidechain entries.
  - `Blocks.swift`: splits Markdown into paragraph, heading, list, code, mermaid, table and quote blocks.
  - `Speech.swift`: turns a block into speakable text:
    - strips emphasis;
    - turns links into their label and drops bare URLs;
    - shortens inline code and paths (`src/a/b.ts` → "b.ts", `foo()` → "foo");
    - skips code, mermaid and table blocks.
  - `HTTPRequest.swift`: a minimal parser for the request line, headers and body.
  - `HookSetup.swift`: merges or removes Glance's hook entries in the settings JSON. It must be idempotent and keep foreign hooks.
  - `DockGeometry.swift`: places the panel inside the right part of Warp's window (about 36% of its width, clamped to 400–620 pt) and converts AX top-left coordinates to AppKit bottom-left coordinates.
- `Glance` executable (AppKit + SwiftUI):
  - `App.swift`, `Panel.swift`, `Docker.swift`, `Narrator.swift`, `EventServer.swift`, `OrbView.swift`, `ContentWeb.swift`, `Setup.swift` (`glance setup|unsetup`, which shows the diff and asks y/N).
- `Web/`: `index.html`, `app.js`, `style.css`, and `vendor/` holding pinned markdown-it, highlight.js and mermaid.
- `styles/explainer.md`: the output style.
- `hooks/notify.sh`: the hook script.
- `scripts/build.sh`: `swift build -c release`, then assembles `build/Glance.app` (Info.plist, Web resources, ad-hoc codesign).

## Behavior
- **prompt event:** the orb goes into its thinking state.
- **stop event:** read the transcript, retrying up to 3 times at 150 ms in case it hasn't been written yet, then split it into blocks.
  - Auto-show if the reply has a diagram or at least 2 prose blocks; otherwise update quietly.
  - Narrate block by block. Highlight the block being spoken. Reveal the diagram over the duration of the prose block nearest to it.
- **Visibility:** the panel is visible only while Warp (or Glance) is frontmost.
- **Hotkeys:** `⌥Space` toggles the panel; `⌥.` stops or resumes speech, using a Carbon `RegisterEventHotKey` so no permission is needed. The header also has buttons.
- **Voice:** the best installed English voice (premium, then enhanced, then Samantha), overridable with `defaults write dev.glance.Glance voice <id>`.

## Verification
1. `swift test`: transcript fixtures, block splitting, speech text, HTTP parsing, hook merge, dock geometry.
2. `scripts/build.sh && open build/Glance.app`, grant Accessibility, then `build/Glance.app/Contents/MacOS/Glance setup` (confirm the diff).
3. Without Claude: `curl` a fake stop event pointing at a fixture transcript. Expect the panel to dock, the orb to speak and the diagram to animate.
4. With Claude in Warp: `/output-style explainer`, then ask for an explanation with a diagram. Typing in Warp must keep working the whole time.
