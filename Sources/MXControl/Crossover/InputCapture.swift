import AppKit
import Carbon.HIToolbox

/// Watches all mouse and keyboard input with an event tap. On the Mac it only looks for the
/// pointer entering the PC's screen; on the PC it swallows everything and sends it straight to
/// the PC.
///
/// The tap runs on its own high-priority thread. An active event tap holds up every input event
/// on the Mac until its callback returns, so it must never wait on the main thread (menu-bar
/// redraws, HID++ work, clipboard reads).
final class InputCapture: @unchecked Sendable {
    struct Config {
        /// The PC's screen, in global top-left (Quartz) coordinates.
        var pcScreen: CGRect = .null
        /// Pixels on the PC per point on the Mac, including the user's pointer speed.
        var pointerScale: CGFloat = 1
        var scrollSpeed: CGFloat = 1
        var style: KeyMap.ModifierStyle = .commandIsCtrl
    }

    /// After control comes back, the pointer can't cross to the PC again for this long, so a
    /// wobble at the edge doesn't bounce control back and forth.
    static let reentryDelay: TimeInterval = 0.2

    /// Called on the main thread after control moved to the PC (fraction of the PC screen).
    var onEntered: ((CGPoint) -> Void)?
    /// Called on the main thread after ⌃⌥⌘ Esc brought control back.
    var onEmergencyReturn: (() -> Void)?
    /// Main thread: the left button went down on the Mac (a drag may be starting).
    var onMouseDown: (() -> Void)?
    /// Main thread: something is being dragged into the PC's screen. Answer with
    /// `enterPCWithDrag()` (files: carry them across) or `dragCheckDone(crossed: false)`.
    var onDragAtEdge: (() -> Void)?

    /// Events MX Control posts itself carry this, so the tap lets them through.
    static let syntheticTag: Int64 = 0x4D58_4358

    // Everything below is guarded by `lock`: the tap thread and the main thread both use it.
    private let lock = NSLock()
    private var config = Config()
    private var macScreens: [CGRect] = []
    private weak var sink: CrossoverSession?
    private var _onPC = false
    private var parkedAt: CGPoint = .zero
    private var reentryAllowedAt: TimeInterval = 0
    private var cursorHidden = false
    private var dragCheckPending = false
    private var dragCheckFailed = false   // this drag isn't files: don't ask again until the button's up
    private var draggingFiles = false     // on the PC with a Mac file drag in hand
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    var onPC: Bool { locked { _onPC } }
    var isEnabled: Bool { locked { tap != nil } }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// New settings or screen layout (main thread).
    func update(_ change: (inout Config) -> Void) {
        let screens = Self.displayFrames()
        locked {
            change(&config)
            macScreens = screens.filter { $0 != config.pcScreen }
        }
    }

    /// Where input goes while on the PC: the trusted session, or nil when there's no link.
    func setSink(_ session: CrossoverSession?) { locked { sink = session } }

    /// Starts watching. Fails without Accessibility permission.
    @discardableResult
    func enable() -> Bool {
        if isEnabled { return true }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        for t in types { mask |= CGEventMask(1) << t.rawValue }
        mask |= CGEventMask(1) << 14 // NX_SYSDEFINED: media keys
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<InputCapture>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
        locked { self.tap = tap; self.source = source }

        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self?.locked { self?.runLoop = rl }
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "MX Control Crossover input"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        return true
    }

    func disable() {
        leavePC(at: nil)
        let (tap, source, rl) = locked { () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?) in
            defer { self.tap = nil; self.source = nil; self.runLoop = nil }
            return (self.tap, self.source, self.runLoop)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let rl {
            if let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
            CFRunLoopStop(rl)
        }
    }

    /// Puts the pointer back on the Mac. `y` is the fraction of the PC screen's height where it
    /// left. Returns whether control was on the PC.
    @discardableResult
    func leavePC(at y: CGFloat?) -> Bool { locked { leaveLocked(at: y) } }

    private func leaveLocked(at y: CGFloat?) -> Bool {
        guard _onPC else { return false }
        _onPC = false
        draggingFiles = false
        reentryAllowedAt = ProcessInfo.processInfo.systemUptime + Self.reentryDelay
        var point = parkedAt
        let pc = config.pcScreen
        if let y, !pc.isNull {
            point.y = pc.minY + y * pc.height
            // Keep it on the Mac screen next to the PC's.
            if let mac = nearestMacScreen(to: point) {
                point.y = min(max(point.y, mac.minY + 1), mac.maxY - 2)
                point.x = min(point.x, mac.maxX - 3)
            }
        }
        // Warp first, then reconnect the mouse to the cursor: reconnecting after the warp also
        // cancels the quarter-second pause macOS otherwise puts on the mouse after a warp.
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        showCursor()
        return true
    }

    // MARK: Events (tap thread)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return Unmanaged.passUnretained(event) }
        guard _onPC else {
            switch type {
            case .mouseMoved:
                if !config.pcScreen.isNull, config.pcScreen.contains(event.location),
                   ProcessInfo.processInfo.systemUptime >= reentryAllowedAt, noButtonsHeld(),
                   let sink, enterPC(from: event.location, sink: sink) {
                    return nil
                }
            case .leftMouseDown:
                dragCheckPending = false; dragCheckFailed = false
                DispatchQueue.main.async { [weak self] in self?.onMouseDown?() }
            case .leftMouseUp:
                dragCheckPending = false; dragCheckFailed = false
            case .leftMouseDragged:
                // Something dragged into the PC's screen: ask the main thread whether it's files.
                if !dragCheckPending, !dragCheckFailed, sink != nil, !config.pcScreen.isNull,
                   config.pcScreen.contains(event.location), ProcessInfo.processInfo.systemUptime >= reentryAllowedAt {
                    dragCheckPending = true
                    DispatchQueue.main.async { [weak self] in self?.onDragAtEdge?() }
                }
            default: break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let sink else {
            // The link went away mid-crossing; give the Mac its pointer back.
            _ = leaveLocked(at: nil)
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            let s = config.pointerScale
            if dx != 0 || dy != 0 { sink.sendInput(.move(dx: Float(dx * s), dy: Float(dy * s))) }
        case .leftMouseDown: sink.sendInput(.button(0, down: true))
        case .leftMouseUp:
            sink.sendInput(.button(0, down: false))
            if draggingFiles {
                // The Mac's own drag was cancelled when it crossed; let the Mac see the button
                // come up too, so it doesn't think it's still held.
                draggingFiles = false
                return Unmanaged.passUnretained(event)
            }
        case .rightMouseDown, .rightMouseUp: sink.sendInput(.button(1, down: type == .rightMouseDown))
        case .otherMouseDown, .otherMouseUp:
            let n = event.getIntegerValueField(.mouseEventButtonNumber)
            if (2...4).contains(n) { sink.sendInput(.button(UInt8(n), down: type == .otherMouseDown)) }
        case .scrollWheel: scroll(event, sink)
        case .keyDown, .keyUp: key(event, down: type == .keyDown, sink)
        case .flagsChanged: flags(event, sink)
        default:
            if type.rawValue == 14 { return media(event, sink) }
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    /// Main thread, answering `onDragAtEdge`: carries the drag across (the file offer has just
    /// been sent). Returns false if the drag ended meanwhile.
    func enterPCWithDrag() -> Bool {
        locked {
            defer { dragCheckPending = false }
            guard !_onPC, let sink, !config.pcScreen.isNull,
                  CGEventSource.buttonState(.combinedSessionState, button: .left) else { return false }
            let pc = config.pcScreen
            var at = CGEvent(source: nil)?.location ?? CGPoint(x: pc.minX, y: pc.midY)
            at.x = min(max(at.x, pc.minX), pc.maxX - 1)
            at.y = min(max(at.y, pc.minY), pc.maxY - 1)
            guard enterPC(from: at, sink: sink) else { return false }
            draggingFiles = true
            return true
        }
    }

    /// Main thread, answering `onDragAtEdge` when it isn't a file drag.
    func dragCheckDone(crossed: Bool) {
        locked {
            dragCheckPending = false
            if !crossed { dragCheckFailed = true }
        }
    }

    /// Posts a key press that only the Mac sees (not sent to the PC).
    static func postKey(_ code: CGKeyCode) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Posts a left-button press at the pointer that only the Mac sees.
    static func postMouseDown() {
        let at = CGEvent(source: nil)?.location ?? .zero
        let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: at, mouseButton: .left)
        e?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e?.post(tap: .cghidEventTap)
    }

    private func enterPC(from location: CGPoint, sink: CrossoverSession) -> Bool {
        let pc = config.pcScreen
        let fx = min(max((location.x - pc.minX) / pc.width, 0), 1)
        let fy = min(max((location.y - pc.minY) / pc.height, 0), 1)
        // Park the hidden pointer just inside the Mac screen it came from.
        var park = CGPoint(x: pc.minX - 2, y: location.y)
        if let mac = nearestMacScreen(to: location) {
            park.y = min(max(location.y, mac.minY + 1), mac.maxY - 2)
            park.x = location.x >= pc.minX ? mac.maxX - 2 : park.x
        }
        parkedAt = park
        _onPC = true
        // Tell the PC first, so its pointer appears as soon as the Mac's disappears.
        sink.sendInput(.enter(x: Float(fx), y: Float(fy)))
        CGWarpMouseCursorPosition(park)
        CGAssociateMouseAndMouseCursorPosition(0)
        hideCursor()
        let point = CGPoint(x: fx, y: fy)
        DispatchQueue.main.async { [weak self] in self?.onEntered?(point) }
        return true
    }

    private func noButtonsHeld() -> Bool {
        (0..<3).allSatisfy { !CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: $0)!) }
    }

    private func scroll(_ event: CGEvent, _ sink: CrossoverSession) {
        var v: Double, h: Double
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            // Trackpads and smooth-scrolling mice: pixels. About 40 px per wheel notch.
            v = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / 40
            h = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) / 40
        } else {
            v = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            h = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        }
        let speed = config.scrollSpeed
        v *= speed; h *= -speed  // the Mac's horizontal axis is the other way round from Windows'
        if v != 0 || h != 0 { sink.sendInput(.scroll(vertical: Float(v), horizontal: Float(h))) }
    }

    private func key(_ event: CGEvent, down: Bool, _ sink: CrossoverSession) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let f = event.flags
        if down, code == kVK_Escape, f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand) {
            sink.sendInput(.leave)
            _ = leaveLocked(at: nil)
            DispatchQueue.main.async { [weak self] in self?.onEmergencyReturn?() }
            return
        }
        if let vk = KeyMap.volumeKeys[code] { sink.sendInput(.vkey(vk, down: down)); return }
        guard let k = KeyMap.key(code) else { return }
        sink.sendInput(.key(scan: k.scan, extended: k.extended, down: down))
    }

    private func flags(_ event: CGEvent, _ sink: CrossoverSession) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if code == kVK_CapsLock {
            sink.sendInput(.key(scan: KeyMap.capsLock.scan, extended: false, down: true))
            sink.sendInput(.key(scan: KeyMap.capsLock.scan, extended: false, down: false))
            return
        }
        guard let m = KeyMap.modifier(code, style: config.style) else { return }
        let down = event.flags.rawValue & m.deviceBit != 0
        sink.sendInput(.key(scan: m.key.scan, extended: m.key.extended, down: down))
    }

    private func media(_ event: CGEvent, _ sink: CrossoverSession) -> Unmanaged<CGEvent>? {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let keyType = (ns.data1 & 0xFFFF0000) >> 16
        let state = (ns.data1 & 0xFF00) >> 8
        if let vk = KeyMap.mediaKeys[keyType] { sink.sendInput(.vkey(vk, down: state == 0xA)) }
        return nil
    }

    // MARK: Cursor

    /// Hiding the cursor normally only works for the frontmost app; this connection property
    /// (also used by Barrier and Input Leap) lets a background app hide it.
    private func hideCursor() {
        guard !cursorHidden else { return }
        Self.allowBackgroundCursorChanges()
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        cursorHidden = false
    }

    nonisolated(unsafe) private static var backgroundCursorAllowed = false
    private static func allowBackgroundCursorChanges() {
        guard !backgroundCursorAllowed,
              let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(sky, "CGSMainConnectionID") ?? dlsym(sky, "_CGSDefaultConnection"),
              let set = dlsym(sky, "CGSSetConnectionProperty") else { return }
        typealias MainConn = @convention(c) () -> Int32
        typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let cid = unsafeBitCast(main, to: MainConn.self)()
        _ = unsafeBitCast(set, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        backgroundCursorAllowed = true
    }

    // MARK: Screens

    /// All screens with their names, in Quartz (top-left) coordinates. Main thread only.
    @MainActor
    static func quartzFrames() -> [(name: String, frame: CGRect)] {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return (s.localizedName, CGDisplayBounds(id))
        }
    }

    /// Every active display's frame, from Core Graphics (safe on any thread).
    static func displayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// The Mac screen that borders the PC's screen, closest to `point`.
    static func macScreen(touching pc: CGRect, near point: CGPoint) -> CGRect? {
        displayFrames().filter { $0 != pc }.min { distance($0, point) < distance($1, point) }
    }

    private func nearestMacScreen(to point: CGPoint) -> CGRect? {
        macScreens.min { Self.distance($0, point) < Self.distance($1, point) }
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
