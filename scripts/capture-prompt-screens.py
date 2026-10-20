#!/usr/bin/env python3
"""Drives `claude` in a pty, renders the screen with pyte, and saves dialog screens as fixtures.
Usage: capture-prompt-screens.py <out-dir> <work-dir>
Re-run when Claude Code changes its dialogs; then re-run the PromptScreen tests."""
import os, pty, sys, time, select, fcntl, termios, struct, pyte

COLS, ROWS = 140, 50
OUT, WORK = sys.argv[1], sys.argv[2]
KEYS = {"enter": b"\r", "esc": b"\x1b", "down": b"\x1b[B", "up": b"\x1b[A", "space": b" ", "tab": b"\t"}

class Claude:
    def __init__(self, *args):
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(WORK)
            os.environ["TERM"] = "xterm-256color"
            os.execvp("claude", ["claude", "--permission-mode", "default", *args])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if r:
                try: self.stream.feed(os.read(self.fd, 65536))
                except OSError: return

    def text(self):
        return "\n".join(line.rstrip() for line in self.screen.display).rstrip() + "\n"

    def wait_for(self, *needles, timeout=120):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.5)
            if any(n in self.text() for n in needles): self.pump(1.0); return True
        return False

    def type(self, text):
        for ch in text: os.write(self.fd, ch.encode()); time.sleep(0.01)
        time.sleep(0.4); os.write(self.fd, b"\r")

    def key(self, name):
        os.write(self.fd, KEYS[name]); self.pump(1.5)

    def save(self, name, ok=True):
        path = os.path.join(OUT, name + ("" if ok else ".timeout") + ".txt")
        open(path, "w").write(self.text()); print("saved", path)

    def start(self):
        self.pump(6)
        if "trust this folder" in self.text(): self.key("down"); self.key("enter"); self.pump(4)

    def quit(self):
        for _ in range(2): os.write(self.fd, b"\x03"); self.pump(1)
        try: os.kill(self.pid, 9)
        except OSError: pass

DIALOG = ("Do you want", "Would you like", "Esc to cancel", "Enter to select")

def scenario(name, prompt, steps, *args):
    c = Claude(*args); c.start()
    if name == "idle": c.save("idle"); c.quit(); return
    c.type(prompt)
    if name == "working": c.pump(4); c.save("working"); c.quit(); return
    c.save(name, c.wait_for(*DIALOG))
    for key, shot in steps:
        c.key(key)
        if shot: c.save(shot)
    c.quit()

open(os.path.join(WORK, "notes.txt"), "w").write("hello\n")
scenario("idle", "", [])
scenario("working", "Run this exact bash command and wait for it: sleep 20", [])
scenario("permission-bash", "Run this exact bash command: echo glance-probe > probe.txt",
         [("esc", "permission-bash-after-esc")])
scenario("permission-edit", "Use the Edit tool to change hello to goodbye in notes.txt", [("esc", None)])
scenario("question-single", "Use the AskUserQuestion tool to ask me one single-select question: "
         "'Which color?' with options red, green, blue (each with a short description).",
         [("down", "question-single-down"), ("esc", None)])
scenario("question-multi-1", "Use the AskUserQuestion tool to ask me two single-select questions in one call: "
         "'Which color?' (red, green) and 'Which size?' (small, large).",
         [("enter", "question-multi-2"), ("enter", "question-multi-submit"), ("esc", None)])
scenario("question-multiselect", "Use the AskUserQuestion tool to ask me one multi-select question: "
         "'Which fruits?' with options apple, banana, cherry.",
         [("space", "question-multiselect-space"), ("esc", None)])
scenario("plan", "Plan adding the line 'world' to notes.txt in two short steps, then exit plan mode to ask me.",
         [("esc", None)], "--permission-mode", "plan")
