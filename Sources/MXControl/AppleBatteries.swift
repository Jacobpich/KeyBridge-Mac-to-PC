import Combine
import Foundation
import IOKit
import SwiftUI

/// Battery levels of Apple accessories (Magic Trackpad, Magic Mouse, Magic Keyboard), which
/// macOS publishes in the I/O Registry as `BatteryPercent` on each device's HID service.
struct AppleAccessory: Identifiable, Equatable {
    let id: String
    let name: String
    let percent: Int
    let charging: Bool
    let wired: Bool

    var isTrackpad: Bool { name.lowercased().contains("trackpad") }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("trackpad") { return "rectangle" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("keyboard") { return "keyboard" }
        return "dot.radiowaves.left.and.right"
    }

    /// Sort order in the label: keyboards, then mice, then trackpads.
    var sortKey: Int {
        let n = name.lowercased()
        return n.contains("keyboard") ? 0 : n.contains("mouse") ? 1 : 2
    }
}

@MainActor
final class AppleBatteryMonitor: ObservableObject {
    @Published private(set) var accessories: [AppleAccessory] = []

    private var timer: Timer?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        refresh()
        // Battery levels change slowly; a connect or disconnect is picked up right away below.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watchConnections()
    }

    func refresh() {
        let found = Self.read()
        if found != accessories { accessories = found }
    }

    nonisolated static func read() -> [AppleAccessory] {
        guard let match = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [AppleAccessory] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = prop("BatteryPercent") as? Int, let name = prop("Product") as? String else { continue }
            let flags = prop("BatteryStatusFlags") as? Int ?? 0
            let id = (prop("SerialNumber") as? String) ?? (prop("DeviceAddress") as? String) ?? name
            guard !result.contains(where: { $0.id == id }) else { continue }
            result.append(AppleAccessory(id: id, name: name, percent: percent,
                                         charging: flags & 0x3 != 0,
                                         wired: (prop("Transport") as? String) == "USB"))
        }
        return result.sorted { ($0.sortKey, $0.name) < ($1.sortKey, $1.name) }
    }

    /// Re-reads whenever an Apple accessory connects or disconnects.
    private func watchConnections() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let context else { return }
            let monitor = Unmanaged<AppleBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // The battery level is published a moment after the device appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { monitor.refresh() } }
            DispatchQueue.main.async { MainActor.assumeIsolated { monitor.refresh() } }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard let match = IOServiceMatching("AppleDeviceManagementHIDEventService"),
                  IOServiceAddMatchingNotification(port, type, match, callback, context, &iterator) == KERN_SUCCESS
            else { continue }
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }  // arm it
            iterators.append(iterator)
        }
    }
}

/// The accessory's icon. There's no SF Symbol for a plain trackpad, so it's drawn: a rounded
/// rectangle sized to sit with the keyboard and mouse symbols.
struct AccessoryIcon: View {
    let accessory: AppleAccessory

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
