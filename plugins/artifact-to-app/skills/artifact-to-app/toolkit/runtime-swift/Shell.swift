// The window: a WKWebView serving app/ over the artifact:// scheme, window options from
// desktop.window.setOptions applied live with AppKit, and app-region drag areas.
import AppKit
import WebKit

final class ShellWindow: NSWindow {
    override var canBecomeKey: Bool { true }   // also when frame: false (borderless)
    override var canBecomeMain: Bool { true }
}

/// WebKit ignores CSS app-region, so bridge.js reports the drag areas and this view moves the window.
final class ShellWebView: WKWebView {
    var dragRects: [NSRect] = []
    var noDragRects: [NSRect] = []

    private func inDragRegion(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let pt = NSPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        return dragRects.contains { $0.contains(pt) } && !noDragRects.contains { $0.contains(pt) }
    }
    override func mouseDown(with event: NSEvent) {
        debugLog("mouseDown \(convert(event.locationInWindow, from: nil)) flipped=\(isFlipped) drag=\(dragRects.count) inDrag=\(inDragRegion(event))")
        guard inDragRegion(event) else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window?.miniaturize(nil)
            case "None": break
            default: window?.zoom(nil)
            }
            return
        }
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Serves the page's files from Resources/app as artifact://app/...
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let types = ["html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8",
                        "mjs": "text/javascript; charset=utf-8", "json": "application/json", "png": "image/png", "jpg": "image/jpeg",
                        "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp", "ico": "image/x-icon",
                        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf", "txt": "text/plain; charset=utf-8",
                        "wasm": "application/wasm", "mp3": "audio/mpeg", "mp4": "video/mp4"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let root = pageRoot.standardizedFileURL.path
        let file = pageRoot.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root + "/"), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish(); return
        }
        let type = SchemeHandler.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Shell: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let window: ShellWindow
    let webView: ShellWebView
    let root = NSView()
    let desktop = Desktop()
    var effectView: NSVisualEffectView?
    let optionsURL: URL
    var savedOptions: [String: Any]
    var appliedOptions: [String: Any] = [:]
    var titleBarStyle = "default"
    var dragHeight: CGFloat = 28
    var trafficLightPosition: NSPoint?
    /// Height of the page's top drag area, reported by bridge.js.
    var titleBandHeight: CGFloat? { didSet { if titleBandHeight != oldValue { layoutTrafficLights() } } }
    var hasAutosavedFrame = false
    var shownOnce = false
    static let pageURL = URL(string: "artifact://app/index.html")!

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(config.name, isDirectory: true)
        optionsURL = support.appendingPathComponent("window-options.json")
        savedOptions = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: optionsURL))) as? [String: Any]) ?? [:]

        window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)

        let wc = WKWebViewConfiguration()
        wc.setURLSchemeHandler(SchemeHandler(), forURLScheme: "artifact")
        wc.userContentController.addScriptMessageHandler(desktop, contentWorld: .page, name: "desktop")
        let cfg: [String: Any] = ["declared": config.declared, "captureIcon": captureIconPath != nil]
        let cfgJSON = String(data: try! JSONSerialization.data(withJSONObject: cfg), encoding: .utf8)!
        let bridge = (try? String(contentsOf: resources.appendingPathComponent("bridge.js"), encoding: .utf8)) ?? ""
        wc.userContentController.addUserScript(WKUserScript(source: "window.__ARTIFACT_CONFIG__ = \(cfgJSON);\n\(bridge)",
                                                            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        wc.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = ShellWebView(frame: .zero, configuration: wc)
        super.init()

        desktop.shell = self
        window.title = config.name
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        root.frame = window.contentLayoutRect
        webView.frame = root.bounds
        webView.autoresizingMask = [.width, .height]
        root.addSubview(webView)
        window.contentView = root
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        // Style first, then the frame the person left: changing the title-bar style resizes the window.
        hasAutosavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(config.name)") != nil
        applyOptions(savedOptions, initial: true)
        if hasAutosavedFrame { window.setFrameUsingName(config.name) } else { window.center() }
        window.setFrameAutosaveName(config.name)
        webView.load(URLRequest(url: Shell.pageURL))
    }

    func showWindow() {
        guard captureIconPath == nil else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        layoutTrafficLights()
    }
    func reload() { webView.load(URLRequest(url: Shell.pageURL)) }

    // MARK: window options (Electron BrowserWindow names, as desktop.d.ts lists them)
    static let optionKeys: Set<String> = ["titleBarStyle", "trafficLightPosition", "dragHeight", "frame", "transparent", "alwaysOnTop",
        "vibrancy", "visualEffectState", "movable", "resizable", "minimizable", "maximizable", "fullscreenable", "hasShadow",
        "roundedCorners", "backgroundColor", "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight"]

    func setOptions(_ raw: [String: Any]) throws -> [String: Any] {
        if let bad = raw.keys.first(where: { !Shell.optionKeys.contains($0) }) { throw ShellError("EINVAL", "unknown window option \(bad)") }
        let o = raw
        let overlay = (o["frame"] as? Bool) == false || (o["transparent"] as? Bool) == true || (o["alwaysOnTop"] as? Bool) == true
        if overlay && !(config.declared.contains("overlay") && captureIconPath == nil) {
            throw ShellError("EPERM", "frame: false, transparent and alwaysOnTop need the overlay permission")
        }
        if !NSDictionary(dictionary: o).isEqual(to: savedOptions) {
            savedOptions = o
            try? FileManager.default.createDirectory(at: optionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: optionsURL)
        }
        if !NSDictionary(dictionary: o).isEqual(to: appliedOptions) { applyOptions(o, initial: false) }
        return ["applied": "now", "reloading": false, "options": o]
    }
    func getOptions() -> [String: Any] { ["options": savedOptions, "applied": appliedOptions] }

    private func applyOptions(_ o: [String: Any], initial: Bool) {
        let prev = appliedOptions
        appliedOptions = o
        func num(_ k: String, _ d: [String: Any] = o) -> CGFloat? { (d[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        func flag(_ k: String, _ def: Bool) -> Bool { (o[k] as? Bool) ?? def }

        titleBarStyle = o["titleBarStyle"] as? String ?? "default"
        let framed = flag("frame", true)
        let customTitleBar = framed && titleBarStyle != "default"
        dragHeight = num("dragHeight") ?? 28
        if let t = o["trafficLightPosition"] as? [String: Any], let x = num("x", t), let y = num("y", t) { trafficLightPosition = NSPoint(x: x, y: y) }
        else { trafficLightPosition = nil }

        var mask: NSWindow.StyleMask = framed ? [.titled, .closable] : [.borderless]
        if flag("resizable", true) { mask.insert(.resizable) }
        if framed && flag("minimizable", true) { mask.insert(.miniaturizable) }
        if customTitleBar { mask.insert(.fullSizeContentView) }
        window.styleMask = mask
        window.titlebarAppearsTransparent = customTitleBar
        window.titleVisibility = customTitleBar ? .hidden : .visible
        window.isMovable = flag("movable", true)
        window.standardWindowButton(.zoomButton)?.isEnabled = flag("maximizable", true)
        if flag("fullscreenable", true) { window.collectionBehavior.remove(.fullScreenNone); window.collectionBehavior.insert(.fullScreenPrimary) }
        else { window.collectionBehavior.remove(.fullScreenPrimary); window.collectionBehavior.insert(.fullScreenNone) }
        window.hasShadow = flag("hasShadow", true)
        window.level = flag("alwaysOnTop", false) ? .floating : .normal

        let transparent = flag("transparent", false)
        let vibrancy = o["vibrancy"] as? String
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : (color(o["backgroundColor"]) ?? .windowBackgroundColor)
        webView.setValue(!(transparent || vibrancy != nil), forKey: "drawsBackground")
        effectView?.removeFromSuperview(); effectView = nil
        if let v = vibrancy, let m = Shell.materials[v] {
            let e = NSVisualEffectView(frame: root.bounds)
            e.autoresizingMask = [.width, .height]
            e.material = m
            e.blendingMode = .behindWindow
            e.state = ["active": .active, "inactive": .inactive][o["visualEffectState"] as? String ?? ""] ?? .followsWindowActiveState
            root.addSubview(e, positioned: .below, relativeTo: webView)
            effectView = e
        }

        window.contentMinSize = NSSize(width: num("minWidth") ?? 0, height: num("minHeight") ?? 0)
        window.contentMaxSize = NSSize(width: num("maxWidth") ?? .greatestFiniteMagnitude, height: num("maxHeight") ?? .greatestFiniteMagnitude)
        // The page's size applies on first launch and when the page asks for a new one; otherwise the size the person left is kept.
        let sizeAsked = num("width") != nil || num("height") != nil
        let sizeChanged = num("width") != num("width", prev) || num("height") != num("height", prev)
        if sizeAsked && (initial ? !hasAutosavedFrame : sizeChanged) {
            var size = window.contentRect(forFrameRect: window.frame).size
            size.width = num("width") ?? size.width
            size.height = num("height") ?? size.height
            // With a hidden title bar the page fills the whole window, so its size is the frame size.
            var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            if window.styleMask.contains(.fullSizeContentView) { f.size = size }
            f.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - f.height)
            window.setFrame(f, display: true)
            debugLog("size \(size) → frame \(window.frame) content \(window.contentLayoutRect)")
        }
        layoutTrafficLights()
    }

    static let materials: [String: NSVisualEffectView.Material] = [
        "under-window": .underWindowBackground, "under-page": .underPageBackground, "sidebar": .sidebar, "content": .contentBackground,
        "hud": .hudWindow, "popover": .popover, "window": .windowBackground, "titlebar": .titlebar, "header": .headerView,
        "menu": .menu, "sheet": .sheet, "selection": .selection, "tooltip": .toolTip, "fullscreen-ui": .fullScreenUI]

    private func color(_ v: Any?) -> NSColor? {
        guard let s = v as? String, s.count == 7, s.hasPrefix("#"), let n = UInt32(s.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((n >> 16) & 0xff) / 255, green: CGFloat((n >> 8) & 0xff) / 255, blue: CGFloat(n & 0xff) / 255, alpha: 1)
    }

    /// hiddenInset (or a trafficLightPosition) moves the window buttons into the page's own title bar,
    /// centered in its drag strip, as Electron does.
    func layoutTrafficLights() {
        guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
              titleBarStyle == "hiddenInset" || trafficLightPosition != nil,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }
        // Center on the page's real title bar (its top drag area) when it reports one; it can be taller than dragHeight.
        let h = max(titleBandHeight ?? dragHeight, close.frame.height + 8)
        var cf = container.frame
        cf.size.height = h
        cf.origin.y = window.frame.height - h
        container.frame = cf
        let spacing = mini.frame.minX - close.frame.minX > 0 ? mini.frame.minX - close.frame.minX : 20
        // Pages written for Claude's app leave about 70–84 pt for the buttons; start them near the edge.
        let x0 = trafficLightPosition?.x ?? 10
        let fromTop = trafficLightPosition?.y ?? (h - close.frame.height) / 2
        for (i, b) in [close, mini, zoom].enumerated() {
            b.setFrameOrigin(NSPoint(x: x0 + CGFloat(i) * spacing, y: h - fromTop - b.frame.height))
        }
        debugLog("traffic lights h=\(h) container=\(container.frame) close=\(close.frame) window=\(window.frame) webView=\(webView.frame)")
    }
    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutTrafficLights() }

    /// With a menu bar item, closing only hides the window (as the installed artifact does on macOS).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if desktop.tray != nil { window.orderOut(nil); return false }
        return true
    }

    // MARK: navigation: the page stays on artifact://; links open in the browser
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "artifact" || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return decisionHandler(.allow) }
        if ["http", "https", "mailto"].contains(url.scheme ?? "") && action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return nil
    }
    // Like the Claude app: processes, shortcuts and the menu bar item end when the page reloads.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { desktop.resetPageState() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("didFinish frame=\(webView.frame) root=\(root.frame)")
        if !shownOnce { shownOnce = true; showWindow() }
        if debugEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                webView.evaluateJavaScript("""
                    (() => { const d = document.documentElement, b = document.body;
                      const tall = [...document.querySelectorAll('body *')].filter(e => e.getBoundingClientRect().bottom > innerHeight + 0.5)
                        .slice(0, 5).map(e => e.tagName + '.' + e.className + ' bottom=' + e.getBoundingClientRect().bottom + ' pos=' + getComputedStyle(e).position);
                      return document.readyState + ' text=' + b.innerText.length + ' viewport=' + innerWidth + 'x' + innerHeight +
                        ' html.scrollHeight=' + d.scrollHeight + ' body.scrollHeight=' + b.scrollHeight + ' html.pad=' + getComputedStyle(d).paddingTop + '/' + getComputedStyle(d).paddingBottom +
                        ' overflowing=' + JSON.stringify(tall); })()
                    """) { r, e in
                    debugLog("page: \(String(describing: r)) \(String(describing: e)) frame=\(webView.frame)")
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { debugLog("didFail \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { debugLog("didFailProvisional \(error)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { debugLog("web content process ended"); reload() }

    // MARK: window calls (coordinates are top-left based, like Electron's)
    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    func bounds() -> [String: Any] {
        let f = window.frame
        return ["x": f.minX, "y": primaryHeight - f.maxY, "width": f.width, "height": f.height]
    }
    func setBounds(_ b: [String: Any]) {
        var f = window.frame
        let top = primaryHeight - f.maxY
        if let w = b["width"] as? NSNumber { f.size.width = CGFloat(w.doubleValue) }
        if let h = b["height"] as? NSNumber { f.size.height = CGFloat(h.doubleValue) }
        let x = (b["x"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? f.minX
        let y = (b["y"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? top
        f.origin = NSPoint(x: x, y: primaryHeight - y - f.height)
        window.setFrame(f, display: true)
    }
    func place(_ p: [String: Any]) throws -> [String: Any] {
        guard window.isVisible, !window.isMiniaturized else { throw ShellError("ECANCELED", "the window is hidden or minimized") }
        var size = window.contentRect(forFrameRect: window.frame).size
        if let w = p["width"] as? NSNumber { size.width = CGFloat(w.doubleValue) }
        if let h = p["height"] as? NSNumber { size.height = CGFloat(h.doubleValue) }
        var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let area = (window.screen ?? NSScreen.main!).visibleFrame
        f.size.width = min(f.width, area.width); f.size.height = min(f.height, area.height)
        let margin = CGFloat((p["margin"] as? NSNumber)?.doubleValue ?? 0)
        if let anchor = p["anchor"] as? String {
            let x = anchor == "center" ? area.midX - f.width / 2 : anchor.hasSuffix("left") ? area.minX + margin : area.maxX - f.width - margin
            let y = anchor == "center" ? area.midY - f.height / 2 : anchor.hasPrefix("top") ? area.maxY - f.height - margin : area.minY + margin
            f.origin = NSPoint(x: x, y: y)
        } else {
            let pin = p["pin"] as? String ?? "top_left"
            let old = window.frame
            f.origin.x = pin.hasSuffix("left") ? old.minX : old.maxX - f.width
            f.origin.y = pin.hasPrefix("top") ? old.maxY - f.height : old.minY
        }
        window.setFrame(f, display: true, animate: false)
        let c = window.contentRect(forFrameRect: window.frame).size
        return ["width": c.width, "height": c.height]
    }
    func print(_ done: @escaping (Bool) -> Void) {
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = webView.bounds
        done(op.run())
    }
}
