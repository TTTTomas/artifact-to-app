// Artifact App runtime: runs a Claude desktop-app artifact (one that declares the `desktop`
// capability) as a standalone Electron app. Loads app/index.html and answers the desktop API
// calls preload.js forwards, the way Claude's desktop app does for an installed artifact.
// Shared by every exported app: change it here, in the plugin's toolkit/runtime, not in a copy.
const { app, BrowserWindow, ipcMain, Notification, Tray, Menu, nativeImage, shell, screen, globalShortcut } = require("electron");
const path = require("node:path");
const fsp = require("node:fs/promises");
const fs = require("node:fs");
const os = require("node:os");
const cp = require("node:child_process");

const PKG = require("./package.json");
const NAME = PKG.productName || PKG.name;
const PAGE = path.join(__dirname, "app", "index.html");
const CAPTURE_ICON = process.env.ARTIFACT_APP_CAPTURE_ICON || null;  // set by the exporter
app.setName(NAME);

// The permissions the page declares in its claude-artifacts-manifest tag; others are refused.
const DECLARED = (() => {
  const m = fs.readFileSync(PAGE, "utf8").match(/<script[^>]*id=["']?claude-artifacts-manifest["']?[^>]*>([\s\S]*?)<\/script>/i);
  try { return (m && JSON.parse(m[1]).permissions) || []; } catch { return []; }
})();
const NEEDS = [  // [channel prefix or name, permission]
  ["fs.", "full-access"], ["exec", "full-access"], ["spawn", "full-access"], ["kill", "full-access"], ["stdin", "full-access"],
  ["shell.", "full-access"], ["screen.", "overlay"], ["window.setIgnoreMouseEvents", "overlay"], ["window.setVisibleOnAllWorkspaces", "overlay"],
  ["shortcut.register", "shortcuts"], ["notification.show", "notifications"], ["tray.set", "menu-bar"],
];
const allowed = channel => {
  const need = NEEDS.find(([c]) => (c.endsWith(".") ? channel.startsWith(c) : channel === c))?.[1];
  return !need || (DECLARED.includes(need) && !CAPTURE_ICON);
};
const expand = p => (p == null ? p : p === "~" ? os.homedir() : p.startsWith("~/") ? path.join(os.homedir(), p.slice(2)) : path.isAbsolute(p) ? p : path.join(os.homedir(), p));

let win = null, tray = null, quitting = false, replacing = false;
const procs = new Map();

// ---- window: options the page sets with window.setOptions are kept for the next launch ----
const OPTIONS_FILE = path.join(app.getPath("userData"), "window-options.json");
const ALLOWED_OPTIONS = ["titleBarStyle", "trafficLightPosition", "frame", "transparent", "alwaysOnTop", "vibrancy", "visualEffectState",
  "movable", "resizable", "minimizable", "maximizable", "fullscreenable", "hasShadow", "roundedCorners", "backgroundColor",
  "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight"];
const pick = o => Object.fromEntries(Object.entries(o || {}).filter(([k]) => ALLOWED_OPTIONS.includes(k) || k === "dragHeight"));
const same = (a, b) => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b).sort());
let savedOptions = (() => { try { return pick(JSON.parse(fs.readFileSync(OPTIONS_FILE, "utf8"))); } catch { return {}; } })();
let appliedOptions = {};

function createWindow() {
  appliedOptions = { ...savedOptions };
  const { dragHeight, ...bw } = appliedOptions;
  win = new BrowserWindow({
    width: 900, height: 600, ...bw,
    title: NAME, show: false,
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  win.loadFile(PAGE);
  if (!CAPTURE_ICON) win.once("ready-to-show", () => win.show());
  // Like the Claude app: processes, shortcuts and the menu bar item end when the page reloads.
  win.webContents.on("did-start-navigation", (_e, _url, inPlace, isMainFrame) => { if (isMainFrame && !inPlace) resetPageState(); });
  // Links open in the browser; the window never navigates away from the page.
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:\/\//.test(url)) shell.openExternal(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", (e, url) => { if (!url.startsWith("file://")) { e.preventDefault(); if (/^https?:\/\//.test(url)) shell.openExternal(url); } });
  // With a menu bar item, closing only hides the window (as the installed artifact does on macOS).
  win.on("close", e => { if (!quitting && !replacing && tray) { e.preventDefault(); win.hide(); } });
  const me = win;
  win.on("closed", () => { if (win === me) { win = null; resetPageState(); } });
}
function replaceWindow() {
  // New BrowserWindow options need a new window; the page reloads in it, as in Claude's app.
  replacing = true;
  const old = win, bounds = old?.getBounds();
  createWindow();
  if (bounds) win.setPosition(bounds.x, bounds.y);
  old?.destroy();
  replacing = false;
}
function resetPageState() {
  for (const p of procs.values()) { try { p.kill("SIGTERM"); } catch {} }
  procs.clear();
  globalShortcut.unregisterAll();
  if (tray) { tray.destroy(); tray = null; }
}
const send = (...args) => { if (win && !win.isDestroyed()) win.webContents.send(...args); };

// ---- IPC: every handler returns a value or { __error: "CODE: detail" } ----
ipcMain.on("config", e => { e.returnValue = { declared: DECLARED, captureIcon: !!CAPTURE_ICON }; });
function handle(channel, fn) {
  ipcMain.handle(channel, async (_e, ...args) => {
    if (!allowed(channel)) return { __error: "EPERM: the page does not declare the permission this needs" };
    try { return await fn(...args); }
    catch (err) { return { __error: `${typeof err.code === "string" ? err.code : "EINVAL"}: ${err.message}` }; }
  });
}
const plainStats = s => ({ size: s.size, mode: s.mode, mtimeMs: s.mtimeMs, ctimeMs: s.ctimeMs, birthtimeMs: s.birthtimeMs,
  isFile: s.isFile(), isDirectory: s.isDirectory(), isSymbolicLink: s.isSymbolicLink() });

handle("fs.readFile", (p, enc) => fsp.readFile(expand(p), enc || undefined));
handle("fs.writeFile", (p, d, enc) => fsp.writeFile(expand(p), d, enc || undefined));
handle("fs.appendFile", (p, d, enc) => fsp.appendFile(expand(p), d, enc || undefined));
handle("fs.readdir", async p => (await fsp.readdir(expand(p), { withFileTypes: true }))
  .map(d => ({ name: d.name, isFile: d.isFile(), isDirectory: d.isDirectory(), isSymbolicLink: d.isSymbolicLink() })));
handle("fs.stat", async p => plainStats(await fsp.stat(expand(p))));
handle("fs.lstat", async p => plainStats(await fsp.lstat(expand(p))));
handle("fs.exists", async p => fs.existsSync(expand(p)));
handle("fs.mkdir", (p, o) => fsp.mkdir(expand(p), o));
handle("fs.rm", (p, o) => fsp.rm(expand(p), o));
handle("fs.rmdir", p => fsp.rmdir(expand(p)));
handle("fs.rename", (a, b) => fsp.rename(expand(a), expand(b)));
handle("fs.copyFile", (a, b) => fsp.copyFile(expand(a), expand(b)));
handle("fs.realpath", p => fsp.realpath(expand(p)));

// ---- processes ----
ipcMain.on("spawn", (_e, id, command, args, options = {}) => {
  if (!allowed("spawn")) { send("proc", id, "error", "EPERM: the page does not declare full-access"); return; }
  let child;
  try {
    child = cp.spawn(command, args || [], { cwd: expand(options.cwd) || os.homedir(), env: { ...process.env, ...options.env }, shell: !!options.shell });
  } catch (err) { send("proc", id, "error", `${err.code || "EINVAL"}: ${err.message}`); return; }
  procs.set(id, child);
  child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
  child.stdout.on("data", c => send("proc", id, "stdout", c));
  child.stderr.on("data", c => send("proc", id, "stderr", c));
  child.on("spawn", () => send("proc", id, "pid", child.pid));
  child.on("error", err => send("proc", id, "error", `${err.code || "EINVAL"}: ${err.message}`));
  child.on("exit", (code, signal) => send("proc", id, "exit", code, signal));
  child.on("close", (code, signal) => { procs.delete(id); send("proc", id, "close", code, signal); });
});
const proc = id => { const c = procs.get(id); if (!c) throw Object.assign(new Error("process has exited"), { code: "ESRCH" }); return c; };
handle("kill", (id, signal = "SIGTERM") => proc(id).kill(signal));
handle("stdin", (id, op, data) => { const c = proc(id); op === "write" ? c.stdin.write(data) : c.stdin.end(); return true; });
handle("exec", (command, o = {}) => new Promise(resolve => {
  const child = cp.exec(command, { cwd: expand(o.cwd) || os.homedir(), env: { ...process.env, ...o.env }, timeout: o.timeout, maxBuffer: 8 * 1024 * 1024 },
    (err, stdout, stderr) => resolve({ stdout, stderr, code: err ? (typeof err.code === "number" ? err.code : null) : 0, signal: err?.signal ?? null, truncated: err?.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" }));
  if (o.input != null) { child.stdin.write(o.input); child.stdin.end(); }
}));

// ---- os, shell, screen ----
handle("os", k => {
  if (k !== "platform" && k !== "arch" && !allowed("fs.")) throw Object.assign(new Error("needs full-access"), { code: "EPERM" });
  const info = { platform: os.platform(), arch: os.arch(), release: os.release(), hostname: os.hostname(), homedir: os.homedir(),
    tmpdir: os.tmpdir(), username: os.userInfo().username, cpus: os.cpus().length, totalmem: os.totalmem(), uptime: os.uptime() };
  return k === "info" ? info : info[k];
});
handle("shell.openPath", async p => { const e = await shell.openPath(expand(p)); if (e) throw new Error(e); });
handle("shell.showItemInFolder", p => shell.showItemInFolder(expand(p)));
handle("shell.trashItem", p => shell.trashItem(expand(p)));
handle("screen.getCursorScreenPoint", () => screen.getCursorScreenPoint());
handle("screen.getAllDisplays", () => screen.getAllDisplays().map(d => ({ id: d.id, label: d.label, bounds: d.bounds, workArea: d.workArea,
  size: d.size, workAreaSize: d.workAreaSize, scaleFactor: d.scaleFactor, rotation: d.rotation, internal: d.internal })));

// ---- window ----
handle("window.setOptions", options => {
  const o = pick(options);
  if (same(o, appliedOptions)) return { applied: "now", reloading: false, options: o };
  savedOptions = o;
  fs.mkdirSync(path.dirname(OPTIONS_FILE), { recursive: true });
  fs.writeFileSync(OPTIONS_FILE, JSON.stringify(o, null, 2));
  if (!CAPTURE_ICON) setImmediate(replaceWindow);
  return { applied: "now", reloading: !CAPTURE_ICON, options: o };
});
handle("window.getOptions", () => ({ options: savedOptions, applied: appliedOptions }));
handle("window.show", () => { if (!win) createWindow(); else { win.show(); win.focus(); } });
handle("window.hide", () => win?.hide());
handle("window.getBounds", () => win.getBounds());
handle("window.setBounds", b => win.setBounds({ ...win.getBounds(), ...b }));
handle("window.place", ({ anchor, margin = 0, width, height }) => {
  if (!win.isVisible() || win.isMinimized()) throw Object.assign(new Error("window is hidden"), { code: "ECANCELED" });
  const [w0, h0] = win.getSize(); win.setSize(width ?? w0, height ?? h0);
  const [w, h] = win.getSize();
  if (anchor) {
    const a = screen.getDisplayMatching(win.getBounds()).workArea;
    const x = anchor === "center" ? a.x + (a.width - w) / 2 : anchor.endsWith("left") ? a.x + margin : a.x + a.width - w - margin;
    const y = anchor === "center" ? a.y + (a.height - h) / 2 : anchor.startsWith("top") ? a.y + margin : a.y + a.height - h - margin;
    win.setPosition(Math.round(x), Math.round(y));
  }
  return { width: w, height: h };
});
handle("window.print", () => new Promise(r => win.webContents.print({}, ok => r(ok))));
handle("window.setIgnoreMouseEvents", (i, o) => win.setIgnoreMouseEvents(i, o));
handle("window.setVisibleOnAllWorkspaces", (v, o) => win.setVisibleOnAllWorkspaces(v, o));

// ---- menus, dock, notifications, shortcuts, tray ----
function buildMenu(items) {
  return Menu.buildFromTemplate(items.map(({ clickId, submenu, href, ...rest }) => ({
    ...rest,
    ...(submenu ? { submenu: buildMenu(submenu) } : {}),
    ...(clickId || href ? { click: item => {
      let opened = false;
      if (href && /^https?:\/\//.test(href)) { shell.openExternal(href); opened = true; }
      if (clickId) send("callback", clickId, { label: item.label, checked: item.checked, role: item.role, opened });
    } } : {}),
  })));
}
const defaultMenu = () => Menu.buildFromTemplate([{ role: "appMenu" }, { role: "editMenu" }, { role: "viewMenu" }, { role: "windowMenu" }]);
handle("menu.setApplicationMenu", t => Menu.setApplicationMenu(t ? Menu.buildFromTemplate([{ role: "appMenu" }, ...buildMenu(t).items]) : defaultMenu()));
handle("menu.popup", t => new Promise(r => buildMenu(t).popup({ window: win, callback: r })));

handle("dock.setIcon", url => {
  const img = nativeImage.createFromDataURL(url);
  if (CAPTURE_ICON) {  // the exporter wants the page's icon for the .app bundle
    fs.mkdirSync(path.dirname(CAPTURE_ICON), { recursive: true });
    fs.writeFileSync(CAPTURE_ICON, img.resize({ width: 1024, height: 1024, quality: "best" }).toPNG());
    setTimeout(() => app.exit(0), 100);
    return { written: true };
  }
  if (process.platform === "darwin") app.dock.setIcon(img);
  return { written: true };
});
handle("dock.setBadge", text => { if (process.platform === "darwin") { app.dock.setBadge(String(text).slice(0, 24)); return true; } return false; });
handle("notification.show", ({ body }) => new Notification({ title: NAME, body: String(body).slice(0, 300) }).show());
handle("shortcut.register", (acc, id) => globalShortcut.register(acc, () => send("callback", id)));
handle("shortcut.unregister", acc => globalShortcut.unregister(acc));
handle("shortcut.unregisterAll", () => globalShortcut.unregisterAll());

handle("tray.set", ({ icon, iconIsTemplate = true, title, toolTip, menu, clickId }) => {
  let img = icon ? nativeImage.createFromDataURL(icon) : nativeImage.createEmpty();
  if (!img.isEmpty()) { img = img.resize({ height: 18, quality: "best" }); img.setTemplateImage(iconIsTemplate); }
  if (!tray) tray = new Tray(img); else tray.setImage(img);
  tray.setTitle(title != null ? String(title).slice(0, 30) : "");
  tray.setToolTip(`${NAME}${toolTip ? "\n" + String(toolTip).slice(0, 100) : ""}`);
  tray.removeAllListeners("click");
  if (menu) tray.setContextMenu(buildMenu(menu));
  else { tray.setContextMenu(null); if (clickId) tray.on("click", () => send("callback", clickId)); }
  return true;
});
handle("tray.remove", () => { if (tray) { tray.destroy(); tray = null; } });

// ---- app lifecycle ----
if (!CAPTURE_ICON && !app.requestSingleInstanceLock()) app.quit();
app.on("second-instance", () => { if (win) { win.show(); win.focus(); } });
app.whenReady().then(() => {
  if (CAPTURE_ICON) { app.dock?.hide(); setTimeout(() => { console.error("The page never set an icon."); app.exit(2); }, 20000); }
  Menu.setApplicationMenu(defaultMenu());
  createWindow();
  app.on("activate", () => { if (!win) createWindow(); else win.show(); });
});
app.on("before-quit", () => { quitting = true; });
app.on("will-quit", () => globalShortcut.unregisterAll());
app.on("window-all-closed", () => { if (process.platform !== "darwin" && !replacing) app.quit(); });
