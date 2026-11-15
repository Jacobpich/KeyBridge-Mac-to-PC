import AppKit
import Combine
import HIDPP
import UserNotifications

/// Live state for one keyboard or mouse.
@MainActor
final class DeviceModel: ObservableObject, Identifiable {
    let device: LogiDevice
    nonisolated var id: String { device.id }

    @Published var online = false
    @Published var loaded = false
    @Published var state = DeviceState()
    @Published var pairedName: String
    @Published var wirelessPID: String?
    @Published var lastEvent: String?
    @Published var lastConnected: Date?
    @Published var busy = false
    @Published var lastError: String?

    /// Controls currently diverted to the app → whether raw XY is on.
    private var diverted: [UInt16: Bool] = [:]
    private var pressed: Set<UInt16> = []
    private var gestureDelta: (x: Int, y: Int) = (0, 0)
    private var lowBatteryWarned = false

    init(device: LogiDevice, pairedName: String) {
        self.device = device
        self.pairedName = pairedName
    }

    var name: String { loaded ? device.name : pairedName }
    var kind: DeviceKind { loaded ? device.kind : (pairedName.lowercased().contains("key") ? .keyboard : .mouse) }
    var configKey: String { device.unitID ?? id }
    var config: DeviceConfig { ConfigStore.shared.config(for: configKey) }

    var symbol: String {
        switch kind {
        case .keyboard, .numpad: "keyboard"
        case .mouse, .trackball: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        default: "dot.radiowaves.left.and.right"
        }
    }

    // MARK: Loading

    func connect() async {
        do {
            if !loaded {
                try await device.load()
                loaded = true
            } else {
                try await device.ping()
            }
            online = true
            lastConnected = Date()
            await reapplySavedSettings()
            await refresh()
            await updateDiversion(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, force: true)
        } catch {
            online = false
            lastError = "\(error)"
        }
    }

    func refresh() async {
        guard online else { return }
        let s = await DeviceState.read(device)
        state = s
        checkBattery()
    }

    // MARK: Writing settings (each write is saved and re-applied on reconnect)

    private func perform(_ label: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work(); lastError = nil } catch { lastError = "\(label): \(error)" }
    }

    func setDPI(_ value: Int) async {
        await perform("DPI") { try await device.setDPI(value) }
        ConfigStore.shared.update(configKey) { $0.settings.dpi = value }
        if let d = try? await device.dpi() { state.dpi = d }
    }

    func setSmartShift(mode: SmartShiftConfig.WheelMode? = nil, threshold: Int? = nil) async {
        await perform("SmartShift") { try await device.setSmartShift(mode: mode, threshold: threshold) }
        ConfigStore.shared.update(configKey) {
            if let mode { $0.settings.smartShiftMode = mode.rawValue }
            if let threshold { $0.settings.smartShiftThreshold = threshold }
        }
        if let s = try? await device.smartShift() { state.smartShift = s }
    }

    func setWheel(_ w: WheelConfig) async {
        await perform("Scroll wheel") { try await device.setWheel(w) }
        ConfigStore.shared.update(configKey) { $0.settings.wheelHiRes = w.hiRes; $0.settings.wheelInverted = w.inverted }
        if let w = try? await device.wheel() { state.wheel = w }
    }

    func setThumbwheel(_ t: ThumbwheelConfig) async {
        await perform("Thumb wheel") { try await device.setThumbwheel(t) }
        ConfigStore.shared.update(configKey) { $0.settings.thumbInverted = t.inverted }
        if let t = try? await device.thumbwheel() { state.thumbwheel = t }
    }

    func setBacklight(_ c: BacklightConfig) async {
        await perform("Backlight") { try await device.setBacklight(c) }
        ConfigStore.shared.update(configKey) {
            $0.settings.backlightEnabled = c.enabled
            $0.settings.backlightMode = c.mode.rawValue
            $0.settings.backlightLevel = c.level
            $0.settings.backlightHandsOut = c.handsOutSeconds
            $0.settings.backlightHandsIn = c.handsInSeconds
            $0.settings.backlightPowered = c.poweredSeconds
        }
        if let b = try? await device.backlight() { state.backlight = b }
    }

    var backlightAlwaysOn: Bool { config.settings.backlightAlwaysOn ?? false }

    /// Always on: backlight enabled with every turn-off timer at the firmware maximum (2 hours),
    /// refreshed every 15 minutes while Keybridge runs so the timer never runs out.
    func setBacklightAlwaysOn(_ on: Bool) async {
        var current = state.backlight
        if current == nil { current = try? await device.backlight() }
        guard var b = current else { return }
        if on {
            if !backlightAlwaysOn {
                ConfigStore.shared.update(configKey) {
                    $0.settings.backlightTimeoutsBeforeAlwaysOn = [b.handsOutSeconds, b.handsInSeconds, b.poweredSeconds]
                }
            }
            b.enabled = true
            b = Self.maxed(b)
        } else {
            let previous = config.settings.backlightTimeoutsBeforeAlwaysOn ?? [1800, 1800, 1800]
            b.handsOutSeconds = min(previous[0], BacklightConfig.maxTimeoutSeconds)
            b.handsInSeconds = min(previous[1], BacklightConfig.maxTimeoutSeconds)
            b.poweredSeconds = min(previous[2], BacklightConfig.maxTimeoutSeconds)
        }
        ConfigStore.shared.update(configKey) { $0.settings.backlightAlwaysOn = on }
        await setBacklight(b)
        updateKeepAlive()
    }

    static func maxed(_ b: BacklightConfig) -> BacklightConfig {
        var b = b
        b.handsOutSeconds = BacklightConfig.maxTimeoutSeconds
        b.handsInSeconds = BacklightConfig.maxTimeoutSeconds
        b.poweredSeconds = BacklightConfig.maxTimeoutSeconds
        return b
    }

    private var keepAlive: Timer?

    /// Re-sends the backlight settings, which restarts the keyboard's turn-off timer.
    private func updateKeepAlive() {
        keepAlive?.invalidate()
        keepAlive = nil
        guard backlightAlwaysOn, device.has(.backlight2) else { return }
        keepAlive = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.online, self.backlightAlwaysOn else { return }
                Task {
                    guard var b = try? await self.device.backlight() else { return }
                    b.enabled = true
                    b = Self.maxed(b)
                    try? await self.device.setBacklight(b)
                    self.state.backlight = b
                }
            }
        }
    }

    func setFnKeys(_ on: Bool) async {
        await perform("Fn keys") { try await device.setFnKeysAsFunctionKeys(on) }
        ConfigStore.shared.update(configKey) { $0.settings.fnKeys = on }
        if let f = try? await device.fnKeysAsFunctionKeys() { state.fnKeys = f }
    }

    func switchHost(_ host: Int) async {
        await perform("Easy-Switch") { try await device.switchHost(to: host) }
        online = false
        lastEvent = "Switched to channel \(host + 1)"
    }

    /// Settings like DPI and backlight can reset when a device wakes or reconnects.
    private func reapplySavedSettings() async {
        let s = config.settings
        if let dpi = s.dpi, device.has(.adjustableDPI) { try? await device.setDPI(dpi) }
        if s.smartShiftMode != nil || s.smartShiftThreshold != nil, device.has(.smartShift) || device.has(.smartShiftEnhanced) {
            try? await device.setSmartShift(mode: s.smartShiftMode.flatMap(SmartShiftConfig.WheelMode.init), threshold: s.smartShiftThreshold)
        }
        if s.wheelHiRes != nil || s.wheelInverted != nil, device.has(.hiResWheel), var w = try? await device.wheel() {
            w.hiRes = s.wheelHiRes ?? w.hiRes
            w.inverted = s.wheelInverted ?? w.inverted
            try? await device.setWheel(w)
        }
        if let inv = s.thumbInverted, device.has(.thumbwheel), var t = try? await device.thumbwheel() {
            t.inverted = inv
            try? await device.setThumbwheel(t)
        }
        if s.backlightEnabled != nil, device.has(.backlight2), var b = try? await device.backlight() {
            b.enabled = s.backlightEnabled ?? b.enabled
            if let m = s.backlightMode.flatMap(BacklightConfig.Mode.init) { b.mode = m }
            b.level = s.backlightLevel ?? b.level
            b.handsOutSeconds = s.backlightHandsOut ?? b.handsOutSeconds
            b.handsInSeconds = s.backlightHandsIn ?? b.handsInSeconds
            b.poweredSeconds = s.backlightPowered ?? b.poweredSeconds
            if s.backlightAlwaysOn == true { b.enabled = true; b = Self.maxed(b) }
            try? await device.setBacklight(b)
        }
        updateKeepAlive()
        if let fn = s.fnKeys { try? await device.setFnKeysAsFunctionKeys(fn) }
    }

    // MARK: Button remapping

    func updateProfiles(_ change: (inout DeviceProfiles) -> Void) {
        ConfigStore.shared.update(configKey) { change(&$0.profiles) }
        objectWillChange.send()
        Task { await updateDiversion(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    }

    /// Diverts exactly the controls that have a mapping for the app in front; returns the rest to normal.
    func updateDiversion(for bundleID: String?, force: Bool = false) async {
        guard online, device.has(.reprogControls) else { return }
        let wanted = config.profiles.effective(for: bundleID)
        let available = Set(state.controls.filter(\.isDivertable).map(\.cid))
        if force { diverted = [:] }
        for (cid, mapping) in wanted where available.contains(cid) {
            let raw = mapping.useGestures && (state.controls.first { $0.cid == cid }?.supportsRawXY ?? false)
            if diverted[cid] != raw {
                do { try await device.divert(cid, true, rawXY: raw); diverted[cid] = raw }
                catch { lastError = "Couldn't remap \(cid): \(error)" }
            }
        }
        for cid in diverted.keys where wanted[cid] == nil {
            try? await device.divert(cid, false)
            diverted[cid] = nil
        }
    }

    /// Returns every control to normal (on quit).
    func releaseAll() async {
        for cid in diverted.keys { try? await device.divert(cid, false) }
        diverted = [:]
    }

    private func mapping(_ cid: UInt16) -> ControlMapping? {
        config.profiles.effective(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)[cid]
    }

    private func buttonsChanged(_ params: [UInt8]) {
        var now = Set<UInt16>()
        for i in stride(from: 0, to: 8, by: 2) {
            let cid = UInt16(params[i]) << 8 | UInt16(params[i + 1])
            if cid != 0 { now.insert(cid) }
        }
        for cid in now.subtracting(pressed) {
            guard let m = mapping(cid) else { continue }
            if m.useGestures { gestureDelta = (0, 0) } else if let a = m.action { ActionRunner.perform(a) }
        }
        for cid in pressed.subtracting(now) {
            guard let m = mapping(cid), m.useGestures else { continue }
            let (dx, dy) = gestureDelta
            let direction: GestureDirection
            if max(abs(dx), abs(dy)) < 50 { direction = .tap }
            else if abs(dx) > abs(dy) { direction = dx > 0 ? .right : .left }
            else { direction = dy > 0 ? .down : .up }
            if let a = m.gestures[direction] { ActionRunner.perform(a) }
        }
        pressed = now
    }

    private func rawXY(_ params: [UInt8]) {
        let dx = Int(Int16(bitPattern: UInt16(params[0]) << 8 | UInt16(params[1])))
        let dy = Int(Int16(bitPattern: UInt16(params[2]) << 8 | UInt16(params[3])))
        gestureDelta.x += dx
        gestureDelta.y += dy
    }

    // MARK: Events from the device

    func handle(_ m: HIDPPMessage) {
        // Receiver: device connected / disconnected (HID++ 1.0 notification 0x41).
        if m.subID == 0x41 {
            let linkDown = m.params.first.map { $0 & 0x40 != 0 } ?? false
            lastEvent = linkDown ? "Went to sleep / disconnected" : "Connected"
            if linkDown { online = false; pressed = []; diverted = [:] }
            else { Task { await connect() } }
            return
        }
        guard m.softwareID == 0, let feature = device.feature(atIndex: m.subID) else { return }
        switch (feature, m.function) {
        case (Feature.unifiedBattery.rawValue, 0):
            state.battery = .unified(m.params)
            checkBattery()
        case (Feature.batteryStatus.rawValue, 0):
            state.battery = .legacy(m.params)
            checkBattery()
        case (Feature.wirelessStatus.rawValue, 0):
            // The device rebooted or reconnected and lost its temporary settings.
            lastEvent = "Reconnected"
            online = true
            Task { await connect() }
        case (Feature.reprogControls.rawValue, 0):
            buttonsChanged(m.params)
        case (Feature.reprogControls.rawValue, 1):
            rawXY(m.params)
        case (Feature.backlight2.rawValue, _):
            Task { if let b = try? await device.backlight() { state.backlight = b } }
        case (Feature.changeHost.rawValue, _), (Feature.hostsInfo.rawValue, _):
            Task { if let h = try? await device.hosts() { state.hosts = h } }
        default:
            break
        }
    }

    /// The last battery % read from this device, kept across relaunches so the menu bar has a
    /// number while the device is still asleep.
    private var lastBatteryKey: String { "lastBattery.\(wirelessPID ?? pairedName)" }
    var lastKnownPercent: Int? { UserDefaults.standard.object(forKey: lastBatteryKey) as? Int }

    private func checkBattery() {
        guard let b = state.battery, let pct = b.percent else { return }
        UserDefaults.standard.set(pct, forKey: lastBatteryKey)
        if pct <= 15, b.charging == .discharging, !lowBatteryWarned, Bundle.main.bundleIdentifier != nil {
            lowBatteryWarned = true
            let content = UNMutableNotificationContent()
            content.title = "\(name) battery low"
            content.body = "\(pct)% left. Plug it in soon."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } else if pct > 20 || b.charging != .discharging {
            lowBatteryWarned = false
        }
    }
}

/// The Bolt receiver (or another receiver) and what it reports.
struct ReceiverInfo: Identifiable {
    var id: String { "\(productID)-\(serial ?? "")" }
    var name: String
    var productID: Int
    var serial: String?
    var transport: String
    var connectedCount: Int?
    var slots: [(index: Int, wpid: String, kind: UInt8, name: String)]
}

@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    @Published private(set) var devices: [DeviceModel] = []
    @Published private(set) var receivers: [ReceiverInfo] = []
    @Published var accessibilityTrusted = AXIsProcessTrusted()

    private let manager = HIDPPManager()
    private var observers: [NSObjectProtocol] = []
    private var deviceSubscriptions: [AnyCancellable] = []
    /// Every keyboard, mouse and trackpad, of any brand.
    let accessoryMonitor = AccessoryMonitor()

    /// Keyboards, mice and trackpads other than the Logitech devices listed in `devices` (those
    /// get their full HID++ pages instead).
    var accessories: [Accessory] {
        let logitech = devices.map { $0.name.lowercased() }
        return accessoryMonitor.accessories.filter { a in
            guard a.vendorID == 0x046D else { return true }
            let n = a.name.lowercased()
            return !logitech.contains { $0 == n || $0.hasPrefix(n) || n.hasPrefix($0) }
        }
    }

    /// Adds a device and passes its changes on, so the menu-bar battery label stays current.
    private func track(_ model: DeviceModel) {
        devices.append(model)
        deviceSubscriptions.append(model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }
    private var timer: Timer?

    func start() {
        manager.onChannelAdded = { [weak self] channel in Task { await self?.added(channel) } }
        manager.onChannelRemoved = { [weak self] channel in self?.removed(channel) }
        manager.start()
        deviceSubscriptions.append(accessoryMonitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        accessoryMonitor.start()

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for d in self.devices { Task { await d.updateDiversion(for: app?.bundleIdentifier) } }
                }
            })
        // Refresh battery and settings every couple of minutes, and retry sleeping devices.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.accessibilityTrusted = AXIsProcessTrusted()
                for d in self.devices { Task { d.online ? await d.refresh() : await d.connect() } }
            }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    func reconnectAll() {
        for d in devices { Task { await d.connect() } }
    }

    private func added(_ channel: HIDPPChannel) async {
        channel.onNotification = { [weak self] message in
            guard let self else { return }
            let index = message.deviceIndex
            self.devices.first { $0.device.channel === channel && $0.device.index == index }?.handle(message)
        }
        if channel.isReceiver {
            // Ask the receiver for connect/disconnect notifications (wireless + software present).
            try? await channel.writeRegister(0x00, params: [0x00, 0x09, 0x00])
            var info = ReceiverInfo(name: receiverProductIDs[channel.productID] ?? channel.productName,
                                    productID: channel.productID, serial: channel.serialNumber,
                                    transport: channel.transport, slots: [])
            if let c = try? await channel.readRegister(0x02) { info.connectedCount = Int(c[1]) }
            for slot in 1...6 {
                guard let p = try? await channel.readRegister(0xB5, params: [UInt8(0x50 + slot)], long: true) else { continue }
                var name = ""
                if let n = try? await channel.readRegister(0xB5, params: [UInt8(0x60 + slot), 0x01], long: true) {
                    name = String(decoding: n.dropFirst(3).prefix(Int(n[2])), as: UTF8.self)
                }
                let wpid = String(format: "%02X%02X", p[3], p[2])
                info.slots.append((slot, wpid, p[1], name))
                let model = DeviceModel(device: LogiDevice(channel: channel, index: UInt8(slot)), pairedName: name.isEmpty ? "Device \(slot)" : name)
                model.wirelessPID = wpid
                track(model)
                await model.connect()
            }
            receivers.append(info)
        } else {
            // Connected directly (Bluetooth or cable). A device that dropped off earlier is
            // replaced by this new connection.
            devices.removeAll { !$0.device.channel.isReceiver && !$0.online && $0.device.channel.productID == channel.productID }
            let model = DeviceModel(device: LogiDevice(channel: channel, index: 0xFF), pairedName: channel.productName)
            track(model)
            await model.connect()
        }
    }

    private func removed(_ channel: HIDPPChannel) {
        if channel.isReceiver {
            devices.removeAll { $0.device.channel === channel }
        } else {
            // A Bluetooth device disappears while it sleeps or is switched to another computer.
            // Keep it listed (asleep, with its last battery level) until it comes back.
            for d in devices where d.device.channel === channel { d.online = false }
        }
        receivers.removeAll { $0.productID == channel.productID && $0.serial == channel.serialNumber }
    }

    func releaseAll() async {
        for d in devices { await d.releaseAll() }
    }
}
