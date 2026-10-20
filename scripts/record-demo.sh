#!/bin/sh
# Records the landing page's feature clips from the real Glance Studio, and encodes them into the site.
#   scripts/record-demo.sh <scene> [seconds]       a scripted reply: Fixtures/site/<scene>.jsonl
#   scripts/record-demo.sh onboarding [seconds]    First Light, opened from Help → Welcome to Glance Studio…
#   scripts/record-demo.sh live <name> [seconds]   record while you drive the app yourself
#   scripts/record-demo.sh encode <name>           re-encode build/demo/<name>.mov into the site
#
# A scene plays without Claude: a Glance Studio tab opens in a demo project, then the scene's prompt and reply are
# written to ~/.claude/projects the way Claude Code writes them. The pane follows that transcript like any session, so
# what's recorded is the app itself: rendering, the voice, the diagrams drawing. The transcript is removed afterwards.
#
# Needs: Glance Studio running, ffmpeg (brew install ffmpeg), and for the terminal you run this from (System Settings →
# Privacy & Security): Screen & System Audio Recording, and Accessibility (to open the floating card and the Help menu).
#
# Env: GLANCE_APP (default build/Glance Studio.app, the dev build), GLANCE_SITE (default ../glance-site), DEMO_DIR (default ~/glance-demo/acme), DEMO_SIZE (the scene window in
#      points, default 1280x800), DEMO_THINK (seconds of "thinking" before the reply, default 2.5).
# The sound is the whole Mac's, from a Core Audio tap (Studio's voice doesn't reach ScreenCaptureKit), so turn on Do Not
# Disturb.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
site="${GLANCE_SITE:-$root/../glance-site}"
demo="${DEMO_DIR:-$HOME/glance-demo/acme}"
think="${DEMO_THINK:-2.5}"
size="${DEMO_SIZE:-1280x800}"
bundle="dev.glance.Terminal"
# The app by path: by name, AppleScript can start the copy in /Applications as well.
app="${GLANCE_APP:-$root/build/Glance Studio.app}"
raw_dir="$root/build/demo"
recorder="$root/build/record-window"

usage() { sed -n '2,6p' "$0" | sed 's/^# *//' >&2; exit 2; }

build_recorder() {
  if [ ! -x "$recorder" ] || [ "$root/scripts/record-window.swift" -nt "$recorder" ]; then
    echo "building the recorder…"
    mkdir -p "$root/build"
    swiftc -O "$root/scripts/record-window.swift" -o "$recorder"
  fi
}

# A small project for the tab to sit in, so the prompt line and the pane's header read like real work.
prepare_project() {
  mkdir -p "$demo/src/auth"
  [ -f "$demo/package.json" ] || printf '{\n  "name": "acme",\n  "private": true\n}\n' >"$demo/package.json"
  [ -f "$demo/src/middleware.ts" ] || printf 'export function middleware() {}\n' >"$demo/src/middleware.ts"
  [ -f "$demo/src/auth/login.ts" ] || printf 'export async function login() {}\n' >"$demo/src/auth/login.ts"
}

# Opens a Glance Studio window in the demo project and brings it to the front, through Studio's own AppleScript (no
# Accessibility needed), so the recorder takes that window and the pane follows its session. Prints the window's id.
stage_window() {
  id="$(osascript -e "tell application \"$app\"
      set cfg to new surface configuration
      set initial working directory of cfg to \"$demo\"
      set w to new window with configuration cfg
      activate window w
      return id of w
    end tell")"
  sleep 2.5
  w="${size%x*}" h="${size#*x}"
  ui "set position of (first window whose name contains \"$(basename "$demo")\") to {120, 80}
      set size of (first window whose name contains \"$(basename "$demo")\") to {$w, $h}"
  sleep 1
}

# Other terminals (this one included) hide for the take: Glance's overlay docks to them, and its panel is one of
# Studio's windows, so it would be in the recording. show_terminals brings back the ones hidden here.
hidden=""
hide_terminals() {
  hidden="$(osascript -e 'tell application "System Events"
      set out to {}
      set shown to name of every process whose visible is true and background only is false
      repeat with n in shown
        if (n as text) is in {"Terminal", "iTerm2", "Warp", "Ghostty", "WezTerm", "kitty", "Alacritty", "Hyper", "Tabby", "Wave", "Rio", "Code", "Cursor", "Windsurf", "Zed"} then
          set visible of process (n as text) to false
          set end of out to (n as text)
        end if
      end repeat
      set AppleScript'"'"'s text item delimiters to ","
      return out as text
    end tell')"
}

show_terminals() {
  [ -n "$hidden" ] || return 0
  osascript -e "tell application \"System Events\"
      repeat with n in words of \"$(echo "$hidden" | tr ',' ' ')\"
        set visible of process (n as text) to true
      end repeat
    end tell" >/dev/null 2>&1 || true
}

# Runs AppleScript against Glance Studio's process through System Events (keys, menus), which needs Accessibility.
ui() { # <script lines inside the process tell>
  if ! out="$(osascript -e "tell application \"System Events\" to tell (first process whose bundle identifier is \"$bundle\")
      $1
    end tell" 2>&1)"; then
    case "$out" in
      *-1719*|*-25211*) echo "allow Accessibility for this terminal (System Settings → Privacy & Security → Accessibility), then run it again" >&2 ;;
      *) echo "$out" >&2 ;;
    esac
    exit 1
  fi
}

# With the pane floating, a reply doesn't open its card by itself: ⌥Space opens it. (Docked, the pane is already open.)
open_card() {
  [ "$(defaults read dev.glance.Glance terminalPaneLayout 2>/dev/null || echo auto)" = floating ] || return 0
  "$recorder" "$bundle" --card && return 0 # ⌥Space toggles, and the card stays open from one window to the next
  ui 'keystroke space using option down'
  sleep 0.6
}

# Unless "Read new answers aloud" is on, a reply is only drawn: ⌥. (play) reads it, once it's on the card.
read_aloud() {
  [ "$(defaults read dev.glance.Glance readAloud 2>/dev/null || echo 0)" = 1 ] && return 0
  sleep 1.2
  ui 'keystroke "." using option down'
}

close_window() {
  [ -n "${id:-}" ] && osascript -e "tell application \"$app\" to close window (first window whose id is \"$id\")" \
    >/dev/null 2>&1 || true
}

# Starts the recorder in the background (extra arguments go to it). wait_recording returns once frames are flowing.
launch_recorder() { # <name> <seconds> [recorder options]
  mkdir -p "$raw_dir"
  raw="$raw_dir/$1.mov"
  rm -f "$raw.ready"
  name="$1" seconds="$2"
  shift 2
  rm -f "$raw.caf"
  "$recorder" "$bundle" "$raw" "$seconds" --tap "$@" &
  rec_pid=$!
}

wait_recording() {
  i=0
  while [ ! -f "$raw.ready" ]; do
    kill -0 "$rec_pid" 2>/dev/null || { wait "$rec_pid" || true; echo "the recorder stopped before it started" >&2; exit 1; }
    i=$((i + 1)); [ "$i" -lt 200 ] || { kill "$rec_pid"; echo "the recorder didn't start" >&2; exit 1; }
    sleep 0.1
  done
}

start_recording() { launch_recorder "$@"; wait_recording; }

# Writes part of a scene to the transcript, shaped like Claude Code's lines (cwd, session, timestamps, stop reasons).
# prompt: everything up to and including the first prompt. reply: the rest, the last assistant line ending the turn.
write_scene() { # <scene file> <transcript> <prompt|reply>
  python3 -I - "$1" "$2" "$3" "$demo" "$session" <<'EOF'
import json, sys, uuid, datetime
scene, transcript, part, cwd, session = sys.argv[1:]
lines = [json.loads(l) for l in open(scene) if l.strip()]
def is_prompt(e):
    c = e.get("message", {}).get("content")
    return e.get("type") == "user" and (isinstance(c, str) or (isinstance(c, list)
        and any(b.get("type") == "text" for b in c) and not any(b.get("type") == "tool_result" for b in c)))
split = next(i for i, e in enumerate(lines) if is_prompt(e)) + 1
chosen = lines[:split] if part == "prompt" else lines[split:]
last = max((i for i, e in enumerate(chosen) if e.get("type") == "assistant"), default=None)
with open(transcript, "a") as f:
    for i, e in enumerate(chosen):
        e = dict(e, cwd=cwd, sessionId=session, uuid=str(uuid.uuid4()),
                 timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"))
        if e.get("type") == "assistant":
            uses_tool = any(b.get("type") == "tool_use" for b in e["message"].get("content", []) if isinstance(b, dict))
            e["message"] = dict(e["message"], stop_reason="end_turn" if i == last else ("tool_use" if uses_tool else None))
        f.write(json.dumps(e) + "\n")
EOF
}

# The raw recording → <name>.mp4 (H.264/AAC) and <name>.webm (VP9/Opus) at up to 1920 px wide, a poster frame, and
# its entry in the site's clip list (src/media/clips.json), which the page reads to know a clip exists.
encode() { # <name>
  raw="$raw_dir/$1.mov"
  [ -f "$raw" ] || { echo "no recording at $raw" >&2; exit 1; }
  command -v ffmpeg >/dev/null || { echo "needs ffmpeg: brew install ffmpeg" >&2; exit 1; }
  media="$site/public/media"
  mkdir -p "$media" "$site/src/media"
  scale="scale='min(1920,iw)':-2:flags=lanczos,fps=30"
  # The tapped sound (<raw>.caf) when there is one, else the recording's own.
  set -- "$1" -i "$raw"
  # apad: silence after the last sound, so the clip runs as long as the video.
  [ -f "$raw.caf" ] && set -- "$@" -i "$raw.caf" -map 0:v -map 1:a -af apad -shortest
  name="$1"; shift
  echo "encoding ${name}…"
  ffmpeg -loglevel error -y "$@" -vf "$scale" -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p \
    -movflags +faststart -c:a aac -b:a 96k "$media/$name.mp4"
  ffmpeg -loglevel error -y "$@" -vf "$scale" -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -deadline good \
    -c:a libopus -b:a 64k "$media/$name.webm"
  set -- "$name"
  duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$media/$1.mp4")"
  # The poster is a late frame, when the reply and its diagram are on screen.
  ffmpeg -loglevel error -y -ss "$(python3 -c "print(round($duration * 0.7, 2))")" -i "$media/$1.mp4" \
    -frames:v 1 -q:v 3 "$media/$1.jpg"
  dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$media/$1.mp4")"
  audio="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$media/$1.mp4" | head -1)"
  python3 -I - "$site/src/media/clips.json" "$1" "$dims" "$duration" "$audio" <<'EOF'
import json, os, sys
path, name, dims, duration, audio = sys.argv[1:]
clips = json.load(open(path)) if os.path.exists(path) else {}
w, h = (int(v) for v in dims.split(","))
clips[name] = {"width": w, "height": h, "duration": round(float(duration), 2), "audio": bool(audio)}
json.dump(dict(sorted(clips.items())), open(path, "w"), indent=2)
open(path, "a").write("\n")
EOF
  ls -lh "$media/$1".* | awk '{print "  " $5 "\t" $NF}'
}

case "${1:-}" in
  ""|-h|--help) usage ;;
  encode)
    [ -n "${2:-}" ] || usage
    encode "$2"
    ;;
  onboarding)
    # First Light's intro plays by itself (the mark, the word, then the way in); record longer and click through the
    # steps to take them too. The recorder waits for its window, so the first frame is caught.
    build_recorder
    launch_recorder first-light "${2:-12}" --title "Welcome to Glance Studio"
    trap 'kill "$rec_pid" 2>/dev/null || true' EXIT
    ui 'click menu item "Welcome to Glance Studio…" of menu 1 of menu bar item "Help" of menu bar 1'
    wait_recording
    wait "$rec_pid" || true
    ui 'key code 53' # Esc: "set up later" closes it
    encode first-light
    ;;
  live)
    [ -n "${2:-}" ] || usage
    build_recorder
    start_recording "$2" "${3:-30}"
    echo "recording; drive Glance Studio now (Ctrl-C stops early)"
    wait "$rec_pid" || true
    encode "$2"
    ;;
  *)
    scene="$root/Fixtures/site/$1.jsonl"
    [ -f "$scene" ] || { echo "no scene at $scene" >&2; exit 1; }
    build_recorder
    prepare_project
    session="$(uuidgen | tr 'A-Z' 'a-z')"
    # Claude Code's folder name for a project: its path with every non-alphanumeric character as a dash.
    folder="$HOME/.claude/projects/$(printf '%s' "$demo" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$folder"
    transcript="$folder/$session.jsonl"
    trap 'rm -f "$transcript"; close_window; show_terminals' EXIT
    hide_terminals
    stage_window
    open_card
    start_recording "$1" "${2:-30}"
    sleep 1
    write_scene "$scene" "$transcript" prompt
    sleep "$think"
    write_scene "$scene" "$transcript" reply
    read_aloud
    wait "$rec_pid" || true
    encode "$1"
    ;;
esac
