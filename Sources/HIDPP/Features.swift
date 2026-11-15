import Foundation

// Typed access to the HID++ 2.0 features MX Control uses.
// Layouts follow the public HID++ 2.0 feature specs (as also implemented by Solaar).

// MARK: Battery (0x1004 Unified Battery, 0x1000 Battery Status fallback)

public struct BatteryInfo: Equatable {
    public enum Charging: UInt8 { case discharging = 0, charging, chargingSlow, full, error }
    public var percent: Int?
    public var level: String
    public var charging: Charging
    public var externalPower: Bool

    public var summary: String {
        let pct = percent.map { "\($0)%" } ?? level
        switch charging {
        case .discharging: return pct
        case .charging, .chargingSlow: return "\(pct), charging"
        case .full: return "\(pct), fully charged"
        case .error: return "\(pct), charging error"
        }
    }

    static func levelName(_ bits: UInt8) -> String {
        if bits & 0x08 != 0 { return "Full" }
        if bits & 0x04 != 0 { return "Good" }
        if bits & 0x02 != 0 { return "Low" }
        if bits & 0x01 != 0 { return "Critical" }
        return "Unknown"
    }

    /// Parses a getStatus reply or a battery event (same layout).
    public static func unified(_ r: [UInt8]) -> BatteryInfo {
        BatteryInfo(percent: r[0] > 0 ? Int(r[0]) : nil, level: levelName(r[1]),
                    charging: Charging(rawValue: r[2]) ?? .error, externalPower: r[3] != 0)
    }

    public static func legacy(_ r: [UInt8]) -> BatteryInfo {
        let charging: Charging = switch r[2] { case 1, 2: .charging; case 3: .full; case 0: .discharging; default: .error }
        return BatteryInfo(percent: r[0] > 0 ? Int(r[0]) : nil, level: r[0] > 20 ? "Good" : "Low",
                           charging: charging, externalPower: r[2] != 0)
    }
}

extension LogiDevice {
    public func battery() async throws -> BatteryInfo {
        if has(.unifiedBattery) { return .unified(try await call(.unifiedBattery, 1)) }
        return .legacy(try await call(.batteryStatus, 0))
    }
}

// MARK: Backlight (0x1982 Backlight2)

public struct BacklightConfig: Equatable {
    public enum Mode: UInt8, CaseIterable, Identifiable {
        case basic = 0, automatic = 1, manual = 3
        public var id: UInt8 { rawValue }
        public var label: String {
            switch self { case .basic: "On"; case .automatic: "Automatic (ambient light)"; case .manual: "Manual level" }
        }
    }

    public var enabled: Bool
    public var options: UInt8
    public var supported: UInt8
    public var effects: UInt16
    public var level: UInt8
    /// Seconds before the backlight turns off after your hands leave the keyboard.
    public var handsOutSeconds: Int
    /// Seconds it stays on while your hands are near the keyboard.
    public var handsInSeconds: Int
    /// Seconds it stays on while the keyboard is charging / on power.
    public var poweredSeconds: Int
    /// Number of manual levels (from getBacklightInfo).
    public var levelCount: Int

    public var mode: Mode {
        get { Mode(rawValue: (options >> 3) & 0x03) ?? .basic }
        set { options = (options & 0x07) | (newValue.rawValue << 3) }
    }
    public var supportsAuto: Bool { supported & 0x08 != 0 }

    /// The longest timeout the firmware accepts (MX Keys S rejects anything above 2 hours).
    public static let maxTimeoutSeconds = 7200

    /// All three timers at their maximum.
    public var isMaxTimeouts: Bool {
        handsOutSeconds >= Self.maxTimeoutSeconds && handsInSeconds >= Self.maxTimeoutSeconds
            && poweredSeconds >= Self.maxTimeoutSeconds
    }
}

extension LogiDevice {
    public func backlight() async throws -> BacklightConfig {
        let r = try await call(.backlight2, 0)
        func u16(_ i: Int) -> Int { Int(r[i]) | Int(r[i + 1]) << 8 }   // little-endian
        var levels = 0
        if let info = try? await call(.backlight2, 2) { levels = Int(info[0]) }
        return BacklightConfig(enabled: r[0] != 0, options: r[1], supported: r[2],
                               effects: UInt16(r[3]) | UInt16(r[4]) << 8, level: r[5],
                               handsOutSeconds: u16(6) * 5, handsInSeconds: u16(8) * 5,
                               poweredSeconds: u16(10) * 5, levelCount: levels)
    }

    public func setBacklight(_ c: BacklightConfig) async throws {
        func le(_ seconds: Int) -> [UInt8] {
            let v = UInt16(clamping: max(1, seconds / 5))
            return [UInt8(v & 0xFF), UInt8(v >> 8)]
        }
        let level: UInt8 = c.mode == .manual ? c.level : 0
        let params: [UInt8] = [c.enabled ? 1 : 0, c.options, 0xFF, level]
            + le(c.handsOutSeconds) + le(c.handsInSeconds) + le(c.poweredSeconds)
        try await call(.backlight2, 1, params)
    }
}

// MARK: Easy-Switch (0x1814 Change Host, 0x1815 Hosts Info)

public struct HostSlot: Identifiable, Equatable {
    public var id: Int { index }
    public var index: Int
    public var paired: Bool
    public var busType: UInt8
    public var name: String

    public var busLabel: String {
        switch busType {
        case 0: return "—"
        case 1: return "Unifying"
        case 2: return "USB"
        case 3: return "Lightspeed"
        case 4: return "Bluetooth"
        case 5: return "Logi Bolt"
        default: return "Bus \(busType)"
        }
    }
}

public struct HostInfo: Equatable {
    public var count: Int
    public var current: Int
    public var slots: [HostSlot]
}

extension LogiDevice {
    public func hosts() async throws -> HostInfo {
        let ch = try await call(.changeHost, 0)
        var info = HostInfo(count: Int(ch[0]), current: Int(ch[1]), slots: [])
        guard has(.hostsInfo) else {
            info.slots = (0..<info.count).map { HostSlot(index: $0, paired: true, busType: 0, name: "") }
            return info
        }
        let caps = try await call(.hostsInfo, 0)
        for host in 0..<info.count {
            guard let h = try? await call(.hostsInfo, 1, [UInt8(host)]) else { continue }
            var slot = HostSlot(index: host, paired: h[1] != 0, busType: h[2], name: "")
            let nameLength = Int(h[4])
            if caps[0] & 0x01 != 0, nameLength > 0 {
                var bytes: [UInt8] = []
                while bytes.count < nameLength {
                    guard let piece = try? await call(.hostsInfo, 3, [UInt8(host), UInt8(bytes.count)]) else { break }
                    bytes += piece.dropFirst(2).prefix(min(14, nameLength - bytes.count))
                }
                slot.name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            info.slots.append(slot)
        }
        return info
    }

    /// Switches the device to another computer. It disconnects from this one immediately.
    public func switchHost(to host: Int) async throws {
        // No reply is expected: the device leaves right away.
        _ = try? await call(.changeHost, 1, [UInt8(host)], timeout: 0.5)
    }
}

// MARK: Pointer speed (0x2201 Adjustable DPI)

public struct DPIInfo: Equatable {
    public var current: Int
    public var defaultDPI: Int
    public var choices: [Int]
    public var range: ClosedRange<Int> { (choices.first ?? 400)...(choices.last ?? 4000) }
}

extension LogiDevice {
    public func dpi() async throws -> DPIInfo {
        var values: [Int] = []
        var offset: UInt8 = 0
        // The list arrives in pages; 0 ends it; 0xE0xx means "step between neighbours".
        list: for _ in 0..<8 {
            let r = try await call(.adjustableDPI, 1, [0, offset])
            var i = 1
            while i + 1 < r.count {
                let v = Int(r[i]) << 8 | Int(r[i + 1])
                i += 2
                if v == 0 { break list }
                values.append(v)
            }
            offset += 1
        }
        var choices: [Int] = []
        var k = 0
        while k < values.count {
            let v = values[k]
            if v >= 0xE000, let low = choices.last, k + 1 < values.count {
                let step = v & 0x1FFF, high = values[k + 1]
                var x = low + step
                while x < high { choices.append(x); x += step }
            } else {
                choices.append(v)
            }
            k += 1
        }
        let cur = try await call(.adjustableDPI, 2, [0])
        let current = Int(cur[1]) << 8 | Int(cur[2])
        let def = Int(cur[3]) << 8 | Int(cur[4])
        return DPIInfo(current: current, defaultDPI: def == 0 ? current : def, choices: choices)
    }

    public func setDPI(_ dpi: Int) async throws {
        try await call(.adjustableDPI, 3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
    }
}

// MARK: Scroll wheel (0x2110 / 0x2111 SmartShift, 0x2121 Hi-res wheel, 0x2150 Thumbwheel)

public struct SmartShiftConfig: Equatable {
    public enum WheelMode: UInt8 { case freeSpin = 1, ratchet = 2 }
    public var mode: WheelMode
    /// How hard you have to flick the wheel before it switches to free spin (1–50); 0xFF = never.
    public var threshold: Int
    public var torque: Int?
    public var supportsTorque: Bool
}

public struct WheelConfig: Equatable {
    public var hiRes: Bool
    public var inverted: Bool
    public var diverted: Bool
    public var multiplier: Int
    public var hasInvert: Bool
}

public struct ThumbwheelConfig: Equatable {
    public var diverted: Bool
    public var inverted: Bool
}

extension LogiDevice {
    private var enhancedShift: Bool { has(.smartShiftEnhanced) }

    public func smartShift() async throws -> SmartShiftConfig {
        if enhancedShift {
            let caps = try await call(.smartShiftEnhanced, 0)
            let r = try await call(.smartShiftEnhanced, 1)
            let torque = caps[0] & 0x01 != 0
            return SmartShiftConfig(mode: .init(rawValue: r[0]) ?? .ratchet, threshold: Int(r[1]),
                                    torque: torque ? Int(r[2]) : nil, supportsTorque: torque)
        }
        let r = try await call(.smartShift, 0)
        return SmartShiftConfig(mode: .init(rawValue: r[0]) ?? .ratchet, threshold: Int(r[1]), torque: nil, supportsTorque: false)
    }

    /// 0 in any field means "leave unchanged".
    public func setSmartShift(mode: SmartShiftConfig.WheelMode?, threshold: Int?, torque: Int? = nil) async throws {
        let params: [UInt8] = [mode?.rawValue ?? 0, UInt8(clamping: threshold ?? 0), UInt8(clamping: torque ?? 0)]
        if enhancedShift { try await call(.smartShiftEnhanced, 2, params) } else { try await call(.smartShift, 1, Array(params.prefix(2))) }
    }

    public func wheel() async throws -> WheelConfig {
        let caps = try await call(.hiResWheel, 0)
        let m = try await call(.hiResWheel, 1)[0]
        return WheelConfig(hiRes: m & 0x02 != 0, inverted: m & 0x04 != 0, diverted: m & 0x01 != 0,
                           multiplier: Int(caps[0]), hasInvert: caps[1] & 0x08 != 0)
    }

    public func setWheel(_ w: WheelConfig) async throws {
        let m: UInt8 = (w.diverted ? 0x01 : 0) | (w.hiRes ? 0x02 : 0) | (w.inverted ? 0x04 : 0)
        try await call(.hiResWheel, 2, [m])
    }

    public func thumbwheel() async throws -> ThumbwheelConfig {
        let r = try await call(.thumbwheel, 1)
        return ThumbwheelConfig(diverted: r[0] & 0x01 != 0, inverted: r[1] & 0x01 != 0)
    }

    public func setThumbwheel(_ t: ThumbwheelConfig) async throws {
        try await call(.thumbwheel, 2, [t.diverted ? 1 : 0, t.inverted ? 1 : 0])
    }
}

// MARK: Fn keys (0x40A0 / 0x40A2 / 0x40A3 Fn inversion)

extension LogiDevice {
    /// True when the top row sends F1–F12 without holding Fn.
    public func fnKeysAsFunctionKeys() async throws -> Bool? {
        if has(.k375FnInversion) { return try await call(.k375FnInversion, 0)[1] & 0x01 != 0 }
        if has(.newFnInversion) { return try await call(.newFnInversion, 0)[0] & 0x01 != 0 }
        if has(.fnInversion) { return try await call(.fnInversion, 0)[0] & 0x01 != 0 }
        return nil
    }

    public func setFnKeysAsFunctionKeys(_ on: Bool) async throws {
        if has(.k375FnInversion) { try await call(.k375FnInversion, 1, [0xFF, on ? 1 : 0]) }
        else if has(.newFnInversion) { try await call(.newFnInversion, 1, [on ? 1 : 0]) }
        else if has(.fnInversion) { try await call(.fnInversion, 1, [on ? 1 : 0]) }
    }
}

// MARK: Buttons and keys (0x1B04 Reprogrammable Controls V4)

public struct ControlInfo: Identifiable, Equatable {
    public var id: UInt16 { cid }
    public var cid: UInt16
    public var taskID: UInt16
    public var flags: UInt16
    public var position: UInt8
    public var group: UInt8

    public var isMouseButton: Bool { flags & 0x01 != 0 }
    public var isFKey: Bool { flags & 0x02 != 0 }
    public var isDivertable: Bool { flags & 0x20 != 0 }
    public var supportsRawXY: Bool { flags & 0x100 != 0 }

    public var name: String {
        let base = controlNames[cid]
        if isFKey, position > 0 { return base.map { "F\(position) · \($0)" } ?? "F\(position)" }
        return base ?? String(format: "Key 0x%04X", cid)
    }
}

/// Names for common control IDs.
public let controlNames: [UInt16: String] = [
    0x0001: "Volume Up", 0x0002: "Volume Down", 0x0003: "Mute", 0x0004: "Play/Pause", 0x0005: "Next Track",
    0x0006: "Previous Track", 0x0007: "Stop", 0x0008: "App Switcher", 0x000A: "Calculator", 0x000E: "Mail",
    0x0012: "Search", 0x0050: "Left Click", 0x0051: "Right Click", 0x0052: "Middle Button", 0x0053: "Back Button",
    0x0056: "Forward Button", 0x005B: "Scroll Left", 0x005D: "Scroll Right", 0x00C3: "Gesture Button",
    0x00C4: "SmartShift Button", 0x00C7: "Brightness Down", 0x00C8: "Brightness Up", 0x00D7: "Virtual Gesture",
    0x00E0: "Show Desktop", 0x00E1: "Lock Screen", 0x00E2: "Screen Capture", 0x00E3: "Mission Control",
    0x00E4: "Launchpad", 0x00E5: "Dictation", 0x00E6: "Emoji", 0x00E7: "Mute Microphone",
    0x00E8: "Backlight Down", 0x00E9: "Backlight Up", 0x00EA: "Do Not Disturb",
]

extension LogiDevice {
    public func controls() async throws -> [ControlInfo] {
        let count = try await call(.reprogControls, 0)[0]
        var out: [ControlInfo] = []
        for i in 0..<count {
            let r = try await call(.reprogControls, 1, [i])
            out.append(ControlInfo(cid: UInt16(r[0]) << 8 | UInt16(r[1]), taskID: UInt16(r[2]) << 8 | UInt16(r[3]),
                                   flags: UInt16(r[4]) | UInt16(r[8]) << 8, position: r[5], group: r[6]))
        }
        return out
    }

    /// Diverts a control so presses come to the app instead of doing their normal job.
    /// `rawXY` also sends pointer movement while the control is held (for gestures).
    public func divert(_ cid: UInt16, _ on: Bool, rawXY: Bool = false) async throws {
        var flags: UInt8 = 0x02 | (on ? 0x01 : 0)        // divert + "divert valid"
        if rawXY || !on { flags |= 0x20 | (rawXY && on ? 0x10 : 0) }   // raw XY + "raw XY valid"
        try await call(.reprogControls, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0])
    }
}

// MARK: Snapshot

/// Everything MX Control shows for one device.
public struct DeviceState {
    public var battery: BatteryInfo?
    public var backlight: BacklightConfig?
    public var hosts: HostInfo?
    public var dpi: DPIInfo?
    public var smartShift: SmartShiftConfig?
    public var wheel: WheelConfig?
    public var thumbwheel: ThumbwheelConfig?
    public var fnKeys: Bool?
    public var controls: [ControlInfo] = []
    public var errors: [String] = []

    public init() {}

    @MainActor
    public static func read(_ d: LogiDevice) async -> DeviceState {
        var s = DeviceState()
        func attempt<T>(_ label: String, _ work: () async throws -> T) async -> T? {
            do { return try await work() } catch { s.errors.append("\(label): \(error)"); return nil }
        }
        if d.has(.unifiedBattery) || d.has(.batteryStatus) { s.battery = await attempt("battery") { try await d.battery() } }
        if d.has(.backlight2) { s.backlight = await attempt("backlight") { try await d.backlight() } }
        if d.has(.changeHost) { s.hosts = await attempt("easy-switch") { try await d.hosts() } }
        if d.has(.adjustableDPI) { s.dpi = await attempt("dpi") { try await d.dpi() } }
        if d.has(.smartShift) || d.has(.smartShiftEnhanced) { s.smartShift = await attempt("smartshift") { try await d.smartShift() } }
        if d.has(.hiResWheel) { s.wheel = await attempt("wheel") { try await d.wheel() } }
        if d.has(.thumbwheel) { s.thumbwheel = await attempt("thumbwheel") { try await d.thumbwheel() } }
        if d.has(.fnInversion) || d.has(.newFnInversion) || d.has(.k375FnInversion) {
            s.fnKeys = await attempt("fn keys") { try await d.fnKeysAsFunctionKeys() } ?? nil
        }
        if d.has(.reprogControls) { s.controls = await attempt("controls") { try await d.controls() } ?? [] }
        return s
    }

    public func printLines(indent: String) {
        if let b = battery { print(indent + "battery: \(b.summary) (level \(b.level), external power \(b.externalPower))") }
        if let b = backlight {
            print(indent + "backlight: \(b.enabled ? "on" : "off"), mode \(b.mode.label), level \(b.level)/\(max(b.levelCount - 1, 0)), off after \(b.handsOutSeconds)s hands-away / \(b.handsInSeconds)s hands-near / \(b.poweredSeconds)s powered, auto supported \(b.supportsAuto)")
        }
        if let h = hosts {
            print(indent + "easy-switch: channel \(h.current + 1) of \(h.count)")
            for slot in h.slots {
                print(indent + "  \(slot.index + 1): \(slot.paired ? "paired" : "empty") \(slot.busLabel) \(slot.name)")
            }
        }
        if let d = dpi { print(indent + "dpi: \(d.current) (default \(d.defaultDPI), range \(d.range), \(d.choices.count) steps)") }
        if let s = smartShift { print(indent + "smartshift: \(s.mode), threshold \(s.threshold), torque \(s.torque.map(String.init) ?? "-")") }
        if let w = wheel { print(indent + "wheel: hi-res \(w.hiRes), inverted \(w.inverted), diverted \(w.diverted), multiplier \(w.multiplier)") }
        if let t = thumbwheel { print(indent + "thumbwheel: inverted \(t.inverted), diverted \(t.diverted)") }
        if let f = fnKeys { print(indent + "top row sends F-keys by default: \(f)") }
        if !controls.isEmpty {
            print(indent + "controls: " + controls.map { "\($0.name)[\(String(format: "%04X", $0.cid))\($0.isDivertable ? "" : " fixed")]" }.joined(separator: ", "))
        }
        for e in errors { print(indent + "error — \(e)") }
    }
}
