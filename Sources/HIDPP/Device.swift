import Foundation

/// HID++ 2.0 feature IDs used by the app.
public enum Feature: UInt16, CaseIterable {
    case root = 0x0000
    case featureSet = 0x0001
    case firmware = 0x0003
    case deviceName = 0x0005
    case friendlyName = 0x0007
    case resetFactory = 0x0020
    case unifiedBattery = 0x1004
    case batteryStatus = 0x1000
    case changeHost = 0x1814
    case hostsInfo = 0x1815
    case backlight2 = 0x1982
    case reprogControls = 0x1B04
    case wirelessStatus = 0x1D4B
    case adjustableDPI = 0x2201
    case smartShift = 0x2110
    case smartShiftEnhanced = 0x2111
    case hiResWheel = 0x2121
    case thumbwheel = 0x2150
    case fnInversion = 0x40A0
    case newFnInversion = 0x40A2
    case k375FnInversion = 0x40A3
    case multiPlatform = 0x4531
}

/// Readable names for feature IDs in the dump.
public let featureNames: [UInt16: String] = [
    0x0000: "Root", 0x0001: "FeatureSet", 0x0002: "FeatureInfo", 0x0003: "DeviceFwVersion",
    0x0004: "DeviceUnitId", 0x0005: "DeviceName", 0x0007: "DeviceFriendlyName", 0x0008: "KeepAlive",
    0x0020: "ConfigChange", 0x0021: "CryptoId", 0x00C2: "DfuControlSigned", 0x00C3: "DfuControlSecure",
    0x00D0: "Dfu", 0x1000: "BatteryStatus", 0x1004: "UnifiedBattery", 0x1010: "ChargingControl",
    0x1300: "LedControl", 0x1500: "ForcePairing", 0x1602: "PasswordAuth", 0x1802: "DeviceReset",
    0x1803: "GpioAccess", 0x1805: "OOBState", 0x1806: "ConfigDeviceProps", 0x1811: "ColorLedEffects",
    0x1814: "ChangeHost", 0x1815: "HostsInfo", 0x1830: "PowerModes", 0x1890: "RfTest", 0x1891: "RfTestBle",
    0x18A1: "LedTest", 0x1981: "Backlight", 0x1982: "Backlight2", 0x1983: "Backlight3", 0x1990: "Illumination",
    0x1A20: "AmbientLightSensor", 0x1B00: "ReprogControls", 0x1B04: "ReprogControlsV4", 0x1BC0: "ReportHidUsage",
    0x1C00: "PersistentRemappableAction", 0x1D4B: "WirelessDeviceStatus", 0x1DF0: "RemainingPairing",
    0x1E00: "EnableHiddenFeatures", 0x1E02: "ManageDeactivatableFeatures", 0x1E22: "SPIDirectAccess",
    0x1EB0: "TdeAccess", 0x1F1F: "FirmwareProperties", 0x1F20: "ADCMeasurement", 0x2005: "ButtonSwapCancel",
    0x2006: "PointerAxisOrientation", 0x2100: "VerticalScrolling", 0x2110: "SmartShift", 0x2111: "SmartShiftEnhanced",
    0x2120: "HiResScrolling", 0x2121: "HiResWheel", 0x2130: "LowResWheel", 0x2150: "Thumbwheel",
    0x2200: "MousePointer", 0x2201: "AdjustableDPI", 0x2202: "ExtendedAdjustableDPI", 0x2205: "PointerMotionScaling",
    0x2230: "SensorAngleSnapping", 0x2240: "SurfaceTuning", 0x2250: "XYStats", 0x2251: "WheelStats",
    0x40A0: "FnInversion", 0x40A2: "NewFnInversion", 0x40A3: "FnInversionWithDefault", 0x4100: "Encryption",
    0x4220: "LockKeyState", 0x4301: "SolarDashboard", 0x4520: "KeyboardLayout", 0x4521: "DisableKeys",
    0x4522: "DisableKeysByUsage", 0x4530: "DualPlatform", 0x4531: "MultiPlatform", 0x4540: "KeyboardInternationalLayouts",
    0x4600: "Crown", 0x6010: "TouchpadFwItems", 0x6100: "TouchpadRawXY", 0x8010: "GKey", 0x8020: "MKeys",
    0x8030: "MR", 0x8040: "BrightnessControl", 0x8060: "ReportRate", 0x8061: "ExtendedReportRate",
    0x8070: "ColorLedEffects", 0x8071: "RgbEffects", 0x8080: "PerKeyLighting", 0x8081: "PerKeyLightingV2",
    0x8100: "OnboardProfiles", 0x8110: "MouseButtonSpy", 0x8111: "LatencyMonitoring", 0x8300: "Sidetone",
    0x9001: "PowerOnOff", 0x9200: "Hidden",
]

public enum DeviceKind: UInt8 {
    case keyboard = 0, remote, numpad, mouse, trackpad, trackball, presenter, receiver, unknown = 0xFF

    public var label: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .remote: return "Remote"
        case .numpad: return "Numpad"
        case .mouse: return "Mouse"
        case .trackpad: return "Trackpad"
        case .trackball: return "Trackball"
        case .presenter: return "Presenter"
        case .receiver: return "Receiver"
        case .unknown: return "Device"
        }
    }
}

public struct FirmwareEntity: CustomStringConvertible {
    public var type: UInt8
    public var name: String
    public var version: String
    public var description: String { "\(Self.typeName(type)) \(name) \(version)" }
    static func typeName(_ t: UInt8) -> String {
        [0: "Main", 1: "Bootloader", 2: "Hardware", 3: "Touchpad", 4: "Optical sensor", 5: "Softdevice",
         6: "RF companion", 7: "Factory"][t] ?? "Other"
    }
}

/// A Logitech device reachable through a channel (a receiver slot, or a direct connection).
@MainActor
public final class LogiDevice: Identifiable {
    public let channel: HIDPPChannel
    public let index: UInt8
    public nonisolated let id: String

    public private(set) var protocolVersion = "?"
    public private(set) var name = "Logitech device"
    public private(set) var kind: DeviceKind = .unknown
    public private(set) var unitID: String?
    public private(set) var modelID: String?
    public private(set) var serial: String?
    public private(set) var firmware: [FirmwareEntity] = []
    /// Feature ID → feature index on this device.
    public private(set) var features: [UInt16: UInt8] = [:]
    /// Feature ID → version.
    public private(set) var featureVersions: [UInt16: UInt8] = [:]

    public init(channel: HIDPPChannel, index: UInt8) {
        self.channel = channel
        self.index = index
        id = "\(channel.serialNumber ?? String(channel.productID, radix: 16))#\(index)"
    }

    public func has(_ feature: Feature) -> Bool { features[feature.rawValue] != nil }

    public func featureIndex(_ feature: Feature) async throws -> UInt8 {
        if let i = features[feature.rawValue] { return i }
        let reply = try await channel.call(index: index, featureIndex: 0, function: 0, params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)])
        guard reply[0] != 0 || feature == .root else { throw HIDPPError.featureMissing(feature.rawValue) }
        features[feature.rawValue] = reply[0]
        return reply[0]
    }

    /// Calls a function of a feature and returns the reply parameters.
    @discardableResult
    public func call(_ feature: Feature, _ function: UInt8, _ params: [UInt8] = [], timeout: Double = 2.0) async throws -> [UInt8] {
        let fi = try await featureIndex(feature)
        return try await channel.call(index: index, featureIndex: fi, function: function, params: params, timeout: timeout)
    }

    /// Feature for an incoming event's feature index.
    public func feature(atIndex fi: UInt8) -> UInt16? {
        features.first(where: { $0.value == fi })?.key
    }

    /// Pings the device; succeeds only when it is awake and connected.
    public func ping(timeout: Double = 1.0) async throws {
        let reply = try await channel.call(index: index, featureIndex: 0, function: 1, params: [0, 0, 0xAA], timeout: timeout)
        protocolVersion = "\(reply[0]).\(reply[1])"
    }

    /// Reads name, type, firmware and the full feature table.
    public func load() async throws {
        try await ping()
        let count = try await channel.call(index: index, featureIndex: 0, function: 0, params: [0x00, 0x01])
        let fsIndex = count[0]
        features[0x0000] = 0
        if fsIndex != 0 {
            features[0x0001] = fsIndex
            let n = try await channel.call(index: index, featureIndex: fsIndex, function: 0)[0]
            for i in 1...max(Int(n), 1) where n > 0 {
                let r = try await channel.call(index: index, featureIndex: fsIndex, function: 1, params: [UInt8(i)])
                let fid = UInt16(r[0]) << 8 | UInt16(r[1])
                features[fid] = UInt8(i)
                featureVersions[fid] = r[3]
            }
        }
        if has(.deviceName) {
            let length = Int(try await call(.deviceName, 0)[0])
            var bytes: [UInt8] = []
            while bytes.count < length {
                let chunk = try await call(.deviceName, 1, [UInt8(bytes.count)])
                bytes += chunk.prefix(length - bytes.count)
            }
            name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            if let t = try? await call(.deviceName, 2) { kind = DeviceKind(rawValue: t[0]) ?? .unknown }
        }
        if has(.firmware) {
            let info = try await call(.firmware, 0)
            unitID = info[1...4].map { String(format: "%02X", $0) }.joined()
            modelID = info[7...12].map { String(format: "%02X", $0) }.joined()
            var entities: [FirmwareEntity] = []
            for e in 0..<info[0] {
                let f = try await call(.firmware, 1, [e])
                let prefix = String(decoding: f[1...3].filter { $0 != 0 }, as: UTF8.self)
                let version = String(format: "%02X.%02X.B%04X", f[4], f[5], UInt16(f[6]) << 8 | UInt16(f[7]))
                entities.append(FirmwareEntity(type: f[0] & 0x0F, name: prefix, version: version))
            }
            firmware = entities
            if (featureVersions[0x0003] ?? 0) >= 4, let s = try? await call(.firmware, 2) {
                let text = String(decoding: s.prefix(12).filter { $0 != 0 }, as: UTF8.self)
                if !text.isEmpty { serial = text }
            }
        }
    }
}
