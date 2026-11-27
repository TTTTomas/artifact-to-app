---
name: desktop-app-style
description: Style rules for desktop-app artifacts, pages that call claude.use("desktop") and are installed as Mac apps (from Claude's app, or exported with artifact-to-app), so they look and behave like native macOS apps. Use whenever you build, restyle or fix such an artifact (a Mac app, menu bar app, floating widget, or a page that runs commands or reads files without a picker), when the artifact-to-app hook or exporter reports style findings, or when the user says an app's title bar, window buttons, spacing or window behavior looks off.
---

# Desktop-app artifact style

Rules for pages that run as Mac apps. They come from comparing exported apps with native ones side by side. Each rule has a name; the exporter's `--check` and the publish hook report findings under these names.

Two principles:
- **The page owns what's inside the window; the shell owns the window.** The shell (Claude's app, or the artifact-to-app Swift shell) places the window buttons and measures native metrics. The page lays out its content and reads those metrics.
- **Always keep a fallback.** Claude's app doesn't set the `--titlebar-*` variables or the `artifact-*` classes. Every rule uses `var(--x, <the page's own value>)` or a class only the standalone shell sets, so the page looks unchanged, or better, in Claude's app.

## What the standalone shell gives the page
| Name | What it is |
| --- | --- |
| `--titlebar-inset-left` | where title-bar content may start: right of the window buttons plus 12 pt (macOS's own button position, measured at runtime) |
| `--titlebar-height` | the title bar's height |
| `--titlebar-font` | the native title font as a CSS shorthand (system font, 13 pt, bold) |
| `--titlebar-color` | the native title color for the window's state: active about 61% of the label color, inactive tertiary; light or dark |
| `html.artifact-app` | set in a standalone app |
| `html.artifact-native-title` | set while the shell draws the window title |

## Rules

### titlebar-inset
With a hidden title bar (`titleBarStyle: "hidden"` or `"hiddenInset"`, or a `trafficLightPosition`), the page's title-bar content must start right of the window buttons. Don't hard-code that padding:
```css
.desktop .bar { padding-left: var(--titlebar-inset-left, 84px); }
/* inside a container that already has 16px side padding: */
.desktop .bar { padding-left: calc(var(--titlebar-inset-left, 86px) - 16px); }
```

### title-style
A title the page draws itself should look like a native window title: not bigger, bolder or blacker.
```css
.bar h1 { margin: 0; font: var(--titlebar-font, 600 14px var(--sans)); color: var(--titlebar-color, var(--fg)); }
```

### native-title
Choose by what the title bar holds:
- **Just the app's title plus a few small controls** (a status, a pin, a refresh): use the native centered title. Add the meta tag and hide the page's own title, and any icon next to it, only in the standalone app:
  ```html
  <meta name="artifact-app:titlebar" content="native-title">
  ```
  ```css
  html.artifact-native-title .bar h1 { display: none; }
  ```
  Keep the small controls on the right (`margin-left: auto`), clear of the centered title. The check warns if anything runs into it.
- **A bar full of controls** (status pills, stats, several buttons): keep the page's own left-aligned title, styled per **title-style**.

An app icon doesn't belong in the title bar; native apps don't put one there.

### blended-titlebar
A title bar with no divider (no bottom border or shadow, no background of its own) blends into the content. The content then starts right at the bar's bottom edge, with no extra gap: the bar's own height already gives the title equal room above and below. If the page's layout puts a gap after every block, take it back on the bar:
```css
.desktop .bar { margin-bottom: -14px; }   /* the parent's gap */
```
With a visible divider, normal spacing below the line is fine.

### fits-window
The whole page shouldn't scroll. Make the `height` in `window.setOptions` fit the content: not taller than the window (the window scrolls and the title bar moves), and not much shorter (an empty band at the bottom). If the content can grow, make one inner area scroll (`overflow: auto` on a list or console) and keep the page itself fixed. After changing the layout, recheck the height.

### menu-bar-panel
A page with a menu bar item (`tray.set`) whose window is opened from that item and hides when it loses focus is a menu bar panel. Panels:
- have no window buttons: `frame: false` in `setOptions`. That needs the `"overlay"` permission in the manifest (see **overlay-permission**), and the window keeps macOS's rounded corners and shadow;
- use their own padding in the title bar, since there are no buttons to clear;
- hide on `blur`, with a pin to keep them open, and show from the menu bar item;
- size themselves exactly, with `resizable: false`.

### overlay-permission
`frame: false`, `transparent: true` and `alwaysOnTop: true` need `"overlay"` in the page's manifest:
```html
<script type="application/json" id="claude-artifacts-manifest">{"permissions": ["full-access", "menu-bar", "overlay"]}</script>
```
Without it, `setOptions` is refused and the window keeps its frame. In Claude's app, a newly declared permission asks once.

## Checking a page
1. **Static checks** run automatically: the plugin's publish hook checks every desktop-app page you publish, and reports findings under the rule names above.
2. **Measured checks** (title-bar positions, the gap under the bar, overlap with a centered title, window height): save the page as `source.html` in an empty scratch folder and run
   ```
   node "<plugin>/skills/artifact-to-app/toolkit/export.mjs" <folder> --check
   ```
   The toolkit is in the sibling `artifact-to-app` skill. This needs macOS with the Command Line Tools and installs nothing. Window height is measured before any permission is granted, so the page may show a notice or example data it won't show live. That's why it's a tip, not an issue.
3. Fix in the artifact with fallbacks, republish, and tell the user what changed and why.
