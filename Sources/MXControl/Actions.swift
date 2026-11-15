import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut to send.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags raw value (device-independent bits)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask) }

    var label: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
            kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        ]
        if let s = special[Int(code)] { return s }
        // Ask the current keyboard layout what character the key makes.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw in
            UCKeyTranslate(raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// What a remapped button or key does.
enum ButtonAction: Codable, Equatable, Hashable {
    case keystroke(KeyCombo)
    case missionControl
    case appExpose
    case showDesktop
    case apps
    case spotlight
    case playPause, nextTrack, previousTrack
    case volumeUp, volumeDown, mute
    case back, forward
    case openApp(path: String)
    case openURL(String)
    case shell(String)
    case doNothing

    enum Kind: String, CaseIterable, Identifiable {
        case keystroke, missionControl, appExpose, showDesktop, apps, spotlight
        case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
        case back, forward, openApp, openURL, shell, doNothing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keystroke: "Keyboard shortcut…"
            case .missionControl: "Mission Control"
            case .appExpose: "App Exposé"
            case .showDesktop: "Show Desktop"
            case .apps: "Apps"
            case .spotlight: "Spotlight"
            case .playPause: "Play / Pause"
            case .nextTrack: "Next Track"
            case .previousTrack: "Previous Track"
            case .volumeUp: "Volume Up"
            case .volumeDown: "Volume Down"
            case .mute: "Mute"
            case .back: "Back (⌘[)"
            case .forward: "Forward (⌘])"
            case .openApp: "Open App…"
            case .openURL: "Open URL…"
            case .shell: "Run Shell Command…"
            case .doNothing: "Do Nothing"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .keystroke: .keystroke
        case .missionControl: .missionControl
        case .appExpose: .appExpose
        case .showDesktop: .showDesktop
        case .apps: .apps
        case .spotlight: .spotlight
        case .playPause: .playPause
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .mute: .mute
        case .back: .back
        case .forward: .forward
        case .openApp: .openApp
        case .openURL: .openURL
        case .shell: .shell
        case .doNothing: .doNothing
        }
    }

    /// A starting value when the user picks a kind from the menu.
    static func make(_ kind: Kind) -> ButtonAction {
        switch kind {
        case .keystroke: .keystroke(KeyCombo(keyCode: UInt16(kVK_ANSI_C), modifiers: NSEvent.ModifierFlags.command.rawValue))
        case .missionControl: .missionControl
        case .appExpose: .appExpose
        case .showDesktop: .showDesktop
        case .apps: .apps
        case .spotlight: .spotlight
        case .playPause: .playPause
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .mute: .mute
        case .back: .back
        case .forward: .forward
        case .openApp: .openApp(path: "")
        case .openURL: .openURL("https://")
        case .shell: .shell("")
        case .doNothing: .doNothing
        }
    }

    var summary: String {
        switch self {
        case .keystroke(let k): return k.label
        case .openApp(let p): return p.isEmpty ? "Open App" : "Open " + FileManager.default.displayName(atPath: p)
        case .openURL(let u): return u
        case .shell(let c): return c.isEmpty ? "Shell command" : "$ " + c
        default: return kind.label
        }
    }
}

enum GestureDirection: String, Codable, CaseIterable, Identifiable {
    case tap, up, down, left, right
    var id: String { rawValue }
    var label: String {
        switch self { case .tap: "Click"; case .up: "Hold + move up"; case .down: "Hold + move down"; case .left: "Hold + move left"; case .right: "Hold + move right" }
    }
}

/// Performs actions. Keystrokes and media keys need Accessibility permission.
@MainActor
enum ActionRunner {
    static func perform(_ action: ButtonAction) {
        // While Crossover is controlling the PC, the button acts on the PC.
        if Crossover.shared.performRemote(action) { return }
        switch action {
        case .keystroke(let k): sendKey(k.keyCode, flags: cgFlags(k.flags))
        case .missionControl: missionControl(nil)
        case .appExpose: missionControl("2")
        case .showDesktop: missionControl("1")
        case .apps: openSystemApp("/System/Applications/Apps.app", fallback: "/System/Applications/Launchpad.app")
        case .spotlight: sendKey(UInt16(kVK_Space), flags: .maskCommand)
        case .playPause: mediaKey(16)
        case .nextTrack: mediaKey(17)
        case .previousTrack: mediaKey(18)
        case .volumeUp: mediaKey(0)
        case .volumeDown: mediaKey(1)
        case .mute: mediaKey(7)
        case .back: sendKey(UInt16(kVK_ANSI_LeftBracket), flags: .maskCommand)
        case .forward: sendKey(UInt16(kVK_ANSI_RightBracket), flags: .maskCommand)
        case .openApp(let path):
            guard !path.isEmpty else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case .openURL(let s):
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .shell(let command):
            guard !command.isEmpty else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            try? p.run()
        case .doNothing: break
        }
    }

    private static func cgFlags(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if f.contains(.command) { out.insert(.maskCommand) }
        if f.contains(.option) { out.insert(.maskAlternate) }
        if f.contains(.shift) { out.insert(.maskShift) }
        if f.contains(.control) { out.insert(.maskControl) }
        return out
    }

    static func sendKey(_ code: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Media keys are "system defined" events (NX_KEYTYPE_*).
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func missionControl(_ argument: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        if let argument { p.arguments = [argument] }
        try? p.run()
    }

    private static func openSystemApp(_ path: String, fallback: String) {
        let url = FileManager.default.fileExists(atPath: path) ? path : fallback
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: url), configuration: .init())
    }
}
