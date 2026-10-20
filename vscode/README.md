# Glance for Claude Code

Claude Code's replies, drawn and read aloud, one click from your code.

When Claude finishes a reply, Glance:

- renders it properly: Markdown, highlighted code, real Mermaid diagrams;
- reads it aloud, while an orb pulses with the voice;
- draws each diagram piece by piece while the paragraph that explains it is spoken.

It works with Claude Code in any terminal (VS Code's own, or iTerm2, Ghostty, Warp…) and with the Claude Code
extension. There's nothing to set up: Glance follows the transcripts Claude Code already writes in `~/.claude/projects`,
for sessions started inside this window's folders.

## Use it

1. Ask Claude Code something. The Glance orb at the bottom right of the status bar follows along: it spins while
   Claude thinks, shows an eye while Glance reads the reply, and a speaker while it reads aloud.
2. When a reply explains something or has a diagram, Glance opens in its own small floating window; short replies
   update it quietly. Click the orb to open or close the window yourself. Claude Code keeps its side bar; Glance
   never takes a docked spot. Where VS Code supports it, the window opens in compact mode and stays on top of the
   editor.
3. `⌥.` (Alt+. on Windows and Linux) plays or pauses the voice, with the window open or closed.

Prefer a docked view? Set `glance.placement` to `sidebar`: Glance gets its own activity-bar icon, and you can drag
the view to any side bar or to the bottom panel.

The gear in the view opens its settings: voice, speed, theme, text size, step-by-step diagrams, follow-along dimming,
and whether new answers are read aloud.

## Voices

- **System voice** (default): your computer's built-in voice, free and offline. macOS uses `say` (pick a voice with
  the `glance.systemVoice` setting, see `say -v ?`). Windows uses System.Speech, Linux uses speech-dispatcher or espeak.
- **ElevenLabs**: run **Glance: Set ElevenLabs API Key**. The key is kept in VS Code's secret storage. Glance fetches
  one paragraph ahead, so stopping early doesn't pay for the rest of the reply. If the quota runs out or the network
  fails, the system voice takes over, with a note under the header.

For the best results, ask Claude for explanations with diagrams: the Glance Mac app's `explainer` output style
(`/output-style explainer`) works well here too.

## Settings

| Setting | |
|---|---|
| `glance.watch` | `workspace` (default) follows sessions started in this window's folders; `everywhere` follows all |
| `glance.placement` | `orb` (default): the status bar orb opens a floating window; `sidebar`: a view in the activity bar |
| `glance.revealOnReply` | open or bring forward Glance when an explanation or diagram arrives (default on); off, the orb says **new reply** |
| `glance.systemVoice` | system voice name |
| `glance.elevenLabs.voiceId`, `glance.elevenLabs.model` | ElevenLabs voice and model |

## Privacy

Glance reads Claude Code transcripts on your computer. Text leaves your computer only when you choose ElevenLabs, and
then only the paragraph being read (plus a little of its neighbours, for natural intonation).
