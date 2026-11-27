#!/usr/bin/env node
// Turns a Claude desktop-app artifact (its saved index.html) into a standalone macOS app.
//
//   node <toolkit>/export.mjs <project-dir> [--runtime swift|electron] [--install [--open]] [--dmg] [--no-build]
//
// --runtime swift (default) hosts the page in WKWebView inside a small native shell
//   (runtime-swift/, compiled once and cached in ~/Library/Caches/ArtifactApp). --runtime electron bundles Chromium (runtime/):
//   larger, but renders exactly like Claude's desktop app. --dmg applies to electron only.
// --install copies the built .app to /Applications, replacing an earlier export of the same
//   app (same bundle id) and quitting it first; it refuses to replace anything else. --open launches it.
//
// <project-dir> holds source.html: the artifact's page exactly as published. The exporter
// writes everything else next to it and can be rerun after source.html changes:
//   artifact-app.json   what was exported: title, bundle id, runtime, version
//   app/index.html      the page with Google Fonts swapped for local copies in app/fonts/
//   build/icon.png      drawn by the page itself (captured from its dock.setIcon call)
//   dist/swift/<Name>.app            (swift)
//   main.js, preload.js, package.json, dist/mac-*/<Name>.app   (electron)
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import os from "node:os";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const flags = new Set(), positional = [];
let runtime = "swift";
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--runtime") runtime = argv[++i];
  else if (a.startsWith("--runtime=")) runtime = a.slice(10);
  else if (a.startsWith("--")) flags.add(a);
  else positional.push(a);
}
const log = m => console.log("•", m);
const warn = m => console.warn("!", m);
const die = m => { console.error("✗", m); process.exit(1); };
if (!["swift", "electron"].includes(runtime)) die(`Unknown runtime "${runtime}". Use swift or electron.`);
const dir = path.resolve(positional[0] || ".");

const srcFile = path.join(dir, "source.html");
if (!fs.existsSync(srcFile)) die(`No source.html in ${dir}. Save the artifact's index.html there first.`);
let html = fs.readFileSync(srcFile, "utf8");

// ---- what the page is ----
const title = (html.match(/<title>([^<]*)<\/title>/i)?.[1] || path.basename(dir)).trim();
const productName = title.slice(0, 50);
const slug = productName.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "artifact-app";
const bundleId = `local.artifact.${slug}`;
const manifest = (() => {
  const m = html.match(/<script[^>]*id=["']?claude-artifacts-manifest["']?[^>]*>([\s\S]*?)<\/script>/i);
  try { return m ? JSON.parse(m[1]) : {}; } catch { return {}; }
})();
const declared = manifest.permissions || [];
if (!/claude\.use\(\s*["']desktop["']\s*\)/.test(html)) die("This page never calls claude.use(\"desktop\"); it isn't a desktop-app artifact.");
const otherCaps = [...new Set([...html.matchAll(/claude\.use\(\s*["'](\w+)["']\s*\)/g)].map(m => m[1]))].filter(c => c !== "desktop" && c !== "permissions");
log(`${productName} · ${runtime} runtime · permissions: ${declared.join(", ") || "none"}`);
if (otherCaps.length) warn(`The page also uses ${otherCaps.join(", ")}. Those need Claude and will resolve null in the standalone app.`);
if (/\.pty\b/.test(html)) warn("The page uses desktop.pty (a terminal), which the standalone runtimes don't provide.");

const metaFile = path.join(dir, "artifact-app.json");
const oldMeta = fs.existsSync(metaFile) ? JSON.parse(fs.readFileSync(metaFile, "utf8")) : {};
const version = oldMeta.version || "1.0.0";
fs.writeFileSync(metaFile, JSON.stringify({ madeWith: "artifact-to-app", title, productName, bundleId, runtime, version }, null, 2) + "\n");

// ---- Google Fonts → local files ----
const appDir = path.join(dir, "app"), fontDir = path.join(appDir, "fonts");
fs.rmSync(fontDir, { recursive: true, force: true });
html = html.replace(/<link[^>]+rel=["']?preconnect["']?[^>]*fonts\.(googleapis|gstatic)\.com[^>]*>\n?/gi, "");
const fontLinks = [...html.matchAll(/<link[^>]+href=["'](https:\/\/fonts\.googleapis\.com\/css2?[^"']+)["'][^>]*>/gi)];
let n = 0;
for (const [tag, rawHref] of fontLinks) {
  const href = rawHref.replace(/&amp;/g, "&");
  // A current Chrome user agent gets woff2 files.
  const css = await (await fetch(href, { headers: { "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36" } })).text();
  if (!/@font-face/.test(css)) die(`Google Fonts returned no @font-face for ${href}`);
  fs.mkdirSync(fontDir, { recursive: true });
  let local = css;
  for (const url of new Set([...css.matchAll(/url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/g)].map(m => m[1]))) {
    const name = crypto.createHash("sha1").update(url).digest("hex").slice(0, 12) + path.extname(new URL(url).pathname);
    fs.writeFileSync(path.join(fontDir, name), Buffer.from(await (await fetch(url)).arrayBuffer()));
    local = local.split(url).join(name);
  }
  const cssName = `fonts-${++n}.css`;
  fs.writeFileSync(path.join(fontDir, cssName), local);
  html = html.replace(tag, `<link rel="stylesheet" href="fonts/${cssName}">`);
}
if (n) log(`bundled ${fs.readdirSync(fontDir).length - n} font files`);
const remote = [...html.matchAll(/<(?:script|link|img)[^>]+(?:src|href)=["'](https?:\/\/[^"']+)/gi)].map(m => m[1]);
if (remote.length) warn(`Still loaded from the network: ${remote.join(", ")}`);

fs.mkdirSync(appDir, { recursive: true });
fs.writeFileSync(path.join(appDir, "index.html"), html);
fs.writeFileSync(path.join(dir, ".gitignore"), "node_modules/\ndist/\n");
if (flags.has("--no-build")) { log("done (not built)"); process.exit(0); }

const iconFile = path.join(dir, "build", "icon.png");
const built = runtime === "swift" ? buildSwift() : buildElectron();
log(`built ${built}`);
if (flags.has("--install")) install(built);

// =====================================================================================
// Swift: a native shell (runtime-swift/) around WKWebView, assembled into an .app by hand.
// =====================================================================================
function buildSwift() {
  const src = path.join(HERE, "runtime-swift");
  const sources = ["main.swift", "Shell.swift", "Desktop.swift", "Menus.swift", "Titlebar.swift"].map(f => path.join(src, f));
  const target = `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macos13.0`;
  const swiftVersion = execFileSync("/usr/bin/swiftc", ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const hash = crypto.createHash("sha1").update(swiftVersion).update(target);
  for (const f of sources) hash.update(fs.readFileSync(f));
  // Cached outside the plugin, so plugin updates don't discard it and nothing is written into the plugin.
  const cache = path.join(os.homedir(), "Library", "Caches", "ArtifactApp", "swift");
  const bin = path.join(cache, `ArtifactShell-${hash.digest("hex").slice(0, 12)}`);
  if (!fs.existsSync(bin)) {
    for (const old of fs.existsSync(cache) ? fs.readdirSync(cache) : []) fs.rmSync(path.join(cache, old), { force: true });
    log("compiling the Swift shell (only after runtime-swift changes)");
    fs.mkdirSync(path.dirname(bin), { recursive: true });
    const r = spawnSync("/usr/bin/swiftc", ["-O", "-swift-version", "5", "-target", target, "-o", bin, ...sources], { stdio: "inherit" });
    if (r.status !== 0) die("The Swift shell didn't compile.");
  }

  const app = path.join(dir, "dist", "swift", `${productName}.app`);
  const contents = path.join(app, "Contents"), res = path.join(contents, "Resources"), exe = path.join(contents, "MacOS", productName);
  fs.rmSync(app, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(exe), { recursive: true });
  fs.mkdirSync(res, { recursive: true });
  fs.copyFileSync(bin, exe);
  fs.chmodSync(exe, 0o755);
  fs.cpSync(appDir, path.join(res, "app"), { recursive: true });
  fs.copyFileSync(path.join(src, "bridge.js"), path.join(res, "bridge.js"));
  fs.writeFileSync(path.join(res, "app-config.json"), JSON.stringify({ name: productName, bundleId, declared }, null, 2));
  const writePlist = withIcon => fs.writeFileSync(path.join(contents, "Info.plist"), plist({
    CFBundleDevelopmentRegion: "en", CFBundleExecutable: productName, CFBundleIdentifier: bundleId, CFBundleName: productName,
    CFBundleDisplayName: productName, CFBundlePackageType: "APPL", CFBundleShortVersionString: version, CFBundleVersion: version,
    LSMinimumSystemVersion: "13.0", LSApplicationCategoryType: "public.app-category.utilities", NSHighResolutionCapable: true,
    NSPrincipalClass: "NSApplication", NSSupportsAutomaticTermination: false, NSSupportsSuddenTermination: false,
    ...(withIcon ? { CFBundleIconFile: "AppIcon" } : {}),
  }));
  const sign = () => execFileSync("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app], { stdio: "pipe" });
  writePlist(false);
  sign();

  // The page draws its own icon: run it once with nothing granted and keep what it passes to dock.setIcon.
  fs.rmSync(iconFile, { force: true });
  const cap = spawnSync(exe, [], { env: { ...process.env, ARTIFACT_APP_CAPTURE_ICON: iconFile }, timeout: 40000, encoding: "utf8" });
  checkTitlebar(cap.stdout);
  if (fs.existsSync(iconFile)) {
    log("captured the page's icon");
    const set = path.join(dir, "build", "AppIcon.iconset");
    fs.rmSync(set, { recursive: true, force: true });
    fs.mkdirSync(set, { recursive: true });
    for (const s of [16, 32, 128, 256, 512]) {
      for (const [scale, suffix] of [[1, ""], [2, "@2x"]]) {
        execFileSync("/usr/bin/sips", ["-z", String(s * scale), String(s * scale), iconFile, "--out", path.join(set, `icon_${s}x${s}${suffix}.png`)], { stdio: "pipe" });
      }
    }
    execFileSync("/usr/bin/iconutil", ["-c", "icns", set, "-o", path.join(res, "AppIcon.icns")]);
    fs.rmSync(set, { recursive: true, force: true });
    writePlist(true);
    sign();
  } else warn("The page didn't set an icon; the app gets the generic one.");
  return app;
}

// The capture run reports where the page's title-bar content starts; warn when the window buttons would crowd it.
function checkTitlebar(stdout) {
  const line = (stdout || "").split("\n").find(l => l.startsWith("ARTIFACT_APP_REPORT "));
  if (!line) return;
  let r; try { r = JSON.parse(line.slice(20)); } catch { return; }
  if (!r.insetLeft || r.contentLeft == null) return;
  if (r.contentLeft < r.insetLeft - 0.5) {
    warn(`Title-bar content (${r.element || "first item"}) starts at ${r.contentLeft} pt, but the window buttons need ${r.insetLeft} pt. ` +
      `In the artifact, pad the title bar with var(--titlebar-inset-left, <current value>) so it fits in both Claude and the standalone app.`);
  } else log(`title bar: content starts at ${r.contentLeft} pt, buttons need ${r.insetLeft} pt`);
}

function plist(obj) {
  const x = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const body = Object.entries(obj).map(([k, v]) => `\t<key>${x(k)}</key>\n\t${typeof v === "boolean" ? (v ? "<true/>" : "<false/>") : `<string>${x(v)}</string>`}`).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${body}\n</dict>\n</plist>\n`;
}

// =====================================================================================
// Electron: the page in bundled Chromium with runtime/main.js and preload.js.
// =====================================================================================
function buildElectron() {
  for (const f of ["main.js", "preload.js"]) fs.copyFileSync(path.join(HERE, "runtime", f), path.join(dir, f));
  const pkgFile = path.join(dir, "package.json");
  const runtimePkg = JSON.parse(fs.readFileSync(path.join(HERE, "package.json"), "utf8"));
  const pkg = {
    name: slug, productName, version,
    description: `Standalone build of the "${title}" artifact (made with the artifact-to-app plugin).`,
    main: "main.js", private: true,
    scripts: { start: "electron .", dist: "electron-builder --mac dir", dmg: "electron-builder --mac dmg" },
    devDependencies: runtimePkg.devDependencies,
    build: {
      appId: bundleId, productName,
      files: ["main.js", "preload.js", "package.json", "app/**"],
      mac: { target: ["dir"], category: "public.app-category.utilities", icon: "build/icon.png", identity: null },
    },
  };
  fs.writeFileSync(pkgFile, JSON.stringify(pkg, null, 2) + "\n");
  const npm = (...a) => { const r = spawnSync("npm", a, { cwd: dir, stdio: "inherit" }); if (r.status !== 0) die(`npm ${a.join(" ")} failed`); };
  if (!fs.existsSync(path.join(dir, "node_modules", "electron"))) { log("installing Electron (once per project)"); npm("install", "--no-audit", "--no-fund"); }

  fs.rmSync(iconFile, { force: true });
  spawnSync(path.join(dir, "node_modules", ".bin", "electron"), ["."], { cwd: dir, env: { ...process.env, ARTIFACT_APP_CAPTURE_ICON: iconFile }, timeout: 40000, encoding: "utf8" });
  if (fs.existsSync(iconFile)) log("captured the page's icon");
  else { warn("The page didn't set an icon; the app gets Electron's default."); delete pkg.build.mac.icon; fs.writeFileSync(pkgFile, JSON.stringify(pkg, null, 2) + "\n"); }

  log("building the .app");
  npm("exec", "--", "electron-builder", "--mac", flags.has("--dmg") ? "dmg" : "dir");
  const out = fs.readdirSync(path.join(dir, "dist")).map(d => path.join(dir, "dist", d)).filter(d => /^mac/.test(path.basename(d)) && fs.statSync(d).isDirectory())
    .flatMap(d => fs.readdirSync(d).filter(f => f.endsWith(".app")).map(f => path.join(d, f)));
  return out.find(p => p.includes(`${path.sep}mac-${process.arch}${path.sep}`)) || out[0] || die("electron-builder produced no .app");
}

// =====================================================================================
// Install: replace /Applications/<Name>.app, but only an earlier export of this same app.
// =====================================================================================
function install(built) {
  const target = path.join("/Applications", path.basename(built));
  if (fs.existsSync(target)) {
    let id = "";
    try { id = execFileSync("/usr/bin/defaults", ["read", path.join(target, "Contents", "Info"), "CFBundleIdentifier"], { encoding: "utf8" }).trim(); } catch {}
    if (id !== bundleId) die(`${target} exists and isn't this app (bundle id "${id}"). Move it away and rerun with --install.`);
  }
  // Quit a running copy (from anywhere) so the old version doesn't stay open.
  spawnSync("/usr/bin/osascript", ["-e", `if application id "${bundleId}" is running then tell application id "${bundleId}" to quit`]);
  for (let i = 0; i < 40 && spawnSync("/usr/bin/pgrep", ["-f", `/Contents/MacOS/${productName}$`]).status === 0; i++) spawnSync("/bin/sleep", ["0.25"]);
  fs.rmSync(target, { recursive: true, force: true });
  execFileSync("/usr/bin/ditto", [built, target]);
  log(`installed ${target}`);
  if (flags.has("--open")) execFileSync("/usr/bin/open", [target]);
}
