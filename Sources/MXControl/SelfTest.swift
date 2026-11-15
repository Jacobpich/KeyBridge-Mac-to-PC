import AppKit
import HIDPP

/// `MXControl --write-test`: changes DPI, backlight level and SmartShift threshold, reads each
/// back, then restores the original values. Proves writes work on the real hardware.
@MainActor
enum WriteTest {
    static func run() {
        let manager = HIDPPManager()
        manager.start()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            var ok = true
            func check(_ c: Bool, _ label: String) { print(c ? "PASS" : "FAIL", label); ok = ok && c }
            for channel in manager.channels where channel.isReceiver {
                for slot in UInt8(1)...6 {
                    let d = LogiDevice(channel: channel, index: slot)
                    guard (try? await d.load()) != nil else { continue }
                    print("== \(d.name)")
                    do {
                        if d.has(.adjustableDPI) {
                            let before = try await d.dpi().current
                            let test = before == 1200 ? 1250 : 1200
                            try await d.setDPI(test)
                            check(try await d.dpi().current == test, "DPI \(before) → \(test)")
                            try await d.setDPI(before)
                            check(try await d.dpi().current == before, "DPI restored to \(before)")
                        }
                        if d.has(.smartShift) || d.has(.smartShiftEnhanced) {
                            let before = try await d.smartShift()
                            let test = before.threshold == 20 ? 25 : 20
                            try await d.setSmartShift(mode: nil, threshold: test)
                            check(try await d.smartShift().threshold == test, "SmartShift threshold \(before.threshold) → \(test)")
                            try await d.setSmartShift(mode: before.mode, threshold: before.threshold)
                            check(try await d.smartShift() == before, "SmartShift restored")
                        }
                        if d.has(.backlight2) {
                            let before = try await d.backlight()
                            if before.mode == .manual, before.levelCount > 1 {
                                var t = before
                                t.level = before.level == 3 ? 4 : 3
                                try await d.setBacklight(t)
                                check(try await d.backlight().level == t.level, "Backlight level \(before.level) → \(t.level)")
                                try await d.setBacklight(before)
                                check(try await d.backlight().level == before.level, "Backlight restored to \(before.level)")
                            } else {
                                print("SKIP backlight (not in manual mode)")
                            }
                        }
                        if d.has(.reprogControls), let c = try await d.controls().first(where: { $0.cid == 0x53 || $0.cid == 0xE3 }) {
                            try await d.divert(c.cid, true)
                            try await d.divert(c.cid, false)
                            check(true, "divert/undivert \(c.name)")
                        }
                    } catch {
                        check(false, "\(error)")
                    }
                }
            }
            print(ok ? "WRITE TEST PASSED" : "WRITE TEST FAILED")
            exit(ok ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}
