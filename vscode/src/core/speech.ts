// Port of Sources/GlanceCore/Speech.swift: turns markdown blocks into text that sounds natural read aloud.
import { Block, isListItem } from "./blocks";

/** What the voice should say for a block, or null for blocks that are only shown (code, diagrams, tables). */
export function speechText(block: Block): string | null {
  let spoken: string;
  switch (block.kind) {
    case "code": case "mermaid": case "table": case "rule":
      return null;
    case "heading":
      spoken = sentence(clean(block.markdown.replace(/^#+/, "")));
      break;
    case "paragraph":
      spoken = clean(block.markdown);
      break;
    case "quote":
      spoken = clean(block.markdown.split("\n").filter(Boolean).map((l) => l.replace(/^[> ]+/, "")).join(" "));
      break;
    case "list":
      spoken = listItems(block.markdown).map((item) => sentence(clean(item))).filter(Boolean).join(" ");
      break;
  }
  return spoken ? spoken : null;
}

/** List items with their continuation lines folded in, markers removed. */
function listItems(markdown: string): string[] {
  const items: string[] = [];
  for (const line of markdown.split("\n").filter(Boolean)) {
    if (isListItem(line)) items.push(line.replace(/^ +/, "").replace(/^[0-9\-*+.)]+/, ""));
    else if (items.length) items[items.length - 1] += " " + line;
  }
  return items;
}

function sentence(text: string): string {
  if (!text) return text;
  const capitalized = text[0].toUpperCase() + text.slice(1);
  return ".!?:;".includes(capitalized[capitalized.length - 1]) ? capitalized : capitalized + ".";
}

export function clean(markdown: string): string {
  let s = markdown.replace(/\n/g, " ");
  s = s.replace(/!\[[^\]]*\]\([^)]*\)/g, "");
  s = s.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");
  s = s.replace(/`([^`]+)`/g, (_, code: string) => simplifyCode(code));
  s = s.replace(/https?:\/\/\S+/g, "");
  s = s.replace(/<\/?[A-Za-z][^>]*>/g, "");
  s = s.replace(/\*\*(.+?)\*\*/g, "$1");
  s = s.replace(/(?<!\w)__(.+?)__(?!\w)/g, "$1");
  s = s.replace(/~~(.+?)~~/g, "$1");
  s = s.replace(/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/g, "$1");
  s = s.replace(/(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)/g, "$1");
  for (const arrow of ["→", "⟶", "->", "=>"]) s = s.split(arrow).join(" to ");
  s = s.replace(/\s+/g, " ");
  s = s.replace(/ ([.,;:!?])/g, "$1");
  return s.replace(/^[ \t]+|[ \t]+$/g, "");
}

/** Inline code is read by name: paths become their file name, calls lose their parentheses, and anything long or
 * command-like becomes a short reference. */
function simplifyCode(raw: string): string {
  const code = raw.trim();
  if (code.includes(" ")) return code.length > 24 ? "that command" : code;
  let name = code;
  if (name.includes("/")) name = name.split("/").filter(Boolean).pop() ?? name;
  name = name.replace(/\(.*\)$/, "");
  return name.length > 40 ? "that snippet" : name;
}
