// The desktop API (desktop.d.ts) carried out with Foundation and AppKit. bridge.js posts
// {op, args}; every op replies with a value or rejects with "CODE: detail" (errno-style codes).
import AppKit
import WebKit
import UserNotifications
import Carbon.HIToolbox

struct ShellError: Error {
    let code: String, message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

let errnoNames: [Int32: String] = [EPERM: "EPERM", ENOENT: "ENOENT", ESRCH: "ESRCH", EINTR: "EINTR", EIO: "EIO", EBADF: "EBADF",
    EACCES: "EACCES", EBUSY: "EBUSY", EEXIST: "EEXIST", EXDEV: "EXDEV", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR", EINVAL: "EINVAL",
    EFBIG: "EFBIG", ENOSPC: "ENOSPC", EROFS: "EROFS", EMLINK: "EMLINK", ENAMETOOLONG: "ENAMETOOLONG", ENOTEMPTY: "ENOTEMPTY",
    ELOOP: "ELOOP", EAGAIN: "EAGAIN", ENOTSUP: "ENOTSUP", ECANCELED: "ECANCELED", ENOSYS: "ENOSYS", EMFILE: "EMFILE"]

func posixError(_ path: String, _ e: Int32 = errno) -> ShellError {
    ShellError(errnoNames[e] ?? "EIO", "\(String(cString: strerror(e))), '\(path)'")
}
/// Any error as "CODE: message", digging out the POSIX code Foundation wraps.
func describe(_ error: Error) -> String {
    if let s = error as? ShellError { return "\(s.code): \(s.message)" }
    var ns = error as NSError
    while true {
        if ns.domain == NSPOSIXErrorDomain { return "\(errnoNames[Int32(ns.code)] ?? "EIO"): \((error as NSError).localizedDescription)" }
        guard let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
        ns = u
    }
    let e = error as NSError
    var code = "EIO"
    if e.domain == NSCocoaErrorDomain {
        switch e.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: code = "ENOENT"
        case NSFileWriteFileExistsError: code = "EEXIST"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: code = "EACCES"
        case NSFileReadTooLargeError: code = "EFBIG"
        case NSFileWriteOutOfSpaceError: code = "ENOSPC"
        default: break
        }
    }
    return "\(code): \(e.localizedDescription)"
}

/// `~/x` and relative paths start at the home folder.
func expand(_ p: String?) -> String {
    let home = NSHomeDirectory()
    guard let p = p, !p.isEmpty else { return home }
    if p == "~" { return home }
    if p.hasPrefix("~/") { return home + "/" + p.dropFirst(2) }
    return p.hasPrefix("/") ? p : home + "/" + p
}

/// Splits off a trailing incomplete UTF-8 sequence so streamed output never breaks a character.
func splitUTF8(_ d: Data) -> (String, Data) {
    let bytes = [UInt8](d)
    var cut = bytes.count, i = bytes.count - 1, back = 0
    while i >= 0 && back < 4 {
        let b = bytes[i]
        if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }
        let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
        if bytes.count - i < need { cut = i }
        break
    }
    return (String(decoding: bytes[..<cut], as: UTF8.self), Data(bytes[cut...]))
}

let signalNames: [Int32: String] = [SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGKILL: "SIGKILL", SIGTERM: "SIGTERM",
                                    SIGABRT: "SIGABRT", SIGSEGV: "SIGSEGV", SIGPIPE: "SIGPIPE", SIGBUS: "SIGBUS"]

final class Proc {
    let process = Process()
    let stdin = Pipe()
    var code: Any = NSNull(), signal: Any = NSNull()
}

final class Desktop: NSObject, WKScriptMessageHandlerWithReply, UNUserNotificationCenterDelegate {
    weak var shell: Shell!
    var procs: [Int: Proc] = [:]
    var tray: NSStatusItem?
    var trayAction: MenuAction?
    let hotkeys = HotKeys()
    var notificationsReady = false

    // MARK: dispatch
    static func permission(for op: String) -> String? {
        if op.hasPrefix("fs.") || op.hasPrefix("shell.") || ["exec", "spawn", "kill", "stdin"].contains(op) { return "full-access" }
        if op.hasPrefix("screen.") || op == "window.setIgnoreMouseEvents" || op == "window.setVisibleOnAllWorkspaces" { return "overlay" }
        return ["shortcut.register": "shortcuts", "notification.show": "notifications", "tray.set": "menu-bar"][op]
    }
    static func granted(_ permission: String) -> Bool { config.declared.contains(permission) && captureIconPath == nil }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return replyHandler(nil, "EINVAL: bad call") }
        let args = (body["args"] as? [Any] ?? []).map { $0 is NSNull ? nil : $0 } as [Any?]
        if let need = Desktop.permission(for: op), !Desktop.granted(need) {
            return replyHandler(nil, "EPERM: the page does not declare the \(need) permission")
        }
        let ok: (Any?) -> Void = { replyHandler($0 ?? NSNull(), nil) }
        let fail: (Error) -> Void = { replyHandler(nil, describe($0)) }
        do { try handle(op, args, ok, fail) } catch { fail(error) }
    }

    /// Runs file and process work off the main thread and replies on it.
    private func background(_ ok: @escaping (Any?) -> Void, _ fail: @escaping (Error) -> Void, _ work: @escaping () throws -> Any?) {
        DispatchQueue.global(qos: .userInitiated).async {
            do { let v = try work(); DispatchQueue.main.async { ok(v) } } catch { DispatchQueue.main.async { fail(error) } }
        }
    }

    private func handle(_ op: String, _ a: [Any?], _ ok: @escaping (Any?) -> Void, _ fail: @escaping (Error) -> Void) throws {
        func s(_ i: Int) -> String? { i < a.count ? a[i] as? String : nil }
        func d(_ i: Int) -> [String: Any] { (i < a.count ? a[i] as? [String: Any] : nil) ?? [:] }
        func n(_ i: Int) -> Int? { i < a.count ? (a[i] as? NSNumber)?.intValue : nil }
        func path(_ i: Int) throws -> String { guard let p = s(i) else { throw ShellError("EINVAL", "a path is required") }; return expand(p) }

        switch op {
        // ---- files ----
        case "fs.readFile":
            let p = try path(0), enc = s(1)
            background(ok, fail) {
                let data = try Data(contentsOf: URL(fileURLWithPath: p))
                if enc == "utf8" { return String(decoding: data, as: UTF8.self) }
                if enc == "base64" { return data.base64EncodedString() }
                return ["__b64": data.base64EncodedString()]
            }
        case "fs.writeFile", "fs.appendFile":
            let p = try path(0), data = try bytes(a.count > 1 ? a[1] : nil, s(2)), append = op == "fs.appendFile"
            background(ok, fail) {
                if append, let h = FileHandle(forWritingAtPath: p) { defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: data); return nil }
                guard FileManager.default.createFile(atPath: p, contents: data) else {
                    var isDir: ObjCBool = false
                    let parent = (p as NSString).deletingLastPathComponent
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { throw posixError(p, EISDIR) }
                    if !FileManager.default.fileExists(atPath: parent) { throw posixError(p, ENOENT) }
                    throw posixError(p, EACCES)
                }
                return nil
            }
        case "fs.readdir":
            let p = try path(0)
            background(ok, fail) {
                try FileManager.default.contentsOfDirectory(atPath: p).sorted().map { name -> [String: Any] in
                    let st = try? Desktop.statInfo(p + "/" + name, link: true)
                    return ["name": name, "isFile": st?["isFile"] ?? false, "isDirectory": st?["isDirectory"] ?? false,
                            "isSymbolicLink": st?["isSymbolicLink"] ?? false]
                }
            }
        case "fs.stat", "fs.lstat":
            let p = try path(0), link = op == "fs.lstat"
            background(ok, fail) { try Desktop.statInfo(p, link: link) }
        case "fs.exists":
            ok(access(try path(0), F_OK) == 0)
        case "fs.mkdir":
            let p = try path(0), recursive = (d(1)["recursive"] as? Bool) ?? false
            background(ok, fail) {
                if recursive { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
                else if mkdir(p, 0o777) != 0 { throw posixError(p) }
                return nil
            }
        case "fs.rm":
            let p = try path(0), o = d(1), recursive = (o["recursive"] as? Bool) ?? false, force = (o["force"] as? Bool) ?? false
            background(ok, fail) {
                var st = Darwin.stat()
                if lstat(p, &st) != 0 { if errno == ENOENT && force { return nil }; throw posixError(p) }
                if st.st_mode & S_IFMT == S_IFDIR {
                    guard recursive else { throw posixError(p, EISDIR) }
                    try FileManager.default.removeItem(atPath: p)
                } else if unlink(p) != 0 { throw posixError(p) }
                return nil
            }
        case "fs.rmdir":
            let p = try path(0)
            background(ok, fail) { if rmdir(p) != 0 { throw posixError(p) }; return nil }
        case "fs.rename":
            let from = try path(0), to = try path(1)
            background(ok, fail) { if rename(from, to) != 0 { throw posixError(from) }; return nil }
        case "fs.copyFile":
            let from = try path(0), to = try path(1)
            background(ok, fail) { if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 { throw posixError(from) }; return nil }
        case "fs.realpath":
            let p = try path(0)
            background(ok, fail) {
                guard let r = realpath(p, nil) else { throw posixError(p) }
                defer { free(r) }
                return String(cString: r)
            }

        // ---- processes ----
        case "spawn":
            guard let id = n(0), let cmd = s(1) else { throw ShellError("EINVAL", "spawn needs a command") }
            ok(Int(try spawn(id: id, command: cmd, args: (a.count > 2 ? a[2] as? [Any] : nil)?.map { "\($0)" } ?? [], options: d(3))))
        case "kill":
            guard let id = n(0), let p = procs[id], p.process.isRunning else { throw ShellError("ESRCH", "the process has exited") }
            let sig = ["SIGTERM": SIGTERM, "SIGKILL": SIGKILL, "SIGINT": SIGINT, "SIGHUP": SIGHUP][s(1) ?? "SIGTERM"]
            guard let sg = sig else { throw ShellError("EINVAL", "unsupported signal \(s(1) ?? "")") }
            ok(Darwin.kill(p.process.processIdentifier, sg) == 0)
        case "stdin":
            guard let id = n(0), let p = procs[id] else { throw ShellError("ESRCH", "the process has exited") }
            if s(1) == "write" { try p.stdin.fileHandleForWriting.write(contentsOf: try bytes(a.count > 2 ? a[2] : nil, nil)) }
            else { try p.stdin.fileHandleForWriting.close() }
            ok(true)
        case "exec":
            guard let cmd = s(0) else { throw ShellError("EINVAL", "exec needs a command") }
            exec(cmd, d(1), ok, fail)

        // ---- os, shell, screen ----
        case "os":
            let key = s(0) ?? "info"
            if key != "platform" && key != "arch" && !Desktop.granted("full-access") { throw ShellError("EPERM", "os.\(key) needs full-access") }
            let info = Desktop.osInfo()
            ok(key == "info" ? info : info[key])
        case "shell.openPath":
            let url = URL(fileURLWithPath: try path(0))
            if url.pathExtension == "app" || FileManager.default.isExecutableFile(atPath: url.path) && !url.hasDirectoryPath && url.pathExtension.isEmpty {
                throw ShellError("EPERM", "openPath opens documents; run programs with childProcess")
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw posixError(url.path, ENOENT) }
            NSWorkspace.shared.open(url); ok(nil)
        case "shell.showItemInFolder":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: try path(0))]); ok(nil)
        case "shell.trashItem":
            let p = try path(0)
            background(ok, fail) { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); return nil }
        case "screen.getCursorScreenPoint":
            let m = NSEvent.mouseLocation
            ok(["x": m.x, "y": shell.primaryHeight - m.y])
        case "screen.getAllDisplays":
            ok(NSScreen.screens.map(displayInfo))

        // ---- window ----
        case "window.setOptions": ok(try shell.setOptions(d(0)))
        case "window.getOptions": ok(shell.getOptions())
        case "window.place": ok(try shell.place(d(0)))
        case "window.show": shell.showWindow(); ok(nil)
        case "window.hide": shell.window.orderOut(nil); ok(nil)
        case "window.getBounds": ok(shell.bounds())
        case "window.setBounds": shell.setBounds(d(0)); ok(nil)
        case "window.print": shell.print { ok($0) }
        case "window.setIgnoreMouseEvents": shell.window.ignoresMouseEvents = (a.first as? Bool) ?? false; ok(nil)
        case "window.setVisibleOnAllWorkspaces":
            if (a.first as? Bool) ?? false {
                shell.window.collectionBehavior.insert(.canJoinAllSpaces)
                if (d(1)["visibleOnFullScreen"] as? Bool) ?? false { shell.window.collectionBehavior.insert(.fullScreenAuxiliary) }
            } else { shell.window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary]) }
            ok(nil)
        case "drag.regions":
            let r = d(0)
            func rects(_ k: String) -> [NSRect] {
                (r[k] as? [[NSNumber]] ?? []).compactMap { $0.count == 4 ? NSRect(x: $0[0].doubleValue, y: $0[1].doubleValue, width: $0[2].doubleValue, height: $0[3].doubleValue) : nil }
            }
            shell.webView.dragRects = rects("drag"); shell.webView.noDragRects = rects("noDrag")
            shell.titleBandHeight = rects("drag").filter { $0.minY <= 1 && $0.height >= 20 && $0.height <= 120 }.map(\.height).max()
            debugLog("drag regions \(rects("drag")) no-drag \(rects("noDrag").count)")
            ok(nil)

        // ---- menus, dock, notifications, shortcuts, tray ----
        case "menu.setApplicationMenu":
            if let t = a.first as? [[String: Any]] { NSApp.mainMenu = Menus.applicationMenu(t, shell: shell, click: clickHandler) }
            else { NSApp.mainMenu = Menus.defaultMenu() }
            ok(nil)
        case "menu.popup":
            guard shell.window.isKeyWindow else { throw ShellError("ENOTSUP", "the window is not focused") }
            let menu = Menus.build(a.first as? [[String: Any]] ?? [], shell: shell, click: clickHandler)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            ok(nil)
        case "dock.setIcon":
            guard let url = s(0), let img = Desktop.image(dataURL: url) else { throw ShellError("EINVAL", "setIcon needs a PNG data: URL") }
            if let out = captureIconPath {   // the exporter wants the page's icon for the app bundle
                try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Desktop.png(img, side: 1024).write(to: URL(fileURLWithPath: out))
                ok(["written": true])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
                return
            }
            NSApp.applicationIconImage = img
            ok(["written": true])
        case "dock.setBadge":
            let t = String((s(0) ?? "").prefix(24))
            NSApp.dockTile.badgeLabel = t.isEmpty ? nil : t
            ok(true)
        case "notification.show":
            notify(String(((d(0)["body"] as? String) ?? "").prefix(300)), ok, fail)
        case "shortcut.register":
            guard let acc = s(0), let id = n(1) else { throw ShellError("EINVAL", "register needs an accelerator") }
            ok(try hotkeys.register(acc) { [weak self] in self?.emit("callback", ["id": id]) })
        case "shortcut.unregister": hotkeys.unregister(s(0) ?? ""); ok(nil)
        case "shortcut.unregisterAll": hotkeys.unregisterAll(); ok(nil)
        case "tray.set": ok(try traySet(d(0)))
        case "tray.remove": removeTray(); ok(nil)
        case "log":
            stderrLine("[page \(s(0) ?? "log")] \(s(1) ?? "")"); ok(nil)
        default:
            throw ShellError("ENOSYS", "\(op) is not available in the standalone build")
        }
    }

    // MARK: events back to the page
    func emit(_ kind: String, _ payload: Any) {
        shell?.webView.callAsyncJavaScript("window.__artifactDesktop && window.__artifactDesktop.event(kind, payload)",
                                           arguments: ["kind": kind, "payload": payload], in: nil, in: .page, completionHandler: nil)
    }
    lazy var clickHandler: (Int, [String: Any]) -> Void = { [weak self] id, item in self?.emit("callback", ["id": id, "payload": item]) }

    func resetPageState() {
        for p in procs.values where p.process.isRunning { p.process.terminate() }
        procs.removeAll()
        hotkeys.unregisterAll()
        removeTray()
    }

    // MARK: helpers
    private func bytes(_ v: Any?, _ enc: String?) throws -> Data {
        if let dict = v as? [String: Any], let b = dict["__b64"] as? String, let data = Data(base64Encoded: b) { return data }
        if let str = v as? String {
            if enc == "base64" { guard let data = Data(base64Encoded: str) else { throw ShellError("EINVAL", "invalid base64") }; return data }
            return Data(str.utf8)
        }
        throw ShellError("EINVAL", "data must be a string or Uint8Array")
    }

    static func statInfo(_ p: String, link: Bool) throws -> [String: Any] {
        var st = Darwin.stat()
        if (link ? lstat(p, &st) : stat(p, &st)) != 0 { throw posixError(p) }
        let fmt = st.st_mode & S_IFMT
        func ms(_ t: timespec) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6 }
        return ["size": Int(st.st_size), "mode": Int(st.st_mode), "mtimeMs": ms(st.st_mtimespec), "ctimeMs": ms(st.st_ctimespec),
                "birthtimeMs": ms(st.st_birthtimespec), "isFile": fmt == S_IFREG, "isDirectory": fmt == S_IFDIR, "isSymbolicLink": fmt == S_IFLNK]
    }

    static func osInfo() -> [String: Any] {
        var u = utsname(); uname(&u)
        let release = withUnsafePointer(to: &u.release) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        var tmp = NSTemporaryDirectory(); if tmp.hasSuffix("/") { tmp.removeLast() }
        let pi = ProcessInfo.processInfo
        return ["platform": "darwin", "arch": arch, "release": release, "hostname": pi.hostName, "homedir": NSHomeDirectory(),
                "tmpdir": tmp, "username": NSUserName(), "cpus": pi.activeProcessorCount, "totalmem": Double(pi.physicalMemory),
                "uptime": pi.systemUptime]
    }

    private func displayInfo(_ s: NSScreen) -> [String: Any] {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        func flip(_ r: NSRect) -> [String: Any] { ["x": r.minX, "y": shell.primaryHeight - r.maxY, "width": r.width, "height": r.height] }
        return ["id": Int(id), "label": s.localizedName, "bounds": flip(s.frame), "workArea": flip(s.visibleFrame),
                "size": ["width": s.frame.width, "height": s.frame.height], "workAreaSize": ["width": s.visibleFrame.width, "height": s.visibleFrame.height],
                "scaleFactor": s.backingScaleFactor, "rotation": Int(CGDisplayRotation(id)), "internal": CGDisplayIsBuiltin(id) != 0]
    }

    static func image(dataURL: String) -> NSImage? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
    static func png(_ img: NSImage, side: Int) throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ShellError("EIO", "could not encode the icon") }
        return data
    }

    // MARK: processes
    /// GUI apps start with a minimal PATH; add the usual tool folders so bare command names resolve.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !dirs.contains(d) { dirs.append(d) }
        env["PATH"] = dirs.joined(separator: ":")
        env.removeValue(forKey: "ARTIFACT_APP_CAPTURE_ICON")
        return env
    }()
    private func env(_ extra: [String: Any]?) -> [String: String] {
        var e = Desktop.environment
        for (k, v) in extra ?? [:] { e[k] = "\(v)" }
        return e
    }
    private func resolve(_ cmd: String, _ env: [String: String]) throws -> String {
        if cmd.contains("/") {
            let p = expand(cmd)
            guard FileManager.default.isExecutableFile(atPath: p) else { throw posixError(p, ENOENT) }
            return p
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/\(cmd)") {
            return "\(dir)/\(cmd)"
        }
        throw posixError(cmd, ENOENT)
    }

    private func spawn(id: Int, command: String, args: [String], options o: [String: Any]) throws -> Int32 {
        let proc = Proc(), p = proc.process
        let environment = env(o["env"] as? [String: Any])
        if (o["shell"] as? Bool) ?? false {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", ([command] + args).joined(separator: " ")]
        } else {
            p.executableURL = URL(fileURLWithPath: try resolve(command, environment))
            p.arguments = args
        }
        p.currentDirectoryURL = URL(fileURLWithPath: expand(o["cwd"] as? String))
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = proc.stdin
        do { try p.run() } catch { throw ShellError("ENOENT", "\(command): \(error.localizedDescription)") }
        procs[id] = proc

        let group = DispatchGroup()
        for (pipe, type) in [(out, "stdout"), (err, "stderr")] {
            group.enter()
            var rest = Data()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    if !rest.isEmpty { let tail = String(decoding: rest, as: UTF8.self); DispatchQueue.main.async { self?.emit("proc", [id, type, tail]) } }
                    group.leave(); return
                }
                rest.append(chunk)
                let (text, left) = splitUTF8(rest); rest = left
                if !text.isEmpty { DispatchQueue.main.async { self?.emit("proc", [id, type, text]) } }
            }
        }
        group.enter()
        p.terminationHandler = { [weak self] t in
            if t.terminationReason == .uncaughtSignal { proc.signal = signalNames[t.terminationStatus] ?? "SIG\(t.terminationStatus)" }
            else { proc.code = Int(t.terminationStatus) }
            DispatchQueue.main.async { self?.emit("proc", [id, "exit", proc.code, proc.signal]) }
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            self?.procs[id] = nil
            self?.emit("proc", [id, "close", proc.code, proc.signal])
        }
        return p.processIdentifier
    }

    private func exec(_ command: String, _ o: [String: Any], _ ok: @escaping (Any?) -> Void, _ fail: @escaping (Error) -> Void) {
        let p = Process(), out = Pipe(), err = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: expand(o["cwd"] as? String))
        p.environment = env(o["env"] as? [String: Any])
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        let input = o["input"] as? String
        let timeout = (o["timeout"] as? NSNumber)?.doubleValue ?? 0
        background(ok, fail) {
            try p.run()
            if let i = input { try? inp.fileHandleForWriting.write(contentsOf: Data(i.utf8)) }
            try? inp.fileHandleForWriting.close()
            var timedOut = false
            if timeout > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + timeout / 1000) { if p.isRunning { timedOut = true; p.terminate() } } }
            let cap = 8 * 1024 * 1024
            var errData = Data()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            errDone.wait()
            p.waitUntilExit()
            let signal: Any = p.terminationReason == .uncaughtSignal || timedOut ? (signalNames[p.terminationStatus] ?? "SIGTERM") : NSNull()
            return ["stdout": String(decoding: outData.prefix(cap), as: UTF8.self), "stderr": String(decoding: errData.prefix(cap), as: UTF8.self),
                    "code": p.terminationReason == .exit ? Int(p.terminationStatus) as Any : NSNull(), "signal": signal,
                    "truncated": outData.count > cap || errData.count > cap]
        }
    }

    // MARK: notifications
    private func notify(_ body: String, _ ok: @escaping (Any?) -> Void, _ fail: @escaping (Error) -> Void) {
        let center = UNUserNotificationCenter.current()
        if !notificationsReady { center.delegate = self; notificationsReady = true }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return DispatchQueue.main.async { fail(ShellError("EPERM", "notifications are turned off for this app in System Settings")) } }
            let content = UNMutableNotificationContent()
            content.title = config.name
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { e in
                DispatchQueue.main.async { if let e = e { fail(e) } else { ok(nil) } }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    // MARK: menu bar item
    private func traySet(_ o: [String: Any]) throws -> Bool {
        let icon = (o["icon"] as? String).flatMap(Desktop.image(dataURL:))
        let title = (o["title"] as? String).map { String($0.prefix(30)) } ?? ""
        guard icon != nil || !title.isEmpty else { throw ShellError("EINVAL", "tray.set needs an icon or a title") }
        if tray == nil { tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        guard let item = tray, let button = item.button else { return false }
        if let img = icon {
            let h: CGFloat = 18
            img.size = NSSize(width: img.size.width * h / max(img.size.height, 1), height: h)
            img.isTemplate = (o["iconIsTemplate"] as? Bool) ?? true
            button.image = img
        } else { button.image = nil }
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        let tip = (o["toolTip"] as? String).map { "\n" + String($0.prefix(100)) } ?? ""
        button.toolTip = "\(config.name)\(tip)"
        if let menu = o["menu"] as? [[String: Any]] {
            item.menu = Menus.build(menu, shell: shell, click: clickHandler)
            button.target = nil; button.action = nil; trayAction = nil
        } else {
            item.menu = nil
            if let id = (o["clickId"] as? NSNumber)?.intValue {
                trayAction = MenuAction { [weak self] _ in self?.emit("callback", ["id": id]) }
                button.target = trayAction; button.action = #selector(MenuAction.fire(_:))
            }
        }
        return true
    }
    private func removeTray() {
        if let t = tray { NSStatusBar.system.removeStatusItem(t) }
        tray = nil; trayAction = nil
    }
}

// MARK: global shortcuts (Carbon hot keys: work while another app is in front)
final class HotKeys {
    private var refs: [String: (EventHotKeyRef, UInt32)] = [:]
    static var handlers: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private var installed = false

    static let keys: [String: Int] = {
        var k: [String: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M,
            "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab, "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in f.enumerated() { k["f\(i + 1)"] = code }
        return k
    }()

    func register(_ accelerator: String, _ fn: @escaping () -> Void) throws -> Bool {
        var mods: UInt32 = 0, modCount = 0, key: Int?
        for t in accelerator.split(separator: "+").map({ $0.lowercased() }) {
            switch t {
            case "cmdorctrl", "commandorcontrol", "cmd", "command", "super", "meta": mods |= UInt32(cmdKey); modCount += 1
            case "ctrl", "control": mods |= UInt32(controlKey); modCount += 1
            case "alt", "option": mods |= UInt32(optionKey); modCount += 1
            case "shift": mods |= UInt32(shiftKey); modCount += 1
            default: key = HotKeys.keys[t]
            }
        }
        guard let code = key, modCount >= 2, accelerator.lowercased() != "cmd+q" else {
            throw ShellError("EINVAL", "\(accelerator): use two or more modifiers and a key")
        }
        install()
        unregister(accelerator)
        let id = nextId; nextId += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: OSType(0x4152_5446), id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let r = ref else { return false }
        refs[accelerator] = (r, id)
        HotKeys.handlers[id] = fn
        return true
    }
    func unregister(_ accelerator: String) {
        if let (r, id) = refs.removeValue(forKey: accelerator) { UnregisterEventHotKey(r); HotKeys.handlers[id] = nil }
    }
    func unregisterAll() { for k in Array(refs.keys) { unregister(k) } }
    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
