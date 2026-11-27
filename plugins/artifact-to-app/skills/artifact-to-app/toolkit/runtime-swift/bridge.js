// Injected at document start by the Swift shell. Gives the page what Claude's desktop app
// gives an installed artifact: claude.use("desktop") resolving the desktop API (desktop.d.ts).
// Calls go to Desktop.swift through window.webkit.messageHandlers.desktop (which returns a
// promise); native events come back through window.__artifactDesktop.event(kind, payload).
(() => {
  const CONFIG = window.__ARTIFACT_CONFIG__ || { declared: [], captureIcon: false };
  delete window.__ARTIFACT_CONFIG__;
  const channel = window.webkit.messageHandlers.desktop;

  // ---- bytes cross the bridge as {__b64} ----
  const toB64 = u8 => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
  const fromB64 = b64 => Uint8Array.from(atob(b64), c => c.charCodeAt(0));
  const enc = v => (v instanceof Uint8Array ? { __b64: toB64(v) } : v === undefined ? null : v);
  const dec = v => (v && typeof v === "object" && typeof v.__b64 === "string" ? fromB64(v.__b64) : v);
  const call = (op, ...args) => channel.postMessage({ op, args: args.map(enc) }).then(dec);
  const log = (level, ...parts) => { try { channel.postMessage({ op: "log", args: [level, parts.map(p => (p instanceof Error ? p.stack || p.message : typeof p === "string" ? p : JSON.stringify(p))).join(" ")] }).catch(() => {}); } catch {} };
  for (const level of ["error", "warn"]) { const orig = console[level].bind(console); console[level] = (...a) => { log(level, ...a); orig(...a); }; }
  addEventListener("error", e => log("error", e.message, `${e.filename}:${e.lineno}`));
  addEventListener("unhandledrejection", e => log("error", "unhandled rejection:", e.reason));

  // ---- callbacks that live in the page (menu clicks, shortcuts, tray presses) ----
  let nextId = 0;
  const callbacks = new Map();
  const remember = fn => { const id = ++nextId; callbacks.set(id, fn); return id; };
  const menuForNative = items => (items || []).map(({ click, submenu, ...rest }) => ({
    ...rest,
    ...(click ? { clickId: remember(click) } : {}),
    ...(submenu ? { submenu: menuForNative(submenu) } : {}),
  }));

  // ---- child processes ----
  const procs = new Map();
  function spawn(command, args = [], options = {}) {
    const id = ++nextId;
    const listeners = { stdout: [], stderr: [], exit: [], close: [], error: [] };
    const emit = (type, a, b) => { for (const fn of listeners[type]) { try { fn(a, b); } catch (e) { console.error(e); } } };
    procs.set(id, emit);
    const pid = call("spawn", id, command, args, options).catch(e => { procs.delete(id); setTimeout(() => emit("error", e)); return null; });
    const on = type => (event, fn) => { if (event === "data") listeners[type].push(fn); };
    return {
      pid,
      stdout: { on: on("stdout") },
      stderr: { on: on("stderr") },
      on(event, fn) { if (listeners[event]) listeners[event].push(fn); },
      kill: signal => pid.then(() => call("kill", id, signal || "SIGTERM")),
      stdin: {
        write: data => pid.then(() => call("stdin", id, "write", data)),
        end: () => pid.then(() => call("stdin", id, "end")),
      },
    };
  }

  // ---- native title-bar metrics as CSS variables (see Titlebar.swift) ----
  // --titlebar-inset-left, --titlebar-height, --titlebar-font, --titlebar-color. A page uses them with its own
  // fallback, e.g. padding-left: var(--titlebar-inset-left, 84px), so it looks the same in Claude's app.
  let metrics = CONFIG.metrics || null;
  function applyMetrics() {
    const root = document.documentElement;
    if (!root || !metrics) return;
    const set = (k, v) => (v ? root.style.setProperty(k, v) : root.style.removeProperty(k));
    set("--titlebar-inset-left", metrics.insetLeft > 0 ? metrics.insetLeft + "px" : "");
    set("--titlebar-height", metrics.height > 0 ? metrics.height + "px" : "");
    set("--titlebar-font", metrics.font);
    set("--titlebar-color", metrics.color);
  }
  if (document.documentElement) applyMetrics();
  else new MutationObserver((_, o) => { if (document.documentElement) { o.disconnect(); applyMetrics(); } }).observe(document, { childList: true });

  // Where the page's title-bar content starts, for the exporter's warning (sent from the icon-capture run).
  function titlebarReport() {
    const cs = getComputedStyle(document.documentElement);
    const inset = parseFloat(cs.getPropertyValue("--titlebar-inset-left")) || 0;
    const height = parseFloat(cs.getPropertyValue("--titlebar-height")) || 60;
    selectors ||= dragSelectors();
    let left = Infinity, element = "";
    for (const band of matching(selectors.drag)) {
      const b = band.getBoundingClientRect();
      if (b.top > 1 || !b.height) continue;
      for (const el of band.querySelectorAll("*")) {
        const r = el.getBoundingClientRect();
        if (!r.width || !r.height || r.top > height) continue;
        const own = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) || /^(img|svg|canvas|button|input|select|picture)$/i.test(el.tagName);
        if (own && r.left < left) { left = r.left; element = el.tagName.toLowerCase() + (typeof el.className === "string" && el.className ? "." + el.className.trim().split(/\s+/)[0] : ""); }
      }
    }
    return { insetLeft: inset, contentLeft: Number.isFinite(left) ? Math.round(left * 10) / 10 : null, element };
  }

  // ---- window drag regions: WebKit ignores app-region, so tell the shell where they are ----
  function dragSelectors() {
    const drag = [], noDrag = [];
    const sheets = [...document.querySelectorAll("style")].map(s => s.textContent.replace(/\/\*[\s\S]*?\*\//g, ""));
    for (const css of sheets) {
      const re = /([^{}]+)\{([^{}]*)\}/g; let m;
      while ((m = re.exec(css))) {
        const sel = m[1].trim(), v = m[2].match(/(?:-webkit-)?app-region\s*:\s*(no-drag|drag)\b/);
        if (v && !sel.startsWith("@")) (v[1] === "drag" ? drag : noDrag).push(sel);
      }
    }
    for (const el of document.querySelectorAll("[style*='app-region']")) {
      const v = el.getAttribute("style").match(/(?:-webkit-)?app-region\s*:\s*(no-drag|drag)\b/);
      if (v) (v[1] === "drag" ? drag : noDrag).push(el);
    }
    return { drag, noDrag };
  }
  let selectors = null, lastRegions = "", pending = false;
  const matching = list => list.flatMap(s => { if (s instanceof Element) return [s]; try { return [...document.querySelectorAll(s)]; } catch { return []; } });
  function sendRegions() {
    pending = false;
    if (!document.body) return;
    selectors ||= dragSelectors();
    const els = matching;
    const rect = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 ? [r.left, r.top, r.width, r.height] : null; };
    const dragEls = els(selectors.drag);
    // Controls inside a drag region stay clickable even if the page forgot to mark them no-drag.
    const controls = dragEls.flatMap(d => [...d.querySelectorAll("button, input, select, textarea, a[href], label, [contenteditable], [role=button]")]);
    const regions = { drag: dragEls.map(rect).filter(Boolean), noDrag: [...els(selectors.noDrag), ...controls].map(rect).filter(Boolean) };
    const json = JSON.stringify(regions);
    if (json !== lastRegions) { lastRegions = json; call("drag.regions", regions).catch(() => {}); }
  }
  const schedule = () => { if (!pending) { pending = true; requestAnimationFrame(sendRegions); } };
  document.addEventListener("DOMContentLoaded", () => {
    // An app window shouldn't rubber-band: with a hidden title bar the page's own title bar would bounce too.
    // Scrolling areas inside the page keep their own behavior.
    const noBounce = document.createElement("style");
    noBounce.textContent = "html, body { overscroll-behavior: none; }";
    document.head.prepend(noBounce);
    selectors = dragSelectors();
    schedule();
    applyMetrics();
    // Opt-in: let macOS draw the window title itself, centered, in the native font and color.
    if (document.querySelector('meta[name="artifact-app:titlebar"][content~="native-title"]')) call("window.nativeTitle", document.title || "").catch(() => {});
    if (CONFIG.captureIcon) {
      const send = () => call("report", titlebarReport()).catch(() => {});
      (document.fonts ? document.fonts.ready : Promise.resolve()).then(() => setTimeout(send, 400));
    }
    new MutationObserver(m => { if (m.some(r => r.target.nodeName === "STYLE" || [...r.addedNodes].some(n => n.nodeName === "STYLE"))) selectors = null; schedule(); })
      .observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
    new ResizeObserver(schedule).observe(document.documentElement);
    addEventListener("scroll", schedule, true);
    addEventListener("resize", schedule);
  });

  // ---- events from the shell ----
  Object.defineProperty(window, "__artifactDesktop", { value: Object.freeze({
    event(kind, p) {
      if (kind === "callback") callbacks.get(p.id)?.(p.payload ?? undefined);
      else if (kind === "metrics") { metrics = p; applyMetrics(); schedule(); }
      else if (kind === "proc") { const emit = procs.get(p[0]); if (emit) { emit(p[1], p[2] ?? null, p[3] ?? null); if (p[1] === "close") procs.delete(p[0]); } }
    },
  }) });

  // ---- the desktop namespace ----
  // A standalone app has nothing to ask: what the page declares in its manifest is granted,
  // anything else is "unavailable". In icon-capture mode nothing is granted, so the page stays idle.
  const PERMISSIONS = ["notifications", "shortcuts", "overlay", "menu-bar", "full-access"];
  const permState = p => (!CONFIG.declared.includes(p) ? "unavailable" : CONFIG.captureIcon ? "prompt" : "granted");
  const allStates = () => Object.fromEntries(PERMISSIONS.map(p => [p, permState(p)]));
  const fn = op => (...a) => call(op, ...a);

  const desktop = Object.freeze({
    install: Object.freeze({ state: async () => "installed", request: async () => "installed" }),
    permissions: Object.freeze({
      state: async name => (name ? (PERMISSIONS.includes(name) ? permState(name) : "unavailable") : allStates()),
      request: async () => allStates(),
      manage: async () => {},
    }),
    window: Object.freeze(Object.fromEntries(["setOptions", "getOptions", "place", "show", "hide", "getBounds", "setBounds", "print",
      "setIgnoreMouseEvents", "setVisibleOnAllWorkspaces"].map(k => [k, fn("window." + k)]))),
    Menu: Object.freeze({
      setApplicationMenu: t => call("menu.setApplicationMenu", t ? menuForNative(t) : null),
      popup: t => call("menu.popup", menuForNative(t)),
    }),
    app: Object.freeze({ dock: Object.freeze({
      setIcon: fn("dock.setIcon"), setBadge: fn("dock.setBadge"),
      setProgress: async () => false, setMenu: async () => false,
    }) }),
    fs: Object.freeze(Object.fromEntries(["readFile", "writeFile", "appendFile", "readdir", "stat", "lstat", "exists", "mkdir", "rm",
      "rmdir", "rename", "copyFile", "realpath"].map(k => [k, fn("fs." + k)]))),
    childProcess: Object.freeze({ exec: fn("exec"), spawn }),
    pty: Object.freeze({ spawn() { throw new Error("ENOSYS: no terminal in the standalone build"); } }),
    os: Object.freeze(Object.fromEntries(["platform", "arch", "info", "release", "hostname", "homedir", "tmpdir", "username", "cpus",
      "totalmem", "uptime"].map(k => [k, () => call("os", k)]))),
    shell: Object.freeze({ openPath: fn("shell.openPath"), showItemInFolder: fn("shell.showItemInFolder"), trashItem: fn("shell.trashItem") }),
    screen: Object.freeze({ getCursorScreenPoint: fn("screen.getCursorScreenPoint"), getAllDisplays: fn("screen.getAllDisplays") }),
    globalShortcut: Object.freeze({
      register: (acc, cb) => call("shortcut.register", acc, remember(cb)),
      unregister: fn("shortcut.unregister"),
      unregisterAll: fn("shortcut.unregisterAll"),
    }),
    notification: Object.freeze({ show: fn("notification.show") }),
    tray: Object.freeze({
      set: ({ click, menu, ...rest }) => call("tray.set", {
        ...rest,
        ...(menu ? { menu: menuForNative(menu) } : {}),
        ...(click ? { clickId: remember(click) } : {}),
      }),
      remove: fn("tray.remove"),
    }),
  });

  Object.defineProperty(window, "claude", { value: Object.freeze({ use: async name => (name === "desktop" ? desktop : null) }) });
})();
