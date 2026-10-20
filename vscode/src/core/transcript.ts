// Port of Sources/GlanceCore/Transcript.swift. Claude Code's transcript (JSONL) is internal and undocumented, so
// this file is the only place that knows its shape.

type Entry = { type?: string; isSidechain?: boolean; isMeta?: boolean; cwd?: string; message?: { content?: unknown; stop_reason?: string | null } };

function parse(line: string): Entry | null {
  try {
    const value = JSON.parse(line);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

/** A user entry is a prompt when it carries text; tool results also arrive as user entries. */
function isPrompt(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content)) return false;
  return content.some((b) => b?.type === "text") && !content.some((b) => b?.type === "tool_result");
}

/** The text Claude wrote since the user's last real prompt, text blocks joined by blank lines. Thinking, tool calls,
 * tool results, meta entries and subagent (sidechain) entries are skipped. */
export function lastReply(jsonl: string): string | null {
  let texts: string[] = [];
  for (const line of jsonl.split("\n")) {
    if (!line) continue;
    const entry = parse(line);
    const message = entry?.message;
    if (!entry || !message || typeof message !== "object") continue;
    if (entry.isSidechain === true || entry.isMeta === true) continue;
    if (entry.type === "user" && isPrompt(message.content)) {
      texts = [];
    } else if (entry.type === "assistant" && Array.isArray(message.content)) {
      for (const block of message.content) {
        if (block?.type !== "text" || typeof block.text !== "string") continue;
        const text = block.text.trim();
        if (text) texts.push(text);
      }
    }
  }
  return texts.length ? texts.join("\n\n") : null;
}

export type TurnEvent = { kind: "prompt" | "done"; cwd?: string };

/** What one new transcript line means for the panel: the user asked something (Claude starts thinking) or Claude
 * finished its turn. Tool use, tool results, meta and subagent entries mean nothing here. */
export function turnEvent(line: string): TurnEvent | null {
  const entry = parse(line);
  const message = entry?.message;
  if (!entry || !message || entry.isSidechain === true || entry.isMeta === true) return null;
  const cwd = typeof entry.cwd === "string" ? entry.cwd : undefined;
  if (entry.type === "user" && isPrompt(message.content)) return { kind: "prompt", cwd };
  const stop = message.stop_reason;
  if (entry.type === "assistant" && typeof stop === "string" && stop !== "tool_use" && stop !== "pause_turn") {
    return { kind: "done", cwd };
  }
  return null;
}
