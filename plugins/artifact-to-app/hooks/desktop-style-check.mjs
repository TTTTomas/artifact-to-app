#!/usr/bin/env node
// PostToolUse hook for the Artifact tool. When Claude publishes a page that is a desktop-app artifact
// (it calls claude.use("desktop")), run the static style rules on it and hand Claude the findings, so the
// desktop-app-style knowledge is applied when the page is written, not only when it's exported.
// Silent for anything else. Never blocks the tool call.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const toolkit = path.join(here, "..", "skills", "artifact-to-app", "toolkit");

try {
  const input = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
  const ti = input.tool_input || {};
  const action = ti.action || "publish";
  const file = ti.file_path;
  if (action !== "publish" || !file || !/\.html?$/i.test(file) || ti.asset) process.exit(0);
  const html = fs.readFileSync(path.isAbsolute(file) ? file : path.join(input.cwd || process.cwd(), file), "utf8");
  const { isDesktopPage, staticChecks, formatFindings } = await import(path.join(toolkit, "style-check.mjs"));
  if (!isDesktopPage(html) && !(ti.capabilities && ti.capabilities.desktop)) process.exit(0);

  const findings = staticChecks(html);
  const lines = [
    "[artifact-to-app] You just published a desktop-app artifact. Pages like this should follow the desktop-app-style skill " +
      "(load it if it isn't loaded): title-bar padding and title style from the shell's --titlebar-* variables with fallbacks, " +
      "a native centered title for simple title bars, no gap under a blended title bar, frameless menu bar panels, a window that fits its content.",
    ...formatFindings(findings),
    `For the measured checks (title bar, spacing, window height), save the page as source.html in an empty scratch folder and run: ` +
      `node "${path.join(toolkit, "export.mjs")}" <that folder> --check   (macOS with the Command Line Tools; installs nothing).`,
    "Apply fixes in the artifact with fallbacks, so it looks the same in Claude's app, then republish. Tell the user what you changed.",
  ];
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: lines.join("\n") } }));
} catch {
  // A style reminder must never get in the way of publishing.
}
process.exit(0);
