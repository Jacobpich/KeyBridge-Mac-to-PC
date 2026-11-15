import AppKit

/// When the PC's monitor is also plugged into the Mac, it shows the PC while linked, so Mac
/// windows there would be invisible. Every few seconds this moves any Mac window that is mostly on that screen back to
/// the Mac screen next to it. Uses Accessibility.
@MainActor
final class WindowGuard {
    /// The PC's monitor, as one of the Mac's screens (null when it isn't plugged into the Mac).
    var pcScreen: CGRect = .null
    /// Where windows go: the Mac screen next to the PC.
    var macScreen: CGRect = .null
    private var timer: Timer?
    private var busy = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        sweep()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sweep() {
        guard !busy, !pcScreen.isNull, !macScreen.isNull, AXIsProcessTrusted() else { return }
        let target = macScreen
        busy = true
        let pc = pcScreen
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map(\.processIdentifier)
        DispatchQueue.global(qos: .utility).async {
            for pid in pids { Self.rescue(pid: pid, pc: pc, target: target) }
            DispatchQueue.main.async { self.busy = false }
        }
    }

    nonisolated private static func rescue(pid: pid_t, pc: CGRect, target: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            guard let frame = frame(w), frame.width > 40, frame.height > 40,
                  !bool(w, kAXMinimizedAttribute), !bool(w, "AXFullScreen") else { continue }
            let overlap = frame.intersection(pc)
            guard !overlap.isNull, overlap.width * overlap.height > frame.width * frame.height / 2 else { continue }
            let top = target.minY + 32  // below the menu bar
            var size = frame.size
            size.width = min(size.width, target.width - 40)
            size.height = min(size.height, target.maxY - top - 20)
            let origin = CGPoint(x: max(target.minX + 20, target.maxX - size.width - 40),
                                 y: min(max(frame.minY, top), target.maxY - size.height - 20))
            if size != frame.size { set(w, kAXSizeAttribute, size) }
            set(w, kAXPositionAttribute, origin)
        }
    }

    nonisolated private static func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    nonisolated private static func bool(_ w: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, attr as CFString, &v) == .success && (v as? Bool) == true
    }

    nonisolated private static func set(_ w: AXUIElement, _ attr: String, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, attr as CFString, v) }
    }

    nonisolated private static func set(_ w: AXUIElement, _ attr: String, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, attr as CFString, v) }
    }
}
