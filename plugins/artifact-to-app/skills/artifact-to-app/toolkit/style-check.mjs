// Style rules for desktop-app artifacts, shared by the exporter (export.mjs) and the publish hook.
// Each finding names a rule; the rules are explained in the desktop-app-style skill under the same names.
//
//   staticChecks(html)        rules that can be read from the page's source
//   reportChecks(report)      rules measured by running the page in the Swift shell (the icon-capture run)
//   mergeFindings(a, b)       one finding per rule, measured ones winning over static guesses
//   formatFindings(findings)  lines for a terminal or for Claude
//
// level "issue": the page looks or behaves wrong in a standalone app; level "tip": a likely improvement.

const SKILL = "desktop-app-style";

export function isDesktopPage(html) {
  return /claude\.use\(\s*["']desktop["']\s*\)/.test(html) || /id=["']?claude-artifacts-manifest/.test(html);
}

function permissions(html) {
  const m = html.match(/<script[^>]*id=["']?claude-artifacts-manifest["']?[^>]*>([\s\S]*?)<\/script>/i);
  try { return (m && JSON.parse(m[1]).permissions) || []; } catch { return []; }
}

export function staticChecks(html) {
  const f = [];
  if (!isDesktopPage(html)) return f;
  const opts = (html.match(/setOptions\(\s*\{([\s\S]*?)\}\s*\)/) || [])[1] || "";
  const perms = permissions(html);
  const frameless = /\bframe\s*:\s*false/.test(opts);
  const hiddenBar = frameless || /titleBarStyle\s*:\s*["']hidden(Inset)?["']/.test(opts) || /trafficLightPosition/.test(opts);
  const nativeTitle = /<meta[^>]+artifact-app:titlebar[^>]+native-title/i.test(html);

  if ((frameless || /transparent\s*:\s*true/.test(opts) || /alwaysOnTop\s*:\s*true/.test(opts)) && !perms.includes("overlay")) {
    f.push({ level: "issue", rule: "overlay-permission",
      text: "setOptions asks for frame: false, transparent or alwaysOnTop, which need the \"overlay\" permission in the claude-artifacts-manifest tag. Without it the call is refused and the window keeps its frame." });
  }
  const panel = /tray\.set\s*\(/.test(html) && /addEventListener\(\s*["']blur["']/.test(html) && /window\.hide\s*\(/.test(html);
  if (panel && !frameless) {
    f.push({ level: "issue", rule: "menu-bar-panel",
      text: "The page has a menu bar item and hides its window when it loses focus: it's a menu bar panel. Panels have no window buttons: use frame: false in setOptions and add the \"overlay\" permission." });
  }
  if (hiddenBar && !frameless && !/--titlebar-inset-left/.test(html)) {
    f.push({ level: "issue", rule: "titlebar-inset",
      text: "The title bar is hidden but its left padding is hard-coded. Pad it with var(--titlebar-inset-left, <current value>) so it clears the window buttons in the standalone app and stays unchanged in Claude's app." });
  }
  if (hiddenBar && !nativeTitle && !/--titlebar-font|--titlebar-color/.test(html)) {
    f.push({ level: "tip", rule: "title-style",
      text: "Style the page's title with font: var(--titlebar-font, <current>) and color: var(--titlebar-color, <current>) to match native window titles, or use the native centered title." });
  }
  return f;
}

export function parseReport(stdout) {
  const line = (stdout || "").split("\n").find(l => l.startsWith("ARTIFACT_APP_REPORT "));
  if (!line) return null;
  try { return JSON.parse(line.slice("ARTIFACT_APP_REPORT ".length)); } catch { return null; }
}

export function reportChecks(r) {
  const f = [], info = [];
  if (!r) return { findings: f, info };
  if (r.nativeTitle) {
    if (r.overlap) f.push({ level: "issue", rule: "native-title",
      text: `The native centered title (${r.nativeTitle.left}–${r.nativeTitle.right} pt) runs into title-bar content (${r.overlap}). Move or shrink that content, or drop the native-title meta tag.` });
    else info.push(`title bar: native centered title at ${r.nativeTitle.left}–${r.nativeTitle.right} pt, clear of the page's controls`);
  } else if (r.band && r.band.hasTitle && r.band.items <= 4) {
    f.push({ level: "tip", rule: "native-title",
      text: `The title bar holds just a title and ${Math.max(r.band.items - 1, 0)} other small item(s). A native centered title would look more at home: add <meta name="artifact-app:titlebar" content="native-title"> and hide the page's own title with html.artifact-native-title.` });
  }
  if (r.below && !r.below.divider && r.below.gap > 4) {
    f.push({ level: "issue", rule: "blended-titlebar",
      text: `The title bar has no divider, yet the content starts ${r.below.gap} pt below it. Start the content at the bar's bottom edge; the bar's own height already spaces the title.` });
  }
  if (r.insetLeft && r.contentLeft != null) {
    if (r.contentLeft < r.insetLeft - 0.5) f.push({ level: "issue", rule: "titlebar-inset",
      text: `Title-bar content (${r.element || "first item"}) starts at ${r.contentLeft} pt, but the window buttons need ${r.insetLeft} pt. Pad the title bar with var(--titlebar-inset-left, <current value>).` });
    else info.push(`title bar: content starts at ${r.contentLeft} pt, buttons need ${r.insetLeft} pt`);
  }
  if (r.page && r.page.content > r.page.viewport + 1) {
    // Measured before any permission is granted, so the page may show a notice or example data it won't show live.
    f.push({ level: "tip", rule: "fits-window",
      text: `Before permissions are granted, the page is ${Math.round(r.page.content - r.page.viewport)} pt taller than the ${r.page.viewport} pt window it asks for. ` +
        `If it's also taller once running (ARTIFACT_APP_DEBUG=1 logs the heights), raise height in setOptions or make one inner area scroll.` });
  }
  return { findings: f, info };
}

export function mergeFindings(staticOnes, measured) {
  const byRule = new Map(staticOnes.map(x => [x.rule, x]));
  const measuredRules = new Set(measured.map(x => x.rule));
  for (const rule of measuredRules) byRule.delete(rule);   // measured beats guessed
  return [...measured, ...byRule.values()].sort((a, b) => (a.level === b.level ? 0 : a.level === "issue" ? -1 : 1));
}

export function formatFindings(findings) {
  const issues = findings.filter(x => x.level === "issue").length, tips = findings.length - issues;
  const lines = findings.map(x => `${x.level === "issue" ? "✗" : "•"} [${x.rule}] ${x.text}`);
  lines.push(findings.length
    ? `Style check: ${issues} issue(s), ${tips} tip(s). The ${SKILL} skill explains each rule and the fix.`
    : "Style check: no issues.");
  return lines;
}
