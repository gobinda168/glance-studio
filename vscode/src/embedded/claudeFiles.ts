// Which of Claude's files (from Glance Studio) are still uncommitted.

/** Claude's files that git still lists as changed, sorted. Both lists hold paths relative to the workspace folder. */
export function stillChanged(claude: string[], changed: string[]): string[] {
  const now = new Set(changed);
  return [...new Set(claude)].filter((p) => now.has(p)).sort();
}
