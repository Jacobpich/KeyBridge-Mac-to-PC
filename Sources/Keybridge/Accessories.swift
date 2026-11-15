import Combine
import Foundation
import IOKit
import IOKit.hid
import SwiftUI

/// A keyboard, mouse or trackpad connected to this Mac, of any brand: its name, how it's
/// connected, and its battery when macOS knows it (Apple's accessories and many Bluetooth ones
/// publish `BatteryPercent` in the I/O Registry). Logitech devices get far more from HID++ in
/// `DeviceStore`; this covers everything.
struct Accessory: Identifiable, Equatable {
    enum Kind: Int { case keyboard, mouse, trackpad }

    let id: String
    let name: String
    let maker: String?
    let kind: Kind
    let transport: String
    let vendorID: Int
    let percent: Int?
    let charging: Bool

    var wired: Bool { transport == "USB" }
    var isTrackpad: Bool { kind == .trackpad }

    var symbol: String {
        switch kind {
        case .keyboard: "keyboard"
        case .mouse: vendorID == 0x004C ? "magicmouse" : "computermouse"
        case .trackpad: "rectangle"
        }
    }

    var kindLabel: String {
        switch kind {
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .trackpad: "Trackpad"
        }
    }

    var connectionLabel: String {
        switch transport {
        case "USB": "USB cable or receiver"
        case "Bluetooth Low Energy", "BluetoothLowEnergy": "Bluetooth LE"
        default: transport
        }
    }
}

@MainActor
final class AccessoryMonitor: ObservableObject {
    @Published private(set) var accessories: [Accessory] = []

    private var timer: Timer?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending = false

    func start() {
        refresh()
        // Battery levels change slowly; connects and disconnects are picked up right away below.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watchConnections()
    }

    func refresh() {
        let found = Self.read()
        if found != accessories { accessories = found }
    }

    nonisolated private static let transports: Set<String> = ["USB", "Bluetooth", "Bluetooth Low Energy", "BluetoothLowEnergy"]

    nonisolated static func read() -> [Accessory] {
        guard let match = IOServiceMatching(kIOHIDDeviceKey) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        struct Found { var name: String; var maker: String?; var kind: Accessory.Kind; var transport: String
                       var vendor: Int; var percent: Int?; var charging: Bool }
        var byID: [String: Found] = [:]
        var order: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            func search(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively))
            }
            guard (prop("Built-In") as? Bool) != true,
                  let transport = prop("Transport") as? String, transports.contains(transport),
                  let name = prop("Product") as? String, !name.isEmpty else { continue }
            let vendor = prop("VendorID") as? Int ?? 0
            let product = prop("ProductID") as? Int ?? 0
            // Logitech's receivers show up as a keyboard and a mouse; their devices are listed by DeviceStore.
            if vendor == 0x046D, name.lowercased().contains("receiver") { continue }
            let pairs = (prop("DeviceUsagePairs") as? [[String: Int]] ?? [])
                .map { ($0["DeviceUsagePage"] ?? 0, $0["DeviceUsage"] ?? 0) }
            let usages = pairs + [(prop("PrimaryUsagePage") as? Int ?? 0, prop("PrimaryUsage") as? Int ?? 0)]
            let kind: Accessory.Kind
            if name.lowercased().contains("trackpad") || usages.contains(where: { $0 == (0x0D, 0x05) }) { kind = .trackpad }
            else if usages.contains(where: { $0 == (0x01, 0x06) }) { kind = .keyboard }
            else if usages.contains(where: { $0 == (0x01, 0x02) }) { kind = .mouse }
            else { continue }
            let percent = search("BatteryPercent") as? Int
            let charging = (search("BatteryStatusFlags") as? Int ?? 0) & 0x3 != 0
            // One device shows up as several HID interfaces; they share a serial number or location.
            let unit = (prop("SerialNumber") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (prop("LocationID") as? Int).map(String.init) ?? name
            let id = "\(vendor)-\(product)-\(unit)"
            if var f = byID[id] {
                if kind.rawValue < f.kind.rawValue && f.kind != .trackpad { f.kind = kind }
                if f.percent == nil { f.percent = percent; f.charging = charging }
                byID[id] = f
            } else {
                byID[id] = Found(name: name, maker: prop("Manufacturer") as? String, kind: kind, transport: transport,
                                 vendor: vendor, percent: percent, charging: charging)
                order.append(id)
            }
        }
        return order.compactMap { id in
            byID[id].map { f in
                Accessory(id: id, name: f.name, maker: f.maker, kind: f.kind, transport: f.transport,
                          vendorID: f.vendor, percent: f.percent, charging: f.charging)
            }
        }
        .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    /// Re-reads whenever a keyboard or mouse connects or disconnects.
    private func watchConnections() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let context else { return }
            let monitor = Unmanaged<AccessoryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshSoon() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard let match = IOServiceMatching(kIOHIDDeviceKey),
                  IOServiceAddMatchingNotification(port, type, match, callback, context, &iterator) == KERN_SUCCESS
            else { continue }
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }  // arm it
            iterators.append(iterator)
        }
    }

    /// A device's interfaces arrive one by one and its battery level a moment later: read once
    /// things settle, and again a bit after.
    private func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.pending = false; self?.refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// The accessory's icon. There's no SF Symbol for a plain trackpad, so it's drawn: a rounded
/// rectangle sized to sit with the keyboard and mouse symbols.
struct AccessoryIcon: View {
    let accessory: Accessory

    var body: some View {
        if accessory.isTrackpad {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(lineWidth: 1.4)
                .frame(width: 17, height: 12)
        } else {
            Image(systemName: accessory.symbol)
        }
    }
}

/// A battery symbol for a percentage.
func batterySymbol(percent: Int, charging: Bool) -> String {
    charging ? "battery.100percent.bolt"
        : percent > 87 ? "battery.100percent" : percent > 62 ? "battery.75percent"
        : percent > 37 ? "battery.50percent" : percent > 12 ? "battery.25percent" : "battery.0percent"
}
