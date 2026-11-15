import AppKit
import HIDPP

/// `MXControl --backlight-always-on on|off`: same as the Keyboard tab toggle, for scripts.
@MainActor
enum BacklightAlwaysOnCommand {
    static func run(_ on: Bool) {
        let store = DeviceStore.shared
        store.start()
        Task { @MainActor in
            for _ in 0..<40 {
                if let kb = store.devices.first(where: { $0.loaded && $0.device.has(.backlight2) }), kb.state.backlight != nil {
                    await kb.setBacklightAlwaysOn(on)
                    if let b = try? await kb.device.backlight() {
                        print("\(kb.name): always on \(kb.backlightAlwaysOn), backlight \(b.enabled ? "on" : "off"), timers \(b.handsOutSeconds)/\(b.handsInSeconds)/\(b.poweredSeconds)s")
                    }
                    if let e = kb.lastError { print("error: \(e)"); exit(1) }
                    exit(0)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            print("No backlit keyboard found (asleep?)")
            exit(1)
        }
        NSApplication.shared.run()
    }
}
