// Gives the page what Claude's desktop app gives an installed artifact:
// window.claude.use("desktop") resolving the desktop API (see desktop.d.ts in the
// artifact-capabilities skill). Every call goes to main.js over IPC.
const { contextBridge, ipcRenderer } = require("electron");

async function call(channel, ...args) {
  const r = await ipcRenderer.invoke(channel, ...args);
  if (r && r.__error) throw new Error(r.__error);
  return r;
}

// ---- callbacks that live in the page (menu clicks, shortcuts, process output) ----
let nextId = 0;
const callbacks = new Map();
function remember(fn) { const id = ++nextId; callbacks.set(id, fn); return id; }
ipcRenderer.on("callback", (_e, id, payload) => { const fn = callbacks.get(id); if (fn) fn(payload); });

// Menu templates: swap each click function for an id main.js can send back.
function menuForMain(items) {
  return (items || []).map(({ click, submenu, ...rest }) => ({
    ...rest,
    ...(click ? { clickId: remember(click) } : {}),
    ...(submenu ? { submenu: menuForMain(submenu) } : {}),
  }));
}

// ---- child processes ----
const procs = new Map();
ipcRenderer.on("proc", (_e, id, type, a, b) => {
  const p = procs.get(id); if (!p) return;
  if (type === "pid") p.resolvePid(a);
  else for (const fn of p.listeners[type] || []) fn(a, b);
  if (type === "close" || (type === "error" && !p.started)) { p.resolvePid(null); procs.delete(id); }
  if (type === "pid") p.started = true;
});
function spawn(command, args = [], options = {}) {
  const id = ++nextId;
  const listeners = { stdout: [], stderr: [], exit: [], close: [], error: [] };
  let resolvePid; const pid = new Promise(r => (resolvePid = r));
  procs.set(id, { listeners, resolvePid, started: false });
  ipcRenderer.send("spawn", id, command, args, options);
  const on = type => (event, fn) => { if (event === "data") listeners[type].push(fn); };
  return {
    pid,
    stdout: { on: on("stdout") },
    stderr: { on: on("stderr") },
    on(event, fn) { if (listeners[event]) listeners[event].push(fn); },
    kill: signal => pid.then(() => call("kill", id, signal)),
    stdin: {
      write: data => pid.then(() => call("stdin", id, "write", data)),
      end: () => pid.then(() => call("stdin", id, "end")),
    },
  };
}

// A standalone app has nothing to ask: what it does is what you built and installed.
// The page's manifest still decides what it gets: a permission it didn't declare reads "unavailable".
// In icon-capture mode (the exporter grabbing the page's icon) nothing is granted, so the page stays idle.
const config = ipcRenderer.sendSync("config");
const PERMISSIONS = ["notifications", "shortcuts", "overlay", "menu-bar", "full-access"];
const permState = p => (!config.declared.includes(p) ? "unavailable" : config.captureIcon ? "prompt" : "granted");
const allStates = () => Object.fromEntries(PERMISSIONS.map(p => [p, permState(p)]));

const desktop = {
  install: { state: async () => "installed", request: async () => "installed" },
  permissions: {
    state: async name => (name ? (PERMISSIONS.includes(name) ? permState(name) : "unavailable") : allStates()),
    request: async () => allStates(),
    manage: async () => {},
  },
  window: {
    setOptions: options => call("window.setOptions", options),
    getOptions: () => call("window.getOptions"),
    place: placement => call("window.place", placement),
    show: () => call("window.show"),
    hide: () => call("window.hide"),
    getBounds: () => call("window.getBounds"),
    setBounds: b => call("window.setBounds", b),
    print: () => call("window.print"),
    setIgnoreMouseEvents: (ignore, o) => call("window.setIgnoreMouseEvents", ignore, o),
    setVisibleOnAllWorkspaces: (v, o) => call("window.setVisibleOnAllWorkspaces", v, o),
  },
  Menu: {
    setApplicationMenu: t => call("menu.setApplicationMenu", t ? menuForMain(t) : null),
    popup: t => call("menu.popup", menuForMain(t)),
  },
  app: {
    dock: {
      setIcon: url => call("dock.setIcon", url),
      setBadge: text => call("dock.setBadge", text),
      setProgress: async () => false,
      setMenu: async () => false,
    },
  },
  fs: {
    readFile: (p, enc) => call("fs.readFile", p, enc),
    writeFile: (p, d, enc) => call("fs.writeFile", p, d, enc),
    appendFile: (p, d, enc) => call("fs.appendFile", p, d, enc),
    readdir: p => call("fs.readdir", p),
    stat: p => call("fs.stat", p),
    lstat: p => call("fs.lstat", p),
    exists: p => call("fs.exists", p),
    mkdir: (p, o) => call("fs.mkdir", p, o),
    rm: (p, o) => call("fs.rm", p, o),
    rmdir: p => call("fs.rmdir", p),
    rename: (a, b) => call("fs.rename", a, b),
    copyFile: (a, b) => call("fs.copyFile", a, b),
    realpath: p => call("fs.realpath", p),
  },
  childProcess: {
    exec: (command, options) => call("exec", command, options),
    spawn,
  },
  pty: { spawn() { throw new Error("ENOSYS: no terminal in the standalone build"); } },
  os: Object.fromEntries(["platform", "arch", "info", "release", "hostname", "homedir", "tmpdir", "username", "cpus", "totalmem", "uptime"]
    .map(k => [k, () => call("os", k)])),
  shell: {
    openPath: p => call("shell.openPath", p),
    showItemInFolder: p => call("shell.showItemInFolder", p),
    trashItem: p => call("shell.trashItem", p),
  },
  screen: {
    getCursorScreenPoint: () => call("screen.getCursorScreenPoint"),
    getAllDisplays: () => call("screen.getAllDisplays"),
  },
  globalShortcut: {
    register: (acc, fn) => call("shortcut.register", acc, remember(fn)),
    unregister: acc => call("shortcut.unregister", acc),
    unregisterAll: () => call("shortcut.unregisterAll"),
  },
  notification: { show: o => call("notification.show", o) },
  tray: {
    set: ({ click, menu, ...rest }) => call("tray.set", {
      ...rest,
      ...(menu ? { menu: menuForMain(menu) } : {}),
      ...(click ? { clickId: remember(click) } : {}),
    }),
    remove: () => call("tray.remove"),
  },
};

contextBridge.exposeInMainWorld("claude", {
  use: async name => (name === "desktop" ? desktop : null),
});
