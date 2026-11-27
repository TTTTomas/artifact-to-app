// Menus from Electron-style templates (label, submenu, role, type, accelerator, checked, enabled,
// visible, click → clickId, href), plus the default application menu.
import AppKit

final class MenuAction: NSObject {
    let fn: (NSMenuItem?) -> Void
    init(_ fn: @escaping (NSMenuItem?) -> Void) { self.fn = fn }
    @objc func fire(_ sender: Any?) { fn(sender as? NSMenuItem) }
}

enum Menus {
    static var name: String { config.name }

    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }
    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    static func appMenu() -> NSMenuItem {
        submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
    }
    static func editMenu() -> NSMenuItem {
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
    }
    static func viewMenu(_ shell: Shell?) -> NSMenuItem {
        let reload = MenuAction { _ in shell?.reload() }
        let r = item("Reload", #selector(MenuAction.fire(_:)), "r")
        r.target = reload; r.representedObject = reload
        return submenu("View", [r, .separator(), item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
    }
    static func windowMenu() -> NSMenuItem {
        let w = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = w.submenu
        return w
    }
    static func defaultMenu() -> NSMenu {
        let m = NSMenu()
        [appMenu(), editMenu(), viewMenu(nil), windowMenu()].forEach(m.addItem)
        // The reload item needs the shell, which exists after launch.
        DispatchQueue.main.async {
            if let shell = (NSApp.delegate as? AppDelegate)?.shell, let i = m.items.firstIndex(where: { $0.title == "View" }) {
                m.removeItem(at: i); m.insertItem(viewMenu(shell), at: i)
            }
        }
        return m
    }
    /// The page's menu bar, after the app menu Claude's app builds itself (appMenu and quit roles are dropped).
    static func applicationMenu(_ template: [[String: Any]], shell: Shell, click: @escaping (Int, [String: Any]) -> Void) -> NSMenu {
        let m = NSMenu()
        m.addItem(appMenu())
        for i in build(template, shell: shell, click: click).items { i.menu?.removeItem(i); m.addItem(i) }
        return m
    }

    static func build(_ template: [[String: Any]], shell: Shell?, click: @escaping (Int, [String: Any]) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for t in template {
            if let role = t["role"] as? String, let r = roleItem(role, t, shell) { menu.addItem(r); continue }
            if t["role"] != nil { continue }   // dropped roles (appMenu, quit)
            let type = t["type"] as? String ?? (t["submenu"] != nil ? "submenu" : "normal")
            if type == "separator" { menu.addItem(.separator()); continue }
            let i = NSMenuItem(title: t["label"] as? String ?? "", action: nil, keyEquivalent: "")
            if let acc = t["accelerator"] as? String { setAccelerator(i, acc) }
            i.isEnabled = (t["enabled"] as? Bool) ?? true
            i.isHidden = (t["visible"] as? Bool) == false
            if type == "checkbox" || type == "radio" { i.state = (t["checked"] as? Bool) == true ? .on : .off }
            if let sub = t["submenu"] as? [[String: Any]] { i.submenu = build(sub, shell: shell, click: click); i.submenu?.title = i.title }
            let clickId = (t["clickId"] as? NSNumber)?.intValue
            let href = (t["href"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
            if clickId != nil || href != nil || type == "checkbox" || type == "radio" {
                let action = MenuAction { item in
                    guard let item = item else { return }
                    if type == "checkbox" { item.state = item.state == .on ? .off : .on }
                    if type == "radio" { item.menu?.items.filter { $0.representedObject is MenuAction && $0 !== item }.forEach { $0.state = .off }; item.state = .on }
                    var opened = false
                    if let url = href { NSWorkspace.shared.open(url); opened = true }
                    if let id = clickId { click(id, ["label": item.title, "checked": item.state == .on, "opened": opened]) }
                }
                i.target = action; i.action = #selector(MenuAction.fire(_:)); i.representedObject = action
            }
            menu.addItem(i)
        }
        return menu
    }

    static func roleItem(_ role: String, _ t: [String: Any], _ shell: Shell?) -> NSMenuItem? {
        let label = t["label"] as? String
        func named(_ def: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            item(label ?? def, sel, key, mods)
        }
        switch role.lowercased() {
        case "editmenu": return editMenu()
        case "windowmenu": return windowMenu()
        case "viewmenu": return viewMenu(shell)
        case "filemenu": return submenu(label ?? "File", [item("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        case "undo": return item("Undo", Selector(("undo:")), "z")
        case "redo": return item("Redo", Selector(("redo:")), "z", [.command, .shift])
        case "cut": return item("Cut", #selector(NSText.cut(_:)), "x")
        case "copy": return item("Copy", #selector(NSText.copy(_:)), "c")
        case "paste": return item("Paste", #selector(NSText.paste(_:)), "v")
        case "pasteandmatchstyle": return item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        case "delete": return item("Delete", #selector(NSText.delete(_:)))
        case "selectall": return item("Select All", #selector(NSText.selectAll(_:)), "a")
        case "about": return item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        case "hide": return item("Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        case "hideothers": return item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        case "unhide": return item("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        case "front": return item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        case "close": return named("Close", #selector(NSWindow.performClose(_:)), "w")
        case "minimize": return named("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        case "zoom": return named("Zoom", #selector(NSWindow.performZoom(_:)))
        case "togglefullscreen": return named("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        case "reload", "forcereload":
            let a = MenuAction { _ in shell?.reload() }
            let i = named("Reload", #selector(MenuAction.fire(_:)), "r"); i.target = a; i.representedObject = a
            return i
        default: return nil   // appMenu, quit, services, devtools: dropped
        }
    }

    static func setAccelerator(_ i: NSMenuItem, _ acc: String) {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for t in acc.split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            switch t.lowercased() {
            case "cmdorctrl", "commandorcontrol", "cmd", "command", "super", "meta": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "": key = "+"
            default: key = keyEquivalent(t)
            }
        }
        // desktop.d.ts: an accelerator needs Command or Control.
        guard mods.contains(.command) || mods.contains(.control) else { return }
        i.keyEquivalent = key
        i.keyEquivalentModifierMask = mods
    }
    static func keyEquivalent(_ t: String) -> String {
        func fn(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }
        switch t.lowercased() {
        case "plus": return "+"
        case "space": return " "
        case "enter", "return": return "\r"
        case "tab": return "\t"
        case "backspace": return fn(NSBackspaceCharacter)
        case "delete": return fn(NSDeleteFunctionKey)
        case "escape", "esc": return "\u{1b}"
        case "up": return fn(NSUpArrowFunctionKey)
        case "down": return fn(NSDownArrowFunctionKey)
        case "left": return fn(NSLeftArrowFunctionKey)
        case "right": return fn(NSRightArrowFunctionKey)
        default:
            if t.count > 1, t.lowercased().hasPrefix("f"), let n = Int(t.dropFirst()), (1...20).contains(n) { return fn(NSF1FunctionKey + n - 1) }
            return t.lowercased()
        }
    }
}
