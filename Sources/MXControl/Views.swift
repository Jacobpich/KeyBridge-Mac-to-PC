import AppKit
import HIDPP
import ServiceManagement
import SwiftUI

// MARK: Overview

struct OverviewView: View {
    @ObservedObject var model: DeviceModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Battery") {
                if let b = model.state.battery {
                    LabeledContent("Charge") {
                        HStack {
                            ProgressView(value: Double(b.percent ?? 0), total: 100).frame(width: 160)
                            Text(b.percent.map { "\($0)%" } ?? b.level).monospacedDigit()
                        }
                    }
                    LabeledContent("Level", value: b.level)
                    LabeledContent("Status", value: chargingText(b))
                    LabeledContent("Power cable", value: b.externalPower ? "Connected" : "Not connected")
                } else {
                    Text("No battery information yet.").foregroundStyle(.secondary)
                }
            }
            Section("Device") {
                LabeledContent("Name", value: model.name)
                LabeledContent("Type", value: model.kind.label)
                LabeledContent("Serial number", value: model.device.serial ?? "—")
                LabeledContent("Model ID", value: model.device.modelID ?? "—")
                LabeledContent("Unit ID", value: model.device.unitID ?? "—")
                LabeledContent("Wireless product ID", value: model.wirelessPID ?? "—")
                LabeledContent("HID++ version", value: model.device.protocolVersion)
                ForEach(Array(model.device.firmware.enumerated()), id: \.offset) { _, f in
                    LabeledContent("Firmware (\(f.description.components(separatedBy: " ").first ?? ""))", value: "\(f.name) \(f.version)")
                }
            }
            Section("Connection") {
                LabeledContent("Status", value: model.online ? "Connected" : "Asleep / disconnected")
                LabeledContent("Through", value: model.device.index == 0xFF ? "\(model.device.channel.transport) (direct)"
                               : "\(receiverProductIDs[model.device.channel.productID] ?? "Receiver"), slot \(model.device.index)")
                if let h = model.state.hosts {
                    LabeledContent("Easy-Switch channel", value: "\(h.current + 1) of \(h.count)")
                }
                if let t = model.lastConnected {
                    LabeledContent("Last connected", value: t.formatted(date: .omitted, time: .standard))
                }
                if let e = model.lastEvent { LabeledContent("Last event", value: e) }
            }
            Section("App") {
                Toggle("Open MX Control at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Button("Re-read device") { Task { await model.connect() } }
            }
        }
        .formStyle(.grouped)
    }

    private func chargingText(_ b: BatteryInfo) -> String {
        switch b.charging {
        case .discharging: "On battery"
        case .charging: "Charging"
        case .chargingSlow: "Charging slowly"
        case .full: "Fully charged"
        case .error: "Charging error"
        }
    }
}

// MARK: Keyboard (backlight + Fn keys)

struct KeyboardView: View {
    @ObservedObject var model: DeviceModel
    @State private var draftLevel: Double = 0

    private static let timeouts: [(Int, String)] = [
        (5, "5 seconds"), (10, "10 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"),
        (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"), (900, "15 minutes"), (1800, "30 minutes"),
        (3600, "1 hour"),
    ]

    var body: some View {
        Form {
            if var b = model.state.backlight {
                Section("Backlight") {
                    Toggle(isOn: Binding(get: { model.backlightAlwaysOn }, set: { on in Task { await model.setBacklightAlwaysOn(on) } })) {
                        Text("Always on while the keyboard is on")
                        Text("The backlight never times out. It only goes dark when the keyboard itself sleeps or is switched off. Uses more battery.")
                    }
                    Toggle("Backlight", isOn: Binding(get: { b.enabled }, set: { b.enabled = $0; apply(b) }))
                        .disabled(model.backlightAlwaysOn)
                    Picker("Brightness", selection: Binding(get: { b.mode }, set: { b.mode = $0; apply(b) })) {
                        ForEach(BacklightConfig.Mode.allCases.filter { $0 != .automatic || b.supportsAuto }) { Text($0.label).tag($0) }
                    }
                    .disabled(!b.enabled)
                    if b.mode == .manual, b.levelCount > 1 {
                        LabeledContent("Level") {
                            HStack {
                                Slider(value: $draftLevel, in: 0...Double(b.levelCount - 1), step: 1) { editing in
                                    if !editing { b.level = UInt8(draftLevel); apply(b) }
                                }
                                Text("\(Int(draftLevel)) / \(b.levelCount - 1)").monospacedDigit().frame(width: 50)
                            }
                        }
                        .disabled(!b.enabled)
                    }
                    Text("Automatic adjusts to the room using the keyboard's light sensor. On uses the keyboard's own default level.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.backlightAlwaysOn { Section("Turn off after") {
                    timeoutPicker("Hands away from the keyboard", b.handsOutSeconds) { b.handsOutSeconds = $0; apply(b) }
                    timeoutPicker("Hands near the keyboard (proximity)", b.handsInSeconds) { b.handsInSeconds = $0; apply(b) }
                    timeoutPicker("While charging", b.poweredSeconds) { b.poweredSeconds = $0; apply(b) }
                    Text("The backlight wakes when your hands come near the keys, then turns off after these times.")
                        .font(.caption).foregroundStyle(.secondary)
                } }
            }
            if let fn = model.state.fnKeys {
                Section("Function keys") {
                    Toggle("Use F1, F2, etc. as standard function keys",
                           isOn: Binding(get: { fn }, set: { v in Task { await model.setFnKeys(v) } }))
                    Text(fn ? "Hold Fn to use the brightness, media and other special keys."
                            : "The top row does its special action; hold Fn for F1–F12.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftLevel = Double(model.state.backlight?.level ?? 0) }
        .onChange(of: model.state.backlight?.level) { _, v in draftLevel = Double(v ?? 0) }
    }

    private func timeoutPicker(_ title: String, _ value: Int, set: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            ForEach(Self.timeouts + (Self.timeouts.contains { $0.0 == value } ? [] : [(value, "\(value) seconds")]), id: \.0) {
                Text($0.1).tag($0.0)
            }
        }
    }

    private func apply(_ b: BacklightConfig) { Task { await model.setBacklight(b) } }
}

// MARK: Pointer & scroll

struct PointerView: View {
    @ObservedObject var model: DeviceModel
    @State private var draftDPI: Double = 1000
    @State private var draftThreshold: Double = 10

    var body: some View {
        Form {
            if let d = model.state.dpi {
                Section("Pointer speed") {
                    LabeledContent("DPI") {
                        HStack {
                            Slider(value: $draftDPI, in: Double(d.range.lowerBound)...Double(d.range.upperBound), step: 50) { editing in
                                if !editing { Task { await model.setDPI(snap(Int(draftDPI), d)) } }
                            }
                            Text("\(Int(draftDPI))").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    HStack {
                        ForEach([800, 1000, 1600, 2400, 4000], id: \.self) { v in
                            Button("\(v)") { draftDPI = Double(v); Task { await model.setDPI(v) } }
                        }
                        Spacer()
                        Button("Default (\(d.defaultDPI))") { draftDPI = Double(d.defaultDPI); Task { await model.setDPI(d.defaultDPI) } }
                    }
                    Text("This is the sensor's speed. macOS's Tracking Speed in System Settings still applies on top.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = model.state.smartShift {
                Section("Scroll wheel (SmartShift)") {
                    Picker("Wheel mode", selection: Binding(get: { s.mode }, set: { m in Task { await model.setSmartShift(mode: m) } })) {
                        Text("Ratchet (click-by-click)").tag(SmartShiftConfig.WheelMode.ratchet)
                        Text("Free spin").tag(SmartShiftConfig.WheelMode.freeSpin)
                    }
                    Toggle("Switch to free spin when I scroll fast", isOn: Binding(
                        get: { s.threshold > 0 && s.threshold < 0xFF },
                        set: { on in
                            let t = on ? max(1, min(50, Int(draftThreshold))) : 0xFF
                            Task { await model.setSmartShift(mode: .ratchet, threshold: t) }
                        }))
                    if s.threshold > 0 && s.threshold < 0xFF {
                        LabeledContent("Sensitivity") {
                            HStack {
                                Text("Easy").font(.caption)
                                Slider(value: $draftThreshold, in: 1...50, step: 1) { editing in
                                    if !editing { Task { await model.setSmartShift(threshold: Int(draftThreshold)) } }
                                }
                                Text("Hard").font(.caption)
                                Text("\(Int(draftThreshold))").monospacedDigit().frame(width: 28)
                            }
                        }
                    }
                    Text("Lower sensitivity means a gentler flick switches to free spin. The button behind the wheel toggles modes by hand.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let w = model.state.wheel {
                Section("Main wheel") {
                    Toggle("Reverse scroll direction (on the mouse only)", isOn: Binding(
                        get: { w.inverted }, set: { v in var n = w; n.inverted = v; Task { await model.setWheel(n) } }))
                    Toggle("High-resolution scrolling", isOn: Binding(
                        get: { w.hiRes }, set: { v in var n = w; n.hiRes = v; Task { await model.setWheel(n) } }))
                    Text("High-resolution scrolling sends \(w.multiplier)× finer steps for smoother scrolling. Some apps scroll much faster with it on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let t = model.state.thumbwheel {
                Section("Thumb wheel") {
                    Toggle("Reverse thumb wheel direction", isOn: Binding(
                        get: { t.inverted }, set: { v in var n = t; n.inverted = v; Task { await model.setThumbwheel(n) } }))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { sync() }
        .onChange(of: model.state.dpi?.current) { _, _ in sync() }
        .onChange(of: model.state.smartShift?.threshold) { _, _ in sync() }
    }

    private func sync() {
        draftDPI = Double(model.state.dpi?.current ?? 1000)
        if let t = model.state.smartShift?.threshold, t > 0, t < 0xFF { draftThreshold = Double(min(t, 50)) }
    }

    private func snap(_ v: Int, _ d: DPIInfo) -> Int {
        d.choices.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
    }
}

// MARK: Connections

struct ConnectionsView: View {
    @ObservedObject var model: DeviceModel
    @State private var confirmHost: Int?

    var body: some View {
        Form {
            if let h = model.state.hosts {
                Section("Easy-Switch channels") {
                    ForEach(h.slots) { slot in
                        HStack {
                            Text("\(slot.index + 1)").font(.title3.bold()).frame(width: 24)
                            Image(systemName: slot.busType == 4 ? "dot.radiowaves.left.and.right" : "cable.connector")
                                .frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(slot.paired ? (slot.name.isEmpty ? "Paired computer" : slot.name) : "Empty")
                                Text(slot.paired ? slot.busLabel : "Not paired").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if slot.index == h.current {
                                Label("This Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if slot.paired {
                                Button("Switch to…") { confirmHost = slot.index }
                            }
                        }
                    }
                    Text("Computer names are the ones the device stored when it was paired.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Link") {
                LabeledContent("Connected through", value: model.device.index == 0xFF ? model.device.channel.transport
                               : (receiverProductIDs[model.device.channel.productID] ?? "Receiver"))
                if model.device.index != 0xFF { LabeledContent("Receiver slot", value: "\(model.device.index)") }
                LabeledContent("Wireless product ID", value: model.wirelessPID ?? "—")
                LabeledContent("Status", value: model.online ? "Connected" : "Asleep / disconnected")
                if let t = model.lastConnected { LabeledContent("Connected since", value: t.formatted(date: .abbreviated, time: .standard)) }
                if let e = model.lastEvent { LabeledContent("Last event", value: e) }
                Text("Logitech doesn't expose signal strength for Bolt or Bluetooth links, so it isn't shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Switch \(model.name) to channel \((confirmHost ?? 0) + 1)?", isPresented: Binding(
            get: { confirmHost != nil }, set: { if !$0 { confirmHost = nil } })) {
            Button("Switch") { if let h = confirmHost { Task { await model.switchHost(h) } }; confirmHost = nil }
            Button("Cancel", role: .cancel) { confirmHost = nil }
        } message: {
            Text("It disconnects from this Mac right away. Press its Easy-Switch button for channel \(model.state.hosts.map { $0.current + 1 } ?? 1) to come back.")
        }
    }
}

struct ReceiverView: View {
    let receiver: ReceiverInfo
    var body: some View {
        Form {
            Section(receiver.name) {
                LabeledContent("Product ID", value: String(format: "0x%04X", receiver.productID))
                LabeledContent("Serial number", value: receiver.serial ?? "—")
                LabeledContent("Connection", value: receiver.transport)
                if let c = receiver.connectedCount { LabeledContent("Devices connected now", value: "\(c)") }
            }
            Section("Paired devices") {
                ForEach(receiver.slots, id: \.index) { s in
                    LabeledContent("Slot \(s.index)", value: "\(s.name)  ·  wireless ID \(s.wpid)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Menu bar

struct MenuBarView: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.devices) { MenuDeviceSection(model: $0) }
            if store.devices.isEmpty { Text("No Logitech devices found").foregroundStyle(.secondary) }
            ForEach(store.apple.accessories) { a in
                HStack {
                    AccessoryIcon(accessory: a)
                    Text(a.name).bold()
                    Spacer()
                    Text("\(a.percent)%").monospacedDigit()
                    Image(systemName: a.charging ? "battery.100percent.bolt"
                          : a.percent > 87 ? "battery.100percent" : a.percent > 62 ? "battery.75percent"
                          : a.percent > 37 ? "battery.50percent" : a.percent > 12 ? "battery.25percent" : "battery.0percent")
                        .help(a.charging ? "Charging" : a.wired ? "Connected by cable" : "On battery")
                }
            }
            Divider()
            CrossoverMenuSection {
                MainSelection.shared.selection = "crossover"
                AppDelegate.showMainWindow { openWindow(id: "main") }
            }
            Divider()
            HStack {
                Button("Open MX Control") {
                    AppDelegate.showMainWindow { openWindow(id: "main") }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .help("Settings stay on your devices. Remapped buttons and always-on backlight refresh stop until MX Control opens again.")
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

struct MenuDeviceSection: View {
    @ObservedObject var model: DeviceModel
    @State private var level: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.symbol)
                Text(model.name).bold()
                Spacer()
                if let b = model.state.battery {
                    Text(b.percent.map { "\($0)%" } ?? b.level).monospacedDigit()
                    BatteryIcon(battery: b)
                } else if !model.online {
                    Text("Asleep").foregroundStyle(.secondary)
                }
            }
            if let b = model.state.backlight, b.enabled, b.mode == .manual, b.levelCount > 1 {
                HStack {
                    Image(systemName: "light.min")
                    Slider(value: $level, in: 0...Double(b.levelCount - 1), step: 1) { editing in
                        if !editing { var n = b; n.level = UInt8(level); Task { await model.setBacklight(n) } }
                    }
                    Image(systemName: "light.max")
                }
                .onAppear { level = Double(b.level) }
            }
            if let h = model.state.hosts {
                HStack {
                    Text("Channel").font(.caption).foregroundStyle(.secondary)
                    ForEach(h.slots) { s in
                        Button("\(s.index + 1)") { Task { await model.switchHost(s.index) } }
                            .disabled(s.index == h.current || !s.paired)
                            .help(s.name)
                    }
                }
            }
        }
        .disabled(!model.online)
    }
}
