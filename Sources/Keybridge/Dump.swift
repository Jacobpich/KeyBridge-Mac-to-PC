import AppKit
import HIDPP

/// `Keybridge --dump`: prints every Logitech endpoint, device, feature and current setting.
@MainActor
enum Dump {
    static func run() {
        let manager = HIDPPManager()
        manager.start()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if manager.channels.isEmpty {
                print("No Logitech HID++ endpoints found.")
                if let e = manager.lastOpenError { print("Open failed: IOReturn 0x\(String(UInt32(bitPattern: e), radix: 16)) — check Input Monitoring permission.") }
                exit(1)
            }
            for channel in manager.channels {
                print("== \(channel.productName) (PID 0x\(String(channel.productID, radix: 16)), \(channel.transport), serial \(channel.serialNumber ?? "-"))")
                if channel.isReceiver {
                    await dumpReceiver(channel)
                    for slot in UInt8(1)...6 { await dumpDevice(LogiDevice(channel: channel, index: slot)) }
                } else {
                    await dumpDevice(LogiDevice(channel: channel, index: 0xFF))
                }
            }
            exit(0)
        }
        NSApplication.shared.run()
    }

    static func dumpReceiver(_ channel: HIDPPChannel) async {
        do {
            let conn = try await channel.readRegister(0x02)
            print("  receiver: \(conn[1]) device(s) connected")
        } catch { print("  receiver register 0x02: \(error)") }
        for slot in UInt8(0)...5 {
            if let info = try? await channel.readRegister(0xB5, params: [0x50 + slot + 1], long: true) {
                let hex = info.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
                var name = ""
                if let n = try? await channel.readRegister(0xB5, params: [0x60 + slot + 1, 0x01], long: true) {
                    let len = Int(n[2])
                    name = String(decoding: n.dropFirst(3).prefix(len), as: UTF8.self)
                }
                print("  pairing slot \(slot + 1): \(hex) \(name)")
            }
        }
    }

    static func dumpDevice(_ device: LogiDevice) async {
        do {
            try await device.load()
        } catch {
            if device.index != 0xFF, case HIDPPError.hidpp10(let c) = error, c == 0x08 || c == 0x09 { return } // empty slot
            print("  [\(device.index)] \(error)")
            return
        }
        print("  [\(device.index)] \(device.name) — \(device.kind.label), HID++ \(device.protocolVersion)")
        print("      unit \(device.unitID ?? "-"), model \(device.modelID ?? "-"), serial \(device.serial ?? "-")")
        for f in device.firmware { print("      firmware: \(f)") }
        let sorted = device.features.sorted { $0.value < $1.value }
        print("      features: " + sorted.map { String(format: "%04X", $0.key) + "(\(featureNames[$0.key] ?? "?") v\(device.featureVersions[$0.key] ?? 0))" }.joined(separator: ", "))
        await DeviceState.read(device).printLines(indent: "      ")
    }
}
