// Jarvis Hands: the small helper that lets Jarvis use the Mac's screen, mouse and keyboard for a task you asked for.
// It holds the Screen Recording and Accessibility permissions (the sandboxed app and the companion cannot), listens on
// a socket only you can open, shows a red border while it is in control, and stops the moment you move the mouse or
// press Esc. It refuses to act in Terminal, System Settings and password apps. Nothing it sees is saved.
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

let socketPath = NSHomeDirectory() + "/Library/Application Support/agent-pikachu/hands.sock"
/// Marks the events Jarvis posts, so the stop watcher can tell them from yours.
let mark: Int64 = 0x4A41_5256
let maxWidth = 1280.0, maxHeight = 800.0
let idleSeconds = 60.0
let blocked: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                            "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
                            "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.ScriptEditor2", "com.apple.Automator",
                            "com.apple.shortcuts", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
                            "com.github.wez.wezterm", "io.alacritty", "co.zeit.hyper", "com.apple.ActivityMonitor", "com.apple.Console",
                            // Jarvis itself: it must never click its own Approve buttons.
                            "dev.agentpikachu.app", "dev.agentpikachu.hands"]

/** System panels an approved app opens (Open and Save dialogs), which count as part of that app. */
let panels: Set<String> = ["com.apple.appkit.xpc.openAndSavePanelService"]

struct Failure: Error { let message: String }

/// The bundle id of an app by its name, from the running apps or the usual app folders.
func bundleID(of name: String) -> String? {
    let want = name.trimmingCharacters(in: .whitespaces).lowercased()
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == want }) { return app.bundleIdentifier }
    let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    for d in dirs {
        let url = URL(fileURLWithPath: d).appendingPathComponent(name.trimmingCharacters(in: .whitespaces) + ".app")
        if let id = Bundle(url: url)?.bundleIdentifier { return id }
    }
    return nil
}

@MainActor
final class Hands {
    var stopped = false
    var lastAction = Date.distantPast
    var overlay: NSWindow?
    var held: CGEventFlags = []
    /// The apps you approved for this task: Jarvis acts only in these.
    var allowed: Set<String> = []
    var allowedNames = ""
    /// While the Allow dialog is up nothing else runs, not even another request to start.
    var asking = false

    /// Screenshot pixels per screen point: the screenshot fits in about 1280x800.
    var scale: Double {
        let b = CGDisplayBounds(CGMainDisplayID())
        return min(1, maxWidth / b.width, maxHeight / b.height)
    }

    func watchForYou() {
        // Your own mouse or keys (not Jarvis's marked events) take control back at once.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.overlay != nil, e.cgEvent?.getIntegerValueField(.eventSourceUserData) != mark else { return }
                if e.type == .mouseMoved && abs(e.deltaX) + abs(e.deltaY) < 3 { return } // a nudge of the desk is not you
                self.stopped = true
                self.hideOverlay()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            // Idle for a minute: the task's approval ends; a new task asks again.
            MainActor.assumeIsolated { if Date().timeIntervalSince(self.lastAction) > idleSeconds { self.hideOverlay(); self.allowed = [] } }
        }
    }

    func showOverlay() {
        guard overlay == nil, let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true; w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = Border(frame: screen.frame)
        w.orderFrontRegardless()
        overlay = w
    }

    func hideOverlay() { overlay?.orderOut(nil); overlay = nil }

    func handle(_ req: [String: Any]) async throws -> [String: Any] {
        let action = req["action"] as? String ?? ""
        if asking { throw Failure(message: "Waiting for the user to answer the Allow dialog.") }
        if action == "begin" {
            allowed = [] // nothing runs while the dialog is up, not even a click aimed at it
            stopped = false
            try checkPermissions()
            let names = ((req["input"] as? [String: Any])?["apps"] as? String ?? "")
                .components(separatedBy: CharacterSet(charactersIn: ",&/")).flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let ids = names.compactMap(bundleID(of:))
            guard !names.isEmpty, ids.count == names.count else { throw Failure(message: "Could not find the app \(names.filter { bundleID(of: $0) == nil }.joined(separator: ", ")) on this Mac. Use the app's exact name.") }
            if let bad = ids.first(where: blocked.contains) { throw Failure(message: "Jarvis does not control \(bad) (terminals, code editors, System Settings, password apps and Jarvis itself are off limits).") }
            // Asked here, by the app that holds the permissions, in a dialog only your own mouse or keys can answer
            // (nothing else can post input: that needs this app's permission). So no other program can start it.
            let task = ((req["input"] as? [String: Any])?["task"] as? String ?? "").prefix(200)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Let Jarvis use \(names.joined(separator: ", "))?"
            alert.informativeText = "\(task.isEmpty ? "" : "To \(task).\n\n")Jarvis works only in \(names.count == 1 ? "this app" : "these apps"). A red border shows while it works. Move the mouse or press Esc to stop it."
            alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Don't Allow")
            alert.window.level = .floating
            asking = true
            let answer = alert.runModal()
            asking = false
            guard answer == .alertFirstButtonReturn else { allowed = []; throw Failure(message: "The user said no to using the Mac for this.") }
            allowed = Set(ids); allowedNames = names.joined(separator: ", ")
            // Bring the first app to the front, so the task starts there.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ids[0]) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                try? await Task.sleep(for: .milliseconds(600))
            }
            lastAction = Date(); showOverlay()
            return ["ok": true]
        }
        if action == "end" { hideOverlay(); allowed = []; return ["ok": true] }
        if allowed.isEmpty { throw Failure(message: "No approved task: call use_computer again (the approval ends after the answer or a minute of no use).") }
        if stopped { throw Failure(message: "The user took back control (moved the mouse or pressed Esc). Stop and ask them what to do.") }
        try checkPermissions()
        let looks = ["screenshot", "zoom", "cursor_position", "wait"].contains(action)
        if !looks {
            // Only in the apps you approved, checked here (not left to the model): the app in front, the window that
            // has the keyboard, and the window under every spot a click, drag or scroll lands on.
            try checkFocus()
            let input = req["input"] as? [String: Any] ?? [:]
            var spots = try ["coordinate", "start_coordinate"].compactMap { try point(input[$0]) }
            if spots.isEmpty, action.contains("click") || action.contains("mouse") || action == "scroll" { spots = [cursor()] }
            for p in spots { try checkSpot(p) }
        }
        lastAction = Date(); showOverlay()
        let input = req["input"] as? [String: Any] ?? [:]
        let mods = flags(input["text"] as? String)
        switch action {
        case "screenshot": return try await image(region: nil)
        case "zoom":
            guard let r = input["region"] as? [Double], r.count == 4, r[2] > r[0], r[3] > r[1] else { throw Failure(message: "region must be [x0, y0, x1, y1]") }
            return try await image(region: CGRect(x: r[0] / scale, y: r[1] / scale, width: (r[2] - r[0]) / scale, height: (r[3] - r[1]) / scale))
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let at = try point(input["coordinate"]) ?? cursor()
            let button: CGMouseButton = action == "right_click" ? .right : action == "middle_click" ? .center : .left
            let count = action == "double_click" ? 2 : action == "triple_click" ? 3 : 1
            move(to: at)
            for n in 1...count { mouse(button, down: true, at: at, clicks: n, flags: mods); mouse(button, down: false, at: at, clicks: n, flags: mods) }
        case "left_click_drag":
            guard let from = try point(input["start_coordinate"]), let to = try point(input["coordinate"]) else { throw Failure(message: "needs start_coordinate and coordinate") }
            move(to: from); mouse(.left, down: true, at: from, flags: mods)
            for i in 1...10 { let t = Double(i) / 10; post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), mouseButton: .left)); usleep(15_000) }
            mouse(.left, down: false, at: to, flags: mods)
        case "mouse_move":
            guard let at = try point(input["coordinate"]) else { throw Failure(message: "needs coordinate") }
            move(to: at)
        case "left_mouse_down": mouse(.left, down: true, at: cursor(), flags: held)
        case "left_mouse_up": mouse(.left, down: false, at: cursor(), flags: held)
        case "cursor_position":
            let c = cursor()
            return ["text": "X=\(Int(c.x * scale)), Y=\(Int(c.y * scale))"]
        case "scroll":
            if let at = try point(input["coordinate"]) { move(to: at) }
            let amount = Int32(max(1, min(50, input["scroll_amount"] as? Int ?? 3)))
            let dir = input["scroll_direction"] as? String ?? "down"
            let (dy, dx): (Int32, Int32) = dir == "up" ? (amount, 0) : dir == "down" ? (-amount, 0) : dir == "left" ? (0, amount) : (0, -amount)
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            e?.flags = mods
            post(e)
        case "type":
            guard let text = input["text"] as? String else { throw Failure(message: "needs text") }
            try type(text)
        case "key":
            guard let combo = input["text"] as? String else { throw Failure(message: "needs text") }
            let times = max(1, min(100, input["repeat"] as? Int ?? 1))
            for _ in 0..<times { try checkFocus(); try press(combo) }
        case "hold_key":
            guard let combo = input["text"] as? String else { throw Failure(message: "needs text") }
            let (code, f) = try parse(combo)
            post(key(code, down: true, flags: f)); held = f
            try await Task.sleep(for: .seconds(max(0, min(300, input["duration"] as? Double ?? 1))))
            post(key(code, down: false, flags: [])); held = []
        case "wait":
            try await Task.sleep(for: .seconds(max(0, min(300, input["duration"] as? Double ?? 1))))
        default: throw Failure(message: "unknown action \(action)")
        }
        usleep(150_000) // let the app react before the next step
        return ["text": "OK"]
    }

    func checkPermissions() throws {
        let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let screen = CGPreflightScreenCaptureAccess()
        if !screen { CGRequestScreenCaptureAccess() }
        if ax && screen { return }
        // A new Screen Recording grant needs a fresh start: quit, so the next request starts Jarvis Hands again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        throw Failure(message: "Jarvis Hands needs \([ax ? nil : "Accessibility", screen ? nil : "Screen Recording"].compactMap { $0 }.joined(separator: " and ")) permission. Tell the user: System Settings > Privacy & Security, turn on Jarvis Hands, then ask again.")
    }

    var scope: String { allowedNames.isEmpty ? "the approved app" : allowedNames }

    /// The app in front and the app whose window has the keyboard must both be approved. Anything unreadable refuses.
    func checkFocus() throws {
        let front = NSWorkspace.shared.frontmostApplication
        guard let id = front?.bundleIdentifier, allowed.contains(id) else {
            throw Failure(message: "Jarvis may only use \(scope) for this task, and \(front?.localizedName ?? "another app") is in front. Ask the user to bring \(scope) to the front, or ask them before using another app.")
        }
        var focused: CFTypeRef?
        var pid: pid_t = 0
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
              let app = focused, CFGetTypeID(app) == AXUIElementGetTypeID(), AXUIElementGetPid(app as! AXUIElement, &pid) == .success,
              let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            throw Failure(message: "Could not tell which app has the keyboard, so nothing was done. Take a screenshot and try again.")
        }
        // An Open or Save dialog of an approved app (the app in front, checked above) has the keyboard as its own service.
        guard allowed.contains(owner) || panels.contains(owner) else { throw Failure(message: "Another app (\(owner)) has the keyboard. Jarvis may only use \(scope).") }
    }

    /// Whether this point is on one of the approved app's own menu bar titles (File, Edit...), not the Apple menu
    /// (Restart, Shut Down, Force Quit) and not a status icon.
    func isApprovedMenuTitle(at p: CGPoint) -> Bool {
        var hit: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success, let item = hit,
              AXUIElementGetPid(item, &pid) == .success, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, allowed.contains(id) else { return false }
        func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil }
        guard (value(item, kAXRoleAttribute) as? String) == kAXMenuBarItemRole, let parent = value(item, kAXParentAttribute),
              CFGetTypeID(parent) == AXUIElementGetTypeID(), let items = value(parent as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              let first = items.first else { return false }
        return !CFEqual(first, item) // the first menu bar item is the Apple menu
    }

    /// The window under this point must belong to an approved app (or its dialog), or be the menu bar of the app in
    /// front. The desktop, the Dock and other apps' windows and menu bar icons are refused.
    func checkSpot(_ p: CGPoint) throws {
        let border = overlay.map { CGWindowID($0.windowNumber) }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw Failure(message: "Could not read the windows on screen, so nothing was done.")
        }
        for w in list {
            // Only the red border (it lets clicks through) is skipped; any other window of Jarvis Hands is refused.
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, (w[kCGWindowNumber as String] as? CGWindowID) != border, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p) else { continue }
            let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if let owner, allowed.contains(owner) || panels.contains(owner) { return }
            // The menu bar strip (drawn by the system): only a menu title of an approved app, never the Apple menu.
            if owner == nil, (w[kCGWindowName as String] as? String) == "Menubar", isApprovedMenuTitle(at: p) { return }
            throw Failure(message: "That spot is \(owner.map { "in another app (\($0))" } ?? "outside the approved app"). Jarvis may only use \(scope).")
        }
        throw Failure(message: "There is no window of \(scope) at that spot.")
    }

    // MARK: screen

    func image(region: CGRect?) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw Failure(message: "no display (is the Mac locked?)") }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []) // never the red border
        let config = SCStreamConfiguration()
        let full = CGSize(width: Double(display.width) * scale, height: Double(display.height) * scale)
        if let region {
            config.sourceRect = region
            let fit = min(full.width / region.width, full.height / region.height)
            config.width = Int(region.width * fit); config.height = Int(region.height * fit)
        } else { config.width = Int(full.width); config.height = Int(full.height) }
        config.showsCursor = true
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: shot).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw Failure(message: "could not encode the screenshot") }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return ["image": jpeg.base64EncodedString(), "width": config.width, "height": config.height, "app": front]
    }

    // MARK: input

    func point(_ v: Any?) throws -> CGPoint? {
        guard let v else { return nil }
        guard let c = v as? [Double], c.count == 2 else { throw Failure(message: "coordinate must be [x, y]") }
        return CGPoint(x: c[0] / scale, y: c[1] / scale)
    }
    func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
    func post(_ e: CGEvent?) { guard let e else { return }; e.setIntegerValueField(.eventSourceUserData, value: mark); e.post(tap: .cghidEventTap) }
    func move(to p: CGPoint) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)); usleep(30_000) }
    func mouse(_ b: CGMouseButton, down: Bool, at p: CGPoint, clicks: Int = 1, flags: CGEventFlags) {
        let type: CGEventType = switch b { case .right: down ? .rightMouseDown : .rightMouseUp; case .center: down ? .otherMouseDown : .otherMouseUp; default: down ? .leftMouseDown : .leftMouseUp }
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: b)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)); e?.flags = flags
        post(e); usleep(20_000)
    }
    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); e?.flags = flags; return e
    }
    func press(_ combo: String) throws {
        let (code, f) = try parse(combo)
        post(key(code, down: true, flags: f)); post(key(code, down: false, flags: f)); usleep(20_000)
    }
    func type(_ text: String) throws {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            try checkFocus() // the keyboard may have moved to another app since the last line
            if line.offset > 0 { post(key(36, down: true, flags: [])); post(key(36, down: false, flags: [])) }
            let units = Array(line.element.utf16)
            for start in stride(from: 0, to: units.count, by: 16) {
                let chunk = Array(units[start..<min(start + 16, units.count)])
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    post(e)
                }
                usleep(12_000)
            }
        }
    }

    func flags(_ text: String?) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in (text ?? "").lowercased().split(separator: "+") {
            switch m.trimmingCharacters(in: .whitespaces) {
            case "shift": f.insert(.maskShift)
            case "ctrl", "control": f.insert(.maskControl)
            case "alt", "option", "opt": f.insert(.maskAlternate)
            case "super", "cmd", "command", "meta", "win": f.insert(.maskCommand)
            case "fn": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }

    func parse(_ combo: String) throws -> (CGKeyCode, CGEventFlags) {
        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let code = Self.keys[last.lowercased()] ?? (last.count == 1 ? Self.keys[last.lowercased()] : nil) else {
            throw Failure(message: "unknown key \(combo)")
        }
        var f = flags(parts.dropLast().joined(separator: "+"))
        if last.count == 1, last != last.lowercased() { f.insert(.maskShift) } // "A" is shift+a
        return (code, f)
    }

    static let keys: [String: CGKeyCode] = {
        var k: [String: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "space": 49, "backspace": 51, "delete": 51, "forwarddelete": 117,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "page_up": 116, "pageup": 116,
            "prior": 116, "page_down": 121, "pagedown": 121, "next": 121, "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44,
            "semicolon": 41, "apostrophe": 39, "bracketleft": 33, "bracketright": 30, "backslash": 42, "grave": 50, "capslock": 57,
            "cmd": 55, "super": 55, "shift": 56, "alt": 58, "option": 58, "ctrl": 59, "control": 59]
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { k["f\(i + 1)"] = CGKeyCode(code) }
        return k
    }()
}

/// The red frame and the note at the top while Jarvis is in control.
final class Border: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let red = NSColor(red: 0.93, green: 0.2, blue: 0.2, alpha: 0.9)
        red.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)); path.lineWidth = 6; path.stroke()
        let label = "  Jarvis is using your Mac. Move the mouse or press Esc to stop.  " as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 40, width: size.width, height: size.height + 10)
        red.setFill(); NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        label.draw(at: NSPoint(x: box.minX, y: box.minY + 5), withAttributes: attrs)
    }
}

// MARK: socket (newline-delimited JSON, one connection at a time is enough)

func serve(_ hands: Hands) {
    unlink(socketPath)
    umask(0o077) // the socket is created owner-only, never briefly open to others
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in socketPath.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) } }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }) == 0, listen(fd, 4) == 0 else { exit(1) }
    chmod(socketPath, 0o600) // only you
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { talk(client, hands) }
        }
    }
}

func talk(_ client: Int32, _ hands: Hands) {
    defer { close(client) }
    var pending = Data()
    var buf = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(client, &buf, buf.count)
        if n <= 0 { return }
        pending.append(contentsOf: buf[0..<n])
        while let nl = pending.firstIndex(of: 10) {
            let line = pending[pending.startIndex..<nl]; pending = Data(pending[(nl + 1)...])
            guard let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var reply: [String: Any] = [:]
            nonisolated(unsafe) let request = req
            Task { @MainActor in
                do { reply = try await hands.handle(request) } catch let f as Failure { reply = ["error": f.message] } catch { reply = ["error": error.localizedDescription] }
                done.signal()
            }
            done.wait()
            reply["id"] = req["id"]
            var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
            out.append(10)
            _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let hands = Hands()
    hands.watchForYou()
    serve(hands)
}
app.run()
