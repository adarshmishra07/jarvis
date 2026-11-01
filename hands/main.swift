// Jarvis Hands: the small helper that lets Jarvis use the Mac's screen, mouse and keyboard for a task you asked for.
// It holds the Screen Recording and Accessibility permissions (the sandboxed app and the companion cannot), listens on
// a socket only you can open, shows a red border while it is in control, and stops the moment you move the mouse or
// press Esc. It refuses to act in Terminal, System Settings and password apps. Nothing it sees is saved.
// It never deletes, spends money or sends anything out (never.json, see rules.swift): before each click it reads the
// name of the button under the mouse, before each shortcut the menu item it would run, and refuses those outright.
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
                            "com.apple.AppStore", // everything in it is a purchase
                            // Jarvis itself: it must never click its own Approve buttons.
                            "dev.agentpikachu.app", "dev.agentpikachu.hands"]

/** System panels an approved app opens (Open and Save dialogs), which count as part of that app. */
let panels: Set<String> = ["com.apple.appkit.xpc.openAndSavePanelService"]

struct Failure: Error { let message: String }

/// Without its rules Jarvis Hands does nothing at all.
let rules: Rules? = Bundle.main.url(forResource: "never", withExtension: "json").flatMap { try? Rules(json: Data(contentsOf: $0)) }

/// Apps where a key or click can send something: browsers, chat and mail. Here Return is pressed only in a search or
/// address field, single keys only in a text field (web apps use them as shortcuts), nothing is pasted, no file is
/// picked, and a button without a readable name is not clicked.
let networkApps: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox",
                                "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "app.zen-browser.zen",
                                "com.apple.MobileSMS", "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
                                "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord",
                                "com.microsoft.teams2", "org.whispersystems.signal-desktop", "us.zoom.xos", "com.apple.FaceTime", "com.facebook.archon.developerID",
                                "org.telegram.desktop", "com.readdle.SparkDesktop", "com.mimestream.Mimestream", "org.mozilla.thunderbird", "com.google.Chrome.canary",
                                "com.google.Chrome.beta", "org.chromium.Chromium", "com.apple.SafariTechnologyPreview", "notion.id", "com.linear", "com.openai.chat",
                                "com.anthropic.claudefordesktop", "com.figma.Desktop", "md.obsidian"]
let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
let pressRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"]
/// Keys that only move around: tab, esc, arrows, home, end, page up and down.
let moveKeys: Set<CGKeyCode> = [48, 53, 123, 124, 125, 126, 115, 119, 116, 121]

func ax(_ el: AXUIElement, _ attr: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil }
func axText(_ el: AXUIElement, _ attr: String) -> String { ax(el, attr) as? String ?? "" }
func axElement(_ v: CFTypeRef?) -> AXUIElement? { guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return (v as! AXUIElement) }
func axChildren(_ el: AXUIElement) -> [AXUIElement] { ax(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func axBundle(_ el: AXUIElement) -> String? { var pid: pid_t = 0; return AXUIElementGetPid(el, &pid) == .success ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil }
func axAt(_ p: CGPoint) -> AXUIElement? {
    var hit: AXUIElement?
    return AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success ? hit : nil
}
func axFocused() -> AXUIElement? { axElement(ax(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)) }
/// The element and its parents, nearest first.
func axLine(_ el: AXUIElement, _ count: Int) -> [AXUIElement] {
    var out = [el]
    while out.count < count, let up = axElement(ax(out[out.count - 1], kAXParentAttribute)) { out.append(up) }
    return out
}
func isPressable(_ el: AXUIElement) -> Bool {
    if pressRoles.contains(axText(el, kAXRoleAttribute)) { return true }
    var names: CFArray?
    return AXUIElementCopyActionNames(el, &names) == .success && ((names as? [String]) ?? []).contains(kAXPressAction)
}
/// Everything that names a button: its title, description, help and id, and the text and image names inside it.
func label(_ el: AXUIElement) -> String {
    var parts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute].map { axText(el, $0) }
    if ["AXStaticText", "AXImage"].contains(axText(el, kAXRoleAttribute)) { parts.append(axText(el, kAXValueAttribute)) }
    var queue = axChildren(el).map { ($0, 1) }
    while let (c, depth) = queue.first, parts.count < 30 {
        queue.removeFirst()
        let role = axText(c, kAXRoleAttribute)
        if role == "AXStaticText" { parts.append(axText(c, kAXValueAttribute)) }
        parts += [axText(c, kAXTitleAttribute), axText(c, kAXDescriptionAttribute)]
        if depth < 3 { queue += axChildren(c).map { ($0, depth + 1) } }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
}
/// The web page an element is on, when it is in a browser.
func pageURL(_ el: AXUIElement) -> URL? {
    for up in axLine(el, 80) where axText(up, kAXRoleAttribute) == "AXWebArea" {
        if let u = ax(up, "AXURL") { return CFGetTypeID(u) == CFURLGetTypeID() ? (u as! URL) : (u as? String).flatMap(URL.init(string:)) }
    }
    return nil
}

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
    /// The app the mouse button went down in, while it is held: a drag may not carry anything into another app.
    var downApp: String?

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
            allowed = Set(ids); allowedNames = names.joined(separator: ", "); downApp = nil
            // Chat apps built on Electron show their buttons' names only when asked to.
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier.map(allowed.contains) == true {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            // Bring the first app to the front, so the task starts there.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ids[0]) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                try? await Task.sleep(for: .milliseconds(600))
            }
            lastAction = Date(); showOverlay()
            return ["ok": true]
        }
        if action == "end" { hideOverlay(); allowed = []; downApp = nil; typed = ""; typedInto = nil; return ["ok": true] }
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
            try checkRules(action, input)
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
            for n in 0..<times { try checkFocus(); if n > 0 { try checkRules(action, input) }; try press(combo) } // each press: the screen changes
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

    // MARK: never (rules.swift): delete, money, send

    var front: String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }
    /// What has been typed into the field that has the keyboard, so a number split over several calls is still seen.
    var typed = ""
    var typedInto: AXUIElement?

    /// Browsers, chat and mail, and anything showing a web page (Electron apps, other browsers).
    func isNet(_ el: AXUIElement?) -> Bool {
        networkApps.contains(front) || el.flatMap(axBundle).map(networkApps.contains) == true || el.flatMap(pageURL) != nil
    }

    func checkRules(_ action: String, _ input: [String: Any]) throws {
        guard let rules else { throw Failure(message: "Jarvis Hands is missing its safety rules, so it does nothing. Reinstall Jarvis.") }
        switch action {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            try checkTarget(try point(input["coordinate"]) ?? cursor(), rules)
        case "left_click_drag":
            guard let from = try point(input["start_coordinate"]), let to = try point(input["coordinate"]) else { return }
            try checkTarget(from, rules); try checkTarget(to, rules, drop: true)
            if axAt(from).flatMap(axBundle) != axAt(to).flatMap(axBundle) { throw refusal("send") } // dragging a file into a browser is an upload
        case "left_mouse_down": try checkTarget(cursor(), rules); downApp = axAt(cursor()).flatMap(axBundle) ?? ""
        case "left_mouse_up": try checkTarget(cursor(), rules, drop: true); downApp = nil
        case "mouse_move":
            if let d = downApp, let to = try point(input["coordinate"]), axAt(to).flatMap(axBundle) != d { throw refusal("send") }
        case "type":
            let text = input["text"] as? String ?? ""
            // Control characters act as keys (a carriage return sends, a DEL deletes): only newlines and tabs, which are checked.
            if text.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7F }) {
                throw Failure(message: "Refused: type plain text only (no control characters). Use the key action for keys.")
            }
            let focus = axFocused()
            if typedInto == nil || focus == nil || !CFEqual(typedInto!, focus!) { typed = "" }
            typedInto = focus; typed = String((typed + text).suffix(200))
            if rules.personal(typed) { throw Failure(message: "Refused: Jarvis never types phone, card or ID numbers or email addresses. Ask the user to type that part themselves.") }
            try checkTyping()
            if text.contains("\n") { try checkKey(36, [], rules) }
        case "key", "hold_key":
            let (code, f) = try parse(input["text"] as? String ?? "")
            try checkKey(code, f, rules)
        default: break
        }
    }

    /// What a click (or a drop) at this spot would press: refused when its name deletes, pays or sends, when it is on
    /// a payment page, when it is a file picker in an app that can upload, or when a button there has no readable name.
    func checkTarget(_ p: CGPoint, _ rules: Rules, drop: Bool = false) throws {
        let hit = axAt(p)
        let net = isNet(hit)
        guard let hit else {
            if net { throw Failure(message: "Could not read what is at that spot, so nothing was done (in this app a click can send). Ask the user to click it.") }
            return
        }
        if let url = pageURL(hit), rules.moneySite(url) { throw refusal("money") }
        if net, axBundle(hit).map(panels.contains) == true { throw refusal("send") } // picking a file to upload
        let line = axLine(hit, 8)
        // Every button around the spot counts (an icon inside a "Delete" button is pressable too).
        let names = line.filter(isPressable).map(label)
        if let kind = names.compactMap(rules.never).first { throw refusal(kind) }
        if net, !names.isEmpty, names.allSatisfy(\.isEmpty) { throw Failure(message: "That button has no name Jarvis can read, so it cannot check that it does not send, pay or delete. Ask the user to click it.") }
        // A drop lands on whatever is there, a Trash mailbox or folder in a sidebar too.
        if drop, let kind = line.prefix(4).compactMap({ rules.never(label($0) + " " + axText($0, kAXValueAttribute)) }).first { throw refusal(kind) }
    }

    /// In apps that can send, keys go only into a text field: elsewhere a single key can be a shortcut (delete in Gmail).
    func checkTyping() throws {
        let focus = axFocused()
        guard isNet(focus) else { return }
        guard let focus, textRoles.contains(axText(focus, kAXRoleAttribute)) else {
            throw Failure(message: "Click into a text field first: in this app, keys outside a text field can be shortcuts that send or delete.")
        }
    }

    /// The window that has the keyboard, when it is a dialog or has a sheet open (Save, Replace, Delete...).
    func dialog() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let win = axElement(ax(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)) else { return nil }
        if let sheet = axChildren(win).first(where: { axText($0, kAXRoleAttribute) == "AXSheet" }) { return sheet }
        return ["AXDialog", "AXSystemDialog"].contains(axText(win, kAXSubroleAttribute)) ? win : nil
    }

    /// A menu is open (from the menu bar or a right click): keys would choose one of its items unseen.
    func menuOpen() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }

    func checkKey(_ code: CGKeyCode, _ f: CGEventFlags, _ rules: Rules) throws {
        let focus = axFocused()
        let net = isNet(focus)
        let command = f.contains(.maskCommand) || f.contains(.maskControl)
        let presses = [36, 76, 49].contains(code)
        if f.contains(.maskCommand), code == 51 || code == 117 { throw refusal("delete") } // Move to Trash, delete line or message
        if net, f.contains(.maskCommand), code == 9 { throw refusal("send") } // pasting could put anything you copied into a message or page
        if presses, menuOpen() { throw Failure(message: "A menu is open: click the menu item instead of pressing keys, so Jarvis can check what it does.") }
        if command, let kind = menuTitles(code).compactMap(rules.never).first { throw refusal(kind) }
        if let sheet = dialog() {
            // Return presses the default button, a Cmd-letter one of the others ("Don't Save" is Cmd-D).
            if command { throw Failure(message: "A dialog is open: click its button instead of a shortcut, so Jarvis can check what it does.") }
            if code == 36 || code == 76, let button = axElement(ax(sheet, kAXDefaultButtonAttribute)), let kind = rules.never(label(button)) { throw refusal(kind) }
        }
        if let focus, let url = pageURL(focus), rules.moneySite(url) { throw refusal("money") }
        let role = focus.map { axText($0, kAXRoleAttribute) } ?? ""
        if presses, let focus, !textRoles.contains(role), isPressable(focus) { // a text box can be pressable too: Return there sends
            let name = label(focus)
            if let kind = rules.never(name) { throw refusal(kind) }
            if net, name.isEmpty { throw Failure(message: "The button that has the keyboard has no readable name, so Jarvis does not press it. Ask the user.") }
            return
        }
        if code == 36 || code == 76, net {
            // Only a search field, or the browser's own address bar (not a field on the page: "Email address" submits a form).
            let field = focus.map { el in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute].map { axText(el, $0) }.joined(separator: " ") } ?? ""
            let search = role == "AXSearchField" || focus.map { axText($0, kAXSubroleAttribute) } == "AXSearchField"
            let addressBar = focus.map { pageURL($0) == nil } == true && textRoles.contains(role) && field.range(of: "address|url|location", options: [.regularExpression, .caseInsensitive]) != nil
            guard search || addressBar else {
                throw Failure(message: "Refused: in this app Return can send a message or a form, so Jarvis presses it only in a search field or the address bar. Tell the user it is ready for them to press Return or Send.")
            }
            return
        }
        // Delete keys only edit text; on a selected email or photo they delete it.
        if code == 51 || code == 117, !textRoles.contains(role) { throw refusal("delete") }
        if net, !command, !moveKeys.contains(code), !textRoles.contains(role) { try checkTyping() }
    }

    /// The menu items on this key in the app in front, whatever their modifiers (an uppercase "D" is Cmd-Shift-D,
    /// Send in Mail, and reports no Shift): refusing when any of them deletes, pays or sends is the safe side.
    func menuTitles(_ code: CGKeyCode) -> [String] {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let bar = axElement(ax(AXUIElementCreateApplication(pid), kAXMenuBarAttribute)) else { return [] }
        let char = Self.keys.first(where: { $0.value == code && $0.key.count == 1 })?.key
        var out: [String] = []
        var queue = axChildren(bar).map { ($0, 0) }
        while let (el, depth) = queue.first {
            queue.removeFirst()
            if axText(el, kAXRoleAttribute) == "AXMenuItem" {
                let vk = ax(el, kAXMenuItemCmdVirtualKeyAttribute) as? Int
                let c = axText(el, kAXMenuItemCmdCharAttribute).lowercased()
                if vk == Int(code) || (!c.isEmpty && c == char) { out.append(axText(el, kAXTitleAttribute)) }
            }
            if depth < 6 { queue += axChildren(el).map { ($0, depth + 1) } }
        }
        return out
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
