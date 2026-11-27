---
name: artifact-to-app
description: Export a Claude desktop-app artifact (one built on the `desktop` capability and installed with "Install as app") as a standalone macOS app that runs without Claude, and install it in /Applications. Use when the user asks to make an artifact app standalone, export or package it as a real .app, run it without Claude, or update an earlier standalone export after the artifact changed (e.g. "make Display Switcher standalone", "rebuild the Officer VM Panel app").
---

# Artifact → standalone app

The toolkit ships with this skill, in `toolkit/` under this skill's base directory (the path given when the skill loads). Below, `$TOOLKIT` means that folder. Always use the absolute path, quoted.

It has two runtimes. Each provides `window.claude.use("desktop")`, the same API Claude's desktop app gives installed artifacts: fs, childProcess, notifications, tray, dock, window, menus and shortcuts.
- **`runtime-swift/` (the default).** A native AppKit shell that runs the page in WKWebView.
  - Apps are about 1 MB and feel like Mac apps.
  - The page renders with WebKit (Safari's engine), not Chromium.
  - `bridge.js` gives the page the API; `Desktop.swift` carries it out.
  - CSS `app-region` drag areas are emulated, and the page doesn't rubber-band.
- **`runtime/` (Electron).** The page runs in bundled Chromium, exactly as in Claude's desktop app, but each app is about 270 MB. Use it with `--runtime electron` when a page renders or behaves wrong in WebKit, or the user asks for it.

`export.mjs` turns a saved artifact page into an app project, builds it and installs it.

## Requirements (check once if an export fails)
- macOS 13 or later.
- Node 18 or later.
- Apple's Command Line Tools (`swiftc`). If they're missing, the user installs them with `xcode-select --install`.
- Network access on the first export of a page, to download its Google Fonts.
- npm, only for `--runtime electron`.

## Project folders
Each exported app gets its own project folder, outside the plugin, conventionally `~/Projects/<Name>App`. It holds:
- `source.html`: the artifact page, unedited;
- `artifact-app.json`: what was exported;
- everything the exporter generates, so never hand-edit `app/` there.

To find an existing project, look for `artifact-app.json` files whose `title` matches (for example `grep -l '"title": "<Title>"' ~/Projects/*/artifact-app.json`). Otherwise ask where to put a new one, or use `~/Projects/<Name>App`; never reuse a folder that holds something else.

The compiled Swift shell is cached in `~/Library/Caches/ArtifactApp`. It is rebuilt automatically (about a minute) when the runtime sources change, such as after a plugin update.

## Steps

1. **Find the artifact.** Use `Artifact` `action: "list"`, or the URL the user gave. It must declare `desktop`. Reading it without `path` shows the stored capabilities.
2. **Save the page.** Use `Artifact` `action: "read"`, `path: "index.html"`, with `out_dir` in the scratchpad. Copy the file to `<project>/source.html`.
3. **Export and install.** Run `node "$TOOLKIT/export.mjs" <project> --install --open`. This takes about 10 seconds, plus about a minute when the shell needs compiling. The exporter:
   - bundles Google Fonts locally;
   - writes `artifact-app.json`;
   - builds `dist/swift/<Name>.app` and signs it ad hoc;
   - captures the page's own icon by running it once in a mode where nothing is granted;
   - installs and launches the app.

   `--install` quits the running app (wherever it runs from) and replaces `/Applications/<Name>.app`. It only replaces an earlier export with the same bundle id, from either runtime; if something else has that name, it stops and says so. In that case ask the user, and don't delete it yourself.

   Leave out `--install` only if the user says not to install. `--runtime electron` uses Electron instead (`--dmg` makes a disk image there). `--no-build` only regenerates `app/`.
4. **Read the warnings.** If the exporter says title-bar content starts left of where the window buttons end, the fix goes in the artifact (see "Title bar" below). Make that change in the artifact, republish it, update `source.html` and export again: a fallback keeps the page unchanged in Claude's app.

   Then the capability warnings. The page may use capabilities other than `desktop`: `sample`, `db`, `mcp`, `artifact`, `user` and so on. Those need Claude, and `claude.use()` returns `null` for them in the standalone app. Tell the user which features of the page will be missing. Also report `desktop.pty` (not provided) and any assets still loaded from the network.
5. **Verify.**
   - With computer use, `request_access` the app's bundle id (`local.artifact.<slug>`) and take an `app_screenshot`. Check that it shows live data, not the page's example rows or "install" notice.
   - The first screenshot of a fresh WKWebView window can come back blank; take another after a few seconds.
   - Click one harmless control, such as Refresh, to confirm clicks reach the page.
   - If something is off, run `ARTIFACT_APP_DEBUG=1 "/Applications/<Name>.app/Contents/MacOS/<Name>"` from a terminal. It logs navigation, drag areas, clicks, window-button layout and page measurements (`console.error` and uncaught errors from the page always go to stderr).
   - A web inspector is available: Safari → Develop → the app's name.
   - Simulated drags and scrolls don't behave like real ones. Ask the user to try dragging the title bar and scrolling.
6. **Report** that it's installed in /Applications, with anything that differs from the Claude-installed version.

## Title bar (the page's part)
The shell sets these CSS variables on `<html>` and keeps them current. They're read from AppKit, not guessed:

| Variable | Value |
| --- | --- |
| `--titlebar-inset-left` | where title-bar content may start: right of the window buttons plus 12 pt |
| `--titlebar-height` | the title bar's height |
| `--titlebar-font` | the native title font as a CSS shorthand (`NSFont.titleBarFont`: system font, 13 pt, bold) |
| `--titlebar-color` | the title color native windows show: `windowFrameTextColor` at 61% (measured and tuned by eye against native titles, which appear lighter than AppKit's 85% because they're drawn over the title-bar material), or `tertiaryLabelColor` while the window is inactive, for light or dark mode |

Two classes on `<html>`: `artifact-app` always, and `artifact-native-title` while the shell draws the window title. Claude's app sets neither.

A page uses them with its own value as the fallback, so it looks unchanged in Claude's app, which doesn't set them:
```css
.desktop .bar { padding-left: var(--titlebar-inset-left, 84px); }
.bar h1 { font: var(--titlebar-font, 600 14px var(--sans)); color: var(--titlebar-color, var(--fg)); }
```
If the bar sits inside a padded container, subtract that padding: `calc(var(--titlebar-inset-left, 86px) - 16px)`.

**Native centered title.** With `<meta name="artifact-app:titlebar" content="native-title">` the shell draws the page's `<title>` centered in the title bar, in the native font and colors. Clicks and drags go through it to the page. The page hides its own title only in the standalone app, so Claude's version keeps it:
```css
html.artifact-native-title .bar h1 { display: none; }
```
It's opt-in: the shell never guesses which element is the title.

**Policy for title bars** (apply it when exporting, and propose it for the artifact):
- A title bar that holds just the app's title plus a few small controls on the right (a status, a pin, a refresh) gets the native centered title. The page's own title and any icon next to it are hidden in the standalone app; the controls stay on the right.
- A title bar full of controls (pills, stats, several buttons) keeps the page's own left-aligned title, styled with `--titlebar-font` and `--titlebar-color`.
- Either way the page pads its title bar with `--titlebar-inset-left`.

During the icon-capture run the page reports where its title-bar content starts. The exporter prints `title bar: content starts at X pt, buttons need Y pt`, or a warning when X < Y. With a native centered title it also checks that no title-bar content runs into the title, and warns if any does.

## How the standalone app behaves (tell the user when relevant)
- **Permissions:** whatever the page lists in its `claude-artifacts-manifest` tag is granted without asking. Undeclared permissions are refused with EPERM, as in Claude.
- **Notifications** are macOS's own: the first one asks the person to allow them.
- **Window options:** the page sets them with `window.setOptions`. They are applied live and saved in `~/Library/Application Support/<Name>/window-options.json`. The size the person leaves the window at is kept between launches.
- **Window buttons:** with `hiddenInset` or a `trafficLightPosition`, they're centered on the page's real title bar (its top drag area). They go where macOS puts them in a unified-toolbar window like Notes or Photos, measured at runtime (19 pt in, 23 pt apart on macOS 26), or at the page's `trafficLightPosition.x`. The page's `y` is only used when the page reports no title bar.
- **Window size:** the page's size applies on first launch and whenever the page asks for a new one; otherwise the size the person left is kept. A non-resizable window always gets the page's size.
- **Scrolling:** the Swift shell switches off page-level rubber-band bounce (`overscroll-behavior: none` on html and body), so a hidden title bar doesn't bounce with the content. A page whose content is taller than its window still scrolls; that's the page's layout, and the fix belongs in the artifact (for example a larger `height` in `window.setOptions`).
- **Closing:** an app with a menu bar item keeps running when its window is closed or hidden by the page; clicking the Dock icon or the menu bar item brings it back. Cmd+Q, or quitting from the Dock, quits. An app without one quits with its window.
- **Not covered:** `pty` (rejects ENOSYS); Dock progress and menu.
- **Updates:** the app doesn't follow republished versions of the artifact. Re-run steps 2–3 to update it.
- **Signing:** apps are signed ad hoc, not with a developer ID. They're fine on the Mac that built them; on another Mac, right-click and choose Open the first time, and macOS may refuse them. Sharing built apps properly needs an Apple Developer ID to sign and notarize them.

## Changing the toolkit
Runtime and exporter changes go in `$TOOLKIT` in the plugin's source repository, not in the installed copy, which updates replace. After a change, re-export each app.
