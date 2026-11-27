// Native title-bar metrics, read from AppKit on the running macOS version instead of hard-coded:
// where a unified-toolbar window (Notes, Photos, …) puts its window buttons, and the title font and colors.
// The shell places its buttons with these and hands them to the page as CSS variables:
//   --titlebar-inset-left   where page content may start, right of the buttons (px)
//   --titlebar-height       the title bar's height (px)
//   --titlebar-font         the native title font, as a CSS font shorthand
//   --titlebar-color        the native title color for the window's current state (active/inactive, light/dark)
// and classes on <html>: artifact-app always, artifact-native-title while the shell draws the window title.
import AppKit

enum NativeTitlebar {
    struct Buttons { let x: CGFloat, spacing: CGFloat, size: CGFloat }

    /// Measured from an off-screen window styled like a native app with a unified toolbar.
    static let buttons: Buttons = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.toolbar = NSToolbar()
        w.toolbarStyle = .unified
        func frame(_ t: NSWindow.ButtonType) -> NSRect? { w.standardWindowButton(t).map { $0.convert($0.bounds, to: nil) } }
        guard let c = frame(.closeButton), let m = frame(.miniaturizeButton), m.minX > c.minX else { return Buttons(x: 19, spacing: 23, size: 14) }
        debugLog("native buttons x=\(c.minX) spacing=\(m.minX - c.minX) size=\(c.width)")
        return Buttons(x: c.minX, spacing: m.minX - c.minX, size: c.width)
    }()

    /// Space between the last window button and the page's title-bar content.
    static let gap: CGFloat = 12

    /// NSFont.titleBarFont as CSS: the system font at its size and weight.
    static let font: String = {
        let f = NSFont.titleBarFont(ofSize: 0)
        let traits = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let w = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0.4
        let css = w >= 0.56 ? 800 : w >= 0.35 ? 700 : w >= 0.23 ? 600 : w >= 0.1 ? 500 : 400
        return "\(css) \(Int(f.pointSize.rounded()))px -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    }()

    /// The title color as native windows show it. AppKit's windowFrameTextColor is 85% black (or white), but a
    /// native title is drawn over the title bar's material and appears at about 57%: measured on Photos' active
    /// title on macOS 26. So the active color is windowFrameTextColor at that strength; inactive is
    /// tertiaryLabelColor (26%, measured about 22%).
    static let activeAlpha: CGFloat = 0.57
    static func nsColor(active: Bool) -> NSColor {
        active ? NSColor.windowFrameTextColor.withAlphaComponent(activeAlpha) : .tertiaryLabelColor
    }
    static func color(active: Bool, appearance: NSAppearance) -> String {
        var css = "inherit"
        appearance.performAsCurrentDrawingAppearance {
            guard let c = nsColor(active: active).usingColorSpace(.sRGB) else { return }
            css = String(format: "rgba(%d, %d, %d, %.2f)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                         Int((c.blueComponent * 255).rounded()), c.alphaComponent)
        }
        return css
    }
}
