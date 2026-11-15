import Foundation

/// A mapping for one control. Controls that send pointer movement can also map gestures.
struct ControlMapping: Codable, Equatable {
    var action: ButtonAction?
    /// Only used when `useGestures` is on (gesture button and similar).
    var gestures: [GestureDirection: ButtonAction] = [:]
    var useGestures = false

    var isActive: Bool { useGestures ? !gestures.isEmpty : action != nil }
}

/// Button mappings for one device: a global set plus per-app overrides.
struct DeviceProfiles: Codable, Equatable {
    /// CID (hex string) → mapping.
    var global: [String: ControlMapping] = [:]
    /// Bundle ID → (CID → mapping). An app entry overrides the global one for that control.
    var perApp: [String: [String: ControlMapping]] = [:]

    /// The mappings in effect while `bundleID` is in front.
    func effective(for bundleID: String?) -> [UInt16: ControlMapping] {
        var out: [UInt16: ControlMapping] = [:]
        for (k, v) in global where v.isActive { if let cid = UInt16(k, radix: 16) { out[cid] = v } }
        if let bundleID, let app = perApp[bundleID] {
            for (k, v) in app { if let cid = UInt16(k, radix: 16) { out[cid] = v.isActive ? v : nil } }
        }
        return out
    }
}

/// Hardware settings the user changed, re-applied whenever the device reconnects.
struct SavedSettings: Codable, Equatable {
    var dpi: Int?
    var smartShiftMode: UInt8?
    var smartShiftThreshold: Int?
    var wheelHiRes: Bool?
    var wheelInverted: Bool?
    var thumbInverted: Bool?
    var backlightEnabled: Bool?
    var backlightMode: UInt8?
    var backlightLevel: UInt8?
    var backlightHandsOut: Int?
    var backlightHandsIn: Int?
    var backlightPowered: Int?
    /// Keep the backlight on whenever the keyboard is awake.
    var backlightAlwaysOn: Bool?
    /// Timers to go back to when always-on is turned off: [hands out, hands in, powered].
    var backlightTimeoutsBeforeAlwaysOn: [Int]?
    var fnKeys: Bool?
}

struct DeviceConfig: Codable, Equatable {
    var settings = SavedSettings()
    var profiles = DeviceProfiles()
}

/// Stores everything in ~/Library/Application Support/Keybridge/config.json, keyed by device unit ID.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()
    private(set) var devices: [String: DeviceConfig] = [:]
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keybridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: DeviceConfig].self, from: data) {
            devices = decoded
        }
    }

    func config(for key: String) -> DeviceConfig { devices[key] ?? DeviceConfig() }

    func update(_ key: String, _ change: (inout DeviceConfig) -> Void) {
        var c = config(for: key)
        change(&c)
        devices[key] = c
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(devices) { try? data.write(to: url, options: .atomic) }
    }
}
