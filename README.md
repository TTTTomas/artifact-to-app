# artifact-to-app

A Claude Code plugin that turns a **Claude desktop-app artifact** into a standalone **macOS app** that runs without Claude.

A desktop-app artifact is a page published with the `desktop` capability and installed from the Claude desktop app with "Install as app". This plugin takes such a page and builds a real `.app` from it:
- about 1 MB, using a native Swift shell around WKWebView;
- the page gets the same `claude.use("desktop")` API it has in Claude: files, processes, menu bar item, notifications, Dock, window options and global shortcuts;
- it's installed in `/Applications`.

## Install

In Claude Code:

```
/plugin marketplace add TTTTomas/artifact-to-app
/plugin install artifact-to-app@artifact-app
```

Then ask Claude things like:
- "make my Display Switcher artifact a standalone app"
- "rebuild the standalone app, I changed the artifact"

You can also type `/artifact-to-app`.

### Requirements
- macOS 13 or later.
- Node 18 or later.
- Apple's Command Line Tools: `xcode-select --install`.
- Network access on the first export of a page, to download its Google Fonts.
- npm, only if you use `--runtime electron`.

## What happens

Claude saves the artifact's page into a project folder of your choice, as `source.html`, and runs the exporter:

```bash
node plugins/artifact-to-app/skills/artifact-to-app/toolkit/export.mjs ~/Projects/MyAppApp --install --open
```

| Output in the project folder | What it is |
| --- | --- |
| `artifact-app.json` | title, bundle id, runtime and version of the export |
| `app/index.html`, `app/fonts/` | the page, with Google Fonts downloaded and linked locally |
| `build/icon.png` | the icon the page draws itself (captured by running it once) |
| `dist/swift/<Name>.app` | the app (about 1 MB), signed ad hoc |
| `dist/mac-*/`, `main.js`, `preload.js`, `package.json`, `node_modules/` | only with `--runtime electron` (about 270 MB, plus build tools) |

**Options**
- **`--install`:** quits the running app and replaces `/Applications/<Name>.app`. It only replaces an earlier export of the same app (same bundle id) and refuses anything else.
- **`--open`:** launches the installed app.

**Updating an app:** replace `source.html` and run the exporter again. Apps don't follow republished artifacts on their own.

## Title bar

With a hidden title bar, the window buttons sit where macOS puts them, measured at runtime from a unified-toolbar window. The page's title bar is drawn by the page. The shell tells it where it may start and how a native title looks, through CSS variables on `<html>`: `--titlebar-inset-left`, `--titlebar-height`, `--titlebar-font` and `--titlebar-color`. Use them with your current values as fallbacks, so the page also looks right in Claude's app:

```css
.desktop .bar { padding-left: var(--titlebar-inset-left, 84px); }
.bar h1 { font: var(--titlebar-font, 600 14px var(--sans)); color: var(--titlebar-color, var(--fg)); }
```

The exporter measures each page and warns when its title-bar content starts under the buttons.

For a native centered title, a page adds `<meta name="artifact-app:titlebar" content="native-title">` and hides its own title in the standalone app with `html.artifact-native-title .bar h1 { display: none; }`. Claude's app never sets that class, so the page keeps its own title there. The exporter warns if title-bar controls run into the centered title.

**Frameless windows.** `frame: false` (with the `overlay` permission) gives a window without buttons that keeps macOS's rounded corners and shadow, which suits menu bar panels.

**Rules of thumb:**
- A title bar with just a title and a few small controls looks most native with the centered title. A bar full of controls keeps its own left-aligned title.
- A blended title bar (no divider) hands over to the content at its bottom edge, with no extra gap; the exporter warns when it doesn't. With a visible divider, normal spacing below the line is fine.

## Runtimes

Both runtimes grant exactly the permissions the page declares in its `claude-artifacts-manifest`; anything else is refused with `EPERM`. `claude.use()` returns `null` for capabilities other than `desktop` (`sample`, `db`, `mcp`, …), because those need Claude. Neither runtime provides `pty` or Dock progress and menu.

### Swift (default): `toolkit/runtime-swift/`
| File | Role |
| --- | --- |
| `bridge.js` | Injected at document start. It builds the desktop namespace, posts calls to the shell (replies come back as promises), reports CSS `app-region` drag areas (WebKit ignores them) and switches off page bounce. |
| `Desktop.swift` | Carries out each call: files (POSIX), processes (`Process` with streamed output), the menu bar item (`NSStatusItem`), notifications (`UNUserNotificationCenter`), global shortcuts (Carbon hot keys) and Dock icon and badge. |
| `Shell.swift` | The window and WKWebView. The page is served from the bundle as `artifact://app/…`. Window options are applied live, the window buttons are inset for `hiddenInset`, drag areas move the window, and links open in the browser. |
| `Titlebar.swift` | Native title-bar metrics read from AppKit: button position and spacing, title font and colors. |
| `Menus.swift` | Electron-style menu templates and the default menus. |
| `main.swift` | App startup and config. |

The shell is compiled once into `~/Library/Caches/ArtifactApp/swift` and reused until its sources change. Each `.app` is assembled around that binary: Info.plist, `Resources/app`, `bridge.js` and `app-config.json`, an `.icns` made from the page's own icon, and an ad-hoc signature.

**Debugging.** `ARTIFACT_APP_DEBUG=1 "/Applications/<Name>.app/Contents/MacOS/<Name>"` logs navigation, drag areas, clicks and layout. Page errors always go to stderr. To inspect the page, use Safari → Develop → `<Name>`.

### Electron: `toolkit/runtime/`
`--runtime electron` runs the page in bundled Chromium, exactly as Claude's desktop app does. Use it when a page renders or behaves wrong in WebKit.

## Sharing built apps
Exported apps are signed ad hoc. They run on the Mac that built them; on another Mac, macOS asks for a right-click → Open the first time, and may refuse them. To hand built apps to other people, sign and notarize them with an Apple Developer ID.

## License

MIT © 2026 Tomas Berg. See [LICENSE](LICENSE).
