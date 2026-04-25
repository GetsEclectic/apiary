import { build } from "esbuild";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

// Prod: empty port → TMUX_API resolves to same-origin; tmux-api fronts mTLS
// and reverse-proxies to ttyd on loopback, so the page and API share host+port.
// E2E: harness runs tmux-api on :3544 and ttyd on :3543 (different origins),
// so the port has to be baked in.
const TARGETS = [
  { out: resolve(here, "..", "index.html"),     tmuxApiPort: "" },
  { out: resolve(here, "..", "index.e2e.html"), tmuxApiPort: "3544" },
];

const result = await build({
  entryPoints: [resolve(here, "main.js")],
  bundle: true,
  format: "iife",
  target: "es2020",
  minify: true,
  write: false,
  logLevel: "info",
});

const appJsBase = result.outputFiles[0].text;
const wtermCss = readFileSync(resolve(here, "node_modules/@wterm/dom/src/terminal.css"), "utf8");
const template = readFileSync(resolve(here, "index.template.html"), "utf8");

for (const { out, tmuxApiPort } of TARGETS) {
  const appJs = appJsBase.replaceAll("__TMUX_API_PORT__", tmuxApiPort);
  const html = template
    .replace("__WTERM_CSS__", wtermCss.replace(/<\/style>/gi, "<\\/style>"))
    .replace("__APP_JS__", appJs.replace(/<\/script>/gi, "<\\/script>"));
  writeFileSync(out, html);
  console.log(`wrote ${out} (${html.length} bytes)`);
}
