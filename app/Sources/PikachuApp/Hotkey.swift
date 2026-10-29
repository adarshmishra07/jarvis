import Carbon.HIToolbox

/// Global push-to-talk hotkey. Carbon reports press and release inside the sandbox with no extra permission (spike S5).
final class Hotkey {
    private static var handlers: [UInt32: (pressed: () -> Void, released: () -> Void)] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init?(id: UInt32, keyCode: UInt32, modifiers: UInt32, pressed: @escaping () -> Void, released: @escaping () -> Void) {
        Self.installIfNeeded()
        Self.handlers[id] = (pressed, released)
        let hotKeyID = EventHotKeyID(signature: OSType(0x504B5543), id: id) // 'PKUC'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard let h = Hotkey.handlers[hk.id] else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { h.pressed() } else { h.released() }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
