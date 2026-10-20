// The panel is the same page the Mac app shows: copy ../Web into media/web before compiling or packaging.
import { cpSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const from = join(here, "..", "..", "Web");
const to = join(here, "..", "media", "web");
rmSync(to, { recursive: true, force: true });
cpSync(from, to, { recursive: true, filter: (path) => !path.endsWith("github-dark.min.css") });
console.log(`copied ${from} → ${to}`);
