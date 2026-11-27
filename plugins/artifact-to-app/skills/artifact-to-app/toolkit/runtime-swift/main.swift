// Artifact App Swift shell: runs a Claude desktop-app artifact (one that declares the `desktop`
// capability) as a native macOS app. The page runs in WKWebView; bridge.js gives it
// claude.use("desktop") and Desktop.swift carries the calls out with AppKit.
// Shared by every exported app: change it here, in the plugin's toolkit/runtime-swift.
import AppKit

struct ShellConfig: Codable {
    var name: String
    var bundleId: String
    var declared: [String]
}

let resources = Bundle.main.resourceURL!
let pageRoot = resources.appendingPathComponent("app", isDirectory: true)
let config: ShellConfig = {
    if let d = try? Data(contentsOf: resources.appendingPathComponent("app-config.json")),
       let c = try? JSONDecoder().decode(ShellConfig.self, from: d) { return c }
    return ShellConfig(name: ProcessInfo.processInfo.processName, bundleId: Bundle.main.bundleIdentifier ?? "local.artifact", declared: [])
}()
/// Set by the exporter: run the page with nothing granted, save the icon it draws, quit.
let captureIconPath = ProcessInfo.processInfo.environment["ARTIFACT_APP_CAPTURE_ICON"]

func stderrLine(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
/// ARTIFACT_APP_DEBUG=1 logs navigation and page state to stderr.
let debugEnabled = ProcessInfo.processInfo.environment["ARTIFACT_APP_DEBUG"] != nil
func debugLog(_ s: @autoclosure () -> String) { if debugEnabled { stderrLine("[shell] " + s()) } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var shell: Shell!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Menus.defaultMenu()
        shell = Shell()
        if captureIconPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { stderrLine("The page never set an icon."); exit(2) }
        }
    }
    /// A menu bar app keeps running with its window hidden (closed, or hidden by the page); others quit with their window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { shell?.desktop.tray == nil }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shell.showWindow(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { shell?.desktop.resetPageState() }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(captureIconPath == nil ? .regular : .accessory)
app.run()
