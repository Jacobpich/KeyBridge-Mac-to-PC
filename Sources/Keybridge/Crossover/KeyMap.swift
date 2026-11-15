import Carbon.HIToolbox
import CoreGraphics

/// Mac key codes → Windows keys.
enum KeyMap {
    struct WinKey: Equatable { let scan: UInt16; let extended: Bool }

    /// How the Mac's modifier keys act on the PC.
    enum ModifierStyle: String, CaseIterable, Identifiable {
        case commandIsCtrl   // ⌘ → Ctrl, ⌥ → Alt, ⌃ → Windows key   (⌘C copies on the PC)
        case commandIsWin    // ⌘ → Windows key, ⌥ → Alt, ⌃ → Ctrl   (keys stay where they are)
        var id: String { rawValue }
        var label: String {
            switch self {
            case .commandIsCtrl: "⌘ acts as Ctrl  (⌘C / ⌘V copy and paste)"
            case .commandIsWin: "⌘ acts as the Windows key, ⌃ as Ctrl"
            }
        }
    }

    static let lCtrl = WinKey(scan: 0x1D, extended: false), rCtrl = WinKey(scan: 0x1D, extended: true)
    static let lAlt = WinKey(scan: 0x38, extended: false), rAlt = WinKey(scan: 0x38, extended: true)
    static let lWin = WinKey(scan: 0x5B, extended: true), rWin = WinKey(scan: 0x5C, extended: true)
    static let lShift = WinKey(scan: 0x2A, extended: false), rShift = WinKey(scan: 0x36, extended: false)
    static let capsLock = WinKey(scan: 0x3A, extended: false)
    static let tab = WinKey(scan: 0x0F, extended: false)
    static let letterD = WinKey(scan: 0x20, extended: false)

    /// Modifier keys: Mac key code → (Windows key for each style, device flag bit that says it's down).
    static func modifier(_ code: Int, style: ModifierStyle) -> (key: WinKey, deviceBit: UInt64)? {
        let ctrlIsCmd = style == .commandIsCtrl
        switch code {
        case kVK_Command: return (ctrlIsCmd ? lCtrl : lWin, 0x08)
        case kVK_RightCommand: return (ctrlIsCmd ? rCtrl : rWin, 0x10)
        case kVK_Control: return (ctrlIsCmd ? lWin : lCtrl, 0x01)
        case kVK_RightControl: return (ctrlIsCmd ? rWin : rCtrl, 0x2000)
        case kVK_Option: return (lAlt, 0x20)
        case kVK_RightOption: return (rAlt, 0x40)
        case kVK_Shift: return (lShift, 0x02)
        case kVK_RightShift: return (rShift, 0x04)
        default: return nil
        }
    }

    /// The Windows modifiers for a shortcut's flags (used for remapped buttons on the PC).
    static func modifiers(for flags: CGEventFlags, style: ModifierStyle) -> [WinKey] {
        var out: [WinKey] = []
        if flags.contains(.maskControl) { out.append(style == .commandIsCtrl ? lWin : lCtrl) }
        if flags.contains(.maskAlternate) { out.append(lAlt) }
        if flags.contains(.maskShift) { out.append(lShift) }
        if flags.contains(.maskCommand) { out.append(style == .commandIsCtrl ? lCtrl : lWin) }
        return out
    }

    /// Windows virtual keys for the Mac's volume keys (key codes 0x48–0x4A).
    static let volumeKeys: [Int: UInt16] = [kVK_VolumeUp: 0xAF, kVK_VolumeDown: 0xAE, kVK_Mute: 0xAD]

    /// Media keys arrive as NX_SYSDEFINED events: NX_KEYTYPE_* → Windows virtual key.
    static let mediaKeys: [Int: UInt16] = [
        0: 0xAF,   // sound up      → VK_VOLUME_UP
        1: 0xAE,   // sound down    → VK_VOLUME_DOWN
        7: 0xAD,   // mute          → VK_VOLUME_MUTE
        16: 0xB3,  // play          → VK_MEDIA_PLAY_PAUSE
        17: 0xB0,  // next          → VK_MEDIA_NEXT_TRACK
        18: 0xB1,  // previous      → VK_MEDIA_PREV_TRACK
        19: 0xB0,  // fast          → next
        20: 0xB1,  // rewind        → previous
    ]

    static func key(_ code: Int) -> WinKey? {
        if let s = plain[code] { return WinKey(scan: s, extended: false) }
        if let s = extended[code] { return WinKey(scan: s, extended: true) }
        return nil
    }

    private static let plain: [Int: UInt16] = [
        kVK_ANSI_A: 0x1E, kVK_ANSI_S: 0x1F, kVK_ANSI_D: 0x20, kVK_ANSI_F: 0x21, kVK_ANSI_H: 0x23,
        kVK_ANSI_G: 0x22, kVK_ANSI_Z: 0x2C, kVK_ANSI_X: 0x2D, kVK_ANSI_C: 0x2E, kVK_ANSI_V: 0x2F,
        kVK_ISO_Section: 0x56, kVK_ANSI_B: 0x30, kVK_ANSI_Q: 0x10, kVK_ANSI_W: 0x11, kVK_ANSI_E: 0x12,
        kVK_ANSI_R: 0x13, kVK_ANSI_Y: 0x15, kVK_ANSI_T: 0x14, kVK_ANSI_1: 0x02, kVK_ANSI_2: 0x03,
        kVK_ANSI_3: 0x04, kVK_ANSI_4: 0x05, kVK_ANSI_6: 0x07, kVK_ANSI_5: 0x06, kVK_ANSI_Equal: 0x0D,
        kVK_ANSI_9: 0x0A, kVK_ANSI_7: 0x08, kVK_ANSI_Minus: 0x0C, kVK_ANSI_8: 0x09, kVK_ANSI_0: 0x0B,
        kVK_ANSI_RightBracket: 0x1B, kVK_ANSI_O: 0x18, kVK_ANSI_U: 0x16, kVK_ANSI_LeftBracket: 0x1A,
        kVK_ANSI_I: 0x17, kVK_ANSI_P: 0x19, kVK_Return: 0x1C, kVK_ANSI_L: 0x26, kVK_ANSI_J: 0x24,
        kVK_ANSI_Quote: 0x28, kVK_ANSI_K: 0x25, kVK_ANSI_Semicolon: 0x27, kVK_ANSI_Backslash: 0x2B,
        kVK_ANSI_Comma: 0x33, kVK_ANSI_Slash: 0x35, kVK_ANSI_N: 0x31, kVK_ANSI_M: 0x32,
        kVK_ANSI_Period: 0x34, kVK_Tab: 0x0F, kVK_Space: 0x39, kVK_ANSI_Grave: 0x29, kVK_Delete: 0x0E,
        kVK_Escape: 0x01, kVK_CapsLock: 0x3A,
        kVK_F1: 0x3B, kVK_F2: 0x3C, kVK_F3: 0x3D, kVK_F4: 0x3E, kVK_F5: 0x3F, kVK_F6: 0x40,
        kVK_F7: 0x41, kVK_F8: 0x42, kVK_F9: 0x43, kVK_F10: 0x44, kVK_F11: 0x57, kVK_F12: 0x58,
        kVK_F13: 0x64, kVK_F14: 0x65, kVK_F15: 0x66, kVK_F16: 0x67, kVK_F17: 0x68, kVK_F18: 0x69,
        kVK_F19: 0x6A, kVK_F20: 0x6B,
        kVK_ANSI_KeypadDecimal: 0x53, kVK_ANSI_KeypadMultiply: 0x37, kVK_ANSI_KeypadPlus: 0x4E,
        kVK_ANSI_KeypadClear: 0x45, kVK_ANSI_KeypadMinus: 0x4A, kVK_ANSI_KeypadEquals: 0x59,
        kVK_ANSI_Keypad0: 0x52, kVK_ANSI_Keypad1: 0x4F, kVK_ANSI_Keypad2: 0x50, kVK_ANSI_Keypad3: 0x51,
        kVK_ANSI_Keypad4: 0x4B, kVK_ANSI_Keypad5: 0x4C, kVK_ANSI_Keypad6: 0x4D, kVK_ANSI_Keypad7: 0x47,
        kVK_ANSI_Keypad8: 0x48, kVK_ANSI_Keypad9: 0x49,
        kVK_JIS_Yen: 0x7D, kVK_JIS_Underscore: 0x73, kVK_JIS_KeypadComma: 0x7E, kVK_JIS_Kana: 0x70,
    ]

    private static let extended: [Int: UInt16] = [
        kVK_ANSI_KeypadDivide: 0x35, kVK_ANSI_KeypadEnter: 0x1C,
        kVK_Help: 0x52 /* Insert */, kVK_Home: 0x47, kVK_PageUp: 0x49, kVK_ForwardDelete: 0x53,
        kVK_End: 0x4F, kVK_PageDown: 0x51, kVK_LeftArrow: 0x4B, kVK_RightArrow: 0x4D,
        kVK_DownArrow: 0x50, kVK_UpArrow: 0x48,
        0x6E: 0x5D, // context menu key on PC-layout keyboards
    ]
}
