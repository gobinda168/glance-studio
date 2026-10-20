// Reads a reply paragraph by paragraph from the extension host. The system voice speaks through the OS (`say` on
// macOS, System.Speech on Windows, speech-dispatcher or espeak on Linux); ElevenLabs audio is fetched one paragraph
// ahead and played with the OS player. Playing from the host (not the webview) means narration never waits for a
// click, and pause is a real pause (SIGSTOP / SIGCONT) where the OS allows it.
import { ChildProcess, spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { speechContext } from "./core/narration";

export interface Segment { block: number; text: string }

export type VoiceChoice = "system" | "elevenlabs";

export interface VoiceSettings {
  choice: VoiceChoice;
  speed: number;
  systemVoice: string;
  elevenLabs?: { key: string; voiceId: string; model: string };
}

/** One paragraph, ready to play. */
interface Clip {
  /** Roughly how long it plays, for timing diagram reveals. */
  durationMs: number;
  play(): Promise<void>;
  pause(): void;
  resume(): void;
  stop(): void;
}

export class Narrator {
  onSegmentStart?: (segment: Segment, durationMs: number) => void;
  onFinish?: () => void;
  /** Why ElevenLabs isn't reading (quota, key, network), or null once it is again. */
  onNotice?: (notice: string | null) => void;

  private generation = 0;
  private clip?: Clip;
  private _speaking = false;
  private _paused = false;
  private tmp = fs.mkdtempSync(path.join(os.tmpdir(), "glance-"));

  constructor(private settings: () => VoiceSettings) {}

  get isSpeaking() { return this._speaking; }
  get isPaused() { return this._paused; }

  speak(segments: Segment[], startAt = 0) {
    this.stop();
    if (startAt >= segments.length) return;
    const gen = ++this.generation;
    this._speaking = true;
    void this.run(segments, startAt, gen);
  }

  stop() {
    this.generation += 1;
    this.clip?.stop();
    this.clip = undefined;
    this._speaking = false;
    this._paused = false;
  }

  togglePause() {
    if (!this._speaking || !this.clip) return;
    if (this._paused) this.clip.resume(); else this.clip.pause();
    this._paused = !this._paused;
  }

  dispose() {
    this.stop();
    fs.rmSync(this.tmp, { recursive: true, force: true });
  }

  private async run(segments: Segment[], startAt: number, gen: number) {
    const texts = segments.map((s) => s.text);
    let next: Promise<Clip> | undefined = this.prepare(texts, startAt);
    for (let i = startAt; i < segments.length; i++) {
      const clip = await next!;
      if (gen !== this.generation) { clip.stop(); return; }
      // Fetch N+1 while N plays, and no further.
      next = i + 1 < segments.length ? this.prepare(texts, i + 1) : undefined;
      this.clip = clip;
      this.onSegmentStart?.(segments[i], clip.durationMs);
      await clip.play();
      if (gen !== this.generation) return;
    }
    this.clip = undefined;
    this._speaking = false;
    this._paused = false;
    this.onFinish?.();
  }

  private async prepare(texts: string[], index: number): Promise<Clip> {
    const settings = this.settings();
    if (settings.choice === "elevenlabs" && settings.elevenLabs) {
      try {
        const context = speechContext(texts, index);
        const file = await this.fetchElevenLabs(texts[index], context, settings.elevenLabs, index);
        this.onNotice?.(null);
        return audioClip(file, settings.speed);
      } catch (error) {
        this.onNotice?.(`System voice · ${(error as Error).message}`);
      }
    }
    return systemClip(texts[index], settings.speed, settings.systemVoice);
  }

  private async fetchElevenLabs(text: string, context: { previous: string | null; next: string | null },
                                voice: { key: string; voiceId: string; model: string }, index: number): Promise<string> {
    const body: Record<string, string> = { text, model_id: voice.model };
    if (context.previous) body.previous_text = context.previous.slice(-300);
    if (context.next) body.next_text = context.next.slice(0, 300);
    let response: Response;
    try {
      response = await fetch(
        `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voice.voiceId)}?output_format=mp3_44100_128`,
        { method: "POST", headers: { "xi-api-key": voice.key, "Content-Type": "application/json" },
          body: JSON.stringify(body), signal: AbortSignal.timeout(8000) });
    } catch {
      throw new Error("ElevenLabs unreachable");
    }
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      if (detail.includes("quota_exceeded")) throw new Error("ElevenLabs quota used");
      if (response.status === 401) throw new Error("ElevenLabs key rejected");
      throw new Error(`ElevenLabs error ${response.status}`);
    }
    const file = path.join(this.tmp, `p${Date.now()}-${index}.mp3`);
    fs.writeFileSync(file, Buffer.from(await response.arrayBuffer()));
    return file;
  }
}

// ── Clips ──────────────────────────────────────────────────────

/** A child process that plays one paragraph; pause/resume stop and continue it where the OS allows. */
function processClip(start: () => ChildProcess, durationMs: number, cleanup?: () => void): Clip {
  let child: ChildProcess | undefined;
  let stopped = false;
  return {
    durationMs,
    play: () => new Promise<void>((resolve) => {
      if (stopped) return resolve();
      try { child = start(); } catch { return resolve(); }
      child.on("error", () => resolve());
      child.on("exit", () => { cleanup?.(); resolve(); });
    }),
    pause: () => { if (child?.pid && process.platform !== "win32") process.kill(child.pid, "SIGSTOP"); },
    resume: () => { if (child?.pid && process.platform !== "win32") process.kill(child.pid, "SIGCONT"); },
    stop: () => {
      stopped = true;
      if (child?.pid) {
        if (process.platform !== "win32") { try { process.kill(child.pid, "SIGCONT"); } catch {} }
        child.kill();
      }
      cleanup?.();
    },
  };
}

function systemClip(text: string, speed: number, voice: string): Clip {
  const words = text.split(/\s+/).length;
  const wpm = 185 * speed;
  const durationMs = (words / wpm) * 60_000;
  const withStdin = (child: ChildProcess) => { child.stdin?.end(text); return child; };
  if (process.platform === "darwin") {
    const args = ["-r", String(Math.round(wpm)), "-f", "-"];
    if (voice) args.unshift("-v", voice);
    return processClip(() => withStdin(spawn("say", args)), durationMs);
  }
  if (process.platform === "win32") {
    const rate = Math.round((speed - 1) * 10);
    const script = `Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; ` +
      `$s.Rate = ${rate}; ${voice ? `try { $s.SelectVoice('${voice.replace(/'/g, "''")}') } catch {}; ` : ""}` +
      `$s.Speak([Console]::In.ReadToEnd())`;
    return processClip(() => withStdin(spawn("powershell", ["-NoProfile", "-Command", script])), durationMs);
  }
  const linux = linuxSpeaker();
  if (linux === "spd-say") {
    const rate = String(Math.round((speed - 1) * 100));
    return processClip(() => withStdin(spawn("spd-say", ["-w", "-e", "-r", rate])), durationMs);
  }
  if (linux) return processClip(() => withStdin(spawn(linux, ["-s", String(Math.round(wpm)), "--stdin"])), durationMs);
  return { durationMs: 0, play: async () => {}, pause() {}, resume() {}, stop() {} };
}

function audioClip(file: string, speed: number): Clip {
  // 128 kbps MP3: bytes → seconds.
  const durationMs = (fs.statSync(file).size * 8 / 128_000) * 1000 / speed;
  const cleanup = () => fs.rm(file, { force: true }, () => {});
  if (process.platform === "darwin") {
    return processClip(() => spawn("afplay", ["-r", String(speed), "-q", "1", file]), durationMs, cleanup);
  }
  if (process.platform === "win32") {
    const script = `Add-Type -AssemblyName PresentationCore; $p = New-Object System.Windows.Media.MediaPlayer; ` +
      `$p.Open([uri]'${file.replace(/'/g, "''")}'); $p.SpeedRatio = ${speed}; $p.Play(); ` +
      `while (-not $p.NaturalDuration.HasTimeSpan) { Start-Sleep -Milliseconds 50 }; ` +
      `Start-Sleep -Milliseconds ([int]($p.NaturalDuration.TimeSpan.TotalMilliseconds / ${speed}) + 150); $p.Close()`;
    return processClip(() => spawn("powershell", ["-NoProfile", "-Command", script]), durationMs, cleanup);
  }
  if (has("ffplay")) {
    return processClip(() => spawn("ffplay", ["-nodisp", "-autoexit", "-loglevel", "quiet", "-af", `atempo=${speed}`, file]),
      durationMs, cleanup);
  }
  return processClip(() => spawn("mpg123", ["-q", file]), durationMs, cleanup);
}

let linuxChoice: string | null | undefined;
function linuxSpeaker(): string | null {
  if (linuxChoice === undefined) linuxChoice = ["spd-say", "espeak-ng", "espeak"].find(has) ?? null;
  return linuxChoice;
}

function has(command: string): boolean {
  return spawnSync("sh", ["-c", `command -v ${command}`]).status === 0;
}
