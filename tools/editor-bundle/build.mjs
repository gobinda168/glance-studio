// Bundles Monaco with only the languages Glance's editor ships (see the editor design spec), plus its three web workers,
// and Prettier (loaded by the page the first time it formats).
import { build } from "esbuild";

const KEEP_LANGUAGES = ["css", "go", "html", "javascript", "markdown", "python", "rust", "shell", "swift", "typescript", "yaml"];
const KEEP_FEATURES = ["typescript", "json"]; // language services with workers; the others are Monarch tokenizers only

const trim = {
  name: "trim-monaco",
  setup(b) {
    b.onResolve({ filter: /languages\/definitions\/([^/]+)\/register\.js$/ }, (a) =>
      KEEP_LANGUAGES.includes(a.path.match(/definitions\/([^/]+)\//)[1]) ? null : { path: a.path, namespace: "empty" });
    b.onResolve({ filter: /languages\/features\/([^/]+)\/register\.js$/ }, (a) =>
      KEEP_FEATURES.includes(a.path.match(/features\/([^/]+)\//)[1]) ? null : { path: a.path, namespace: "empty" });
    b.onResolve({ filter: /monaco-lsp-client/ }, (a) => ({ path: a.path, namespace: "empty" }));
    b.onLoad({ filter: /.*/, namespace: "empty" }, () => ({ contents: "export {}", loader: "js" }));
  },
};

const common = { bundle: true, minify: true, format: "iife", loader: { ".ttf": "dataurl" }, logLevel: "warning" };
const out = process.argv[2];
const monaco = "node_modules/monaco-editor/esm/vs";
await build({ ...common, entryPoints: { monaco: "main.js" }, outdir: out, plugins: [trim] });
await build({ ...common, entryPoints: { prettier: "prettier.js" }, outdir: out });
await build({
  ...common,
  entryPoints: {
    "editor.worker": `${monaco}/editor/editor.worker.js`,
    "ts.worker": `${monaco}/language/typescript/ts.worker.js`,
    "json.worker": `${monaco}/language/json/json.worker.js`,
  },
  outdir: out,
});
