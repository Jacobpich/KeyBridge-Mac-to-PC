import AppKit
import HIDPP
import SwiftUI
import UniformTypeIdentifiers

struct ButtonsView: View {
    @ObservedObject var model: DeviceModel
    @EnvironmentObject var store: DeviceStore
    /// nil = all apps; otherwise a bundle ID.
    @State private var profile: String?

    private var controls: [ControlInfo] { model.state.controls.filter(\.isDivertable) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Settings for", selection: $profile) {
                        Text("All apps").tag(String?.none)
                        ForEach(model.config.profiles.perApp.keys.sorted(), id: \.self) { id in
                            Text(appName(id)).tag(String?.some(id))
                        }
                    }
                    Button("Add App…") { addApp() }
                    if let p = profile {
                        Button("Remove") {
                            model.updateProfiles { $0.perApp[p] = nil }
                            profile = nil
                        }
                    }
                }
                if profile != nil {
                    Text("Controls left on \"Same as All apps\" use the All apps setting while this app is in front.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !store.accessibilityTrusted {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Keyboard shortcuts and media keys need Accessibility permission.")
                        Spacer()
                        Button("Allow…") {
                            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                        }
                    }
                }
            }

            Section(model.kind == .keyboard ? "Keys" : "Buttons") {
                ForEach(controls) { control in
                    ControlRow(control: control, mapping: binding(for: control.cid), inheriting: profile != nil)
                }
            }
            Section {
                Text("Remapped controls only work while MX Control is running. Quitting MX Control returns them to normal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for cid: UInt16) -> Binding<ControlMapping?> {
        let key = String(cid, radix: 16)
        return Binding(
            get: {
                if let p = profile { return model.config.profiles.perApp[p]?[key] }
                return model.config.profiles.global[key]
            },
            set: { new in
                model.updateProfiles { profiles in
                    if let p = profile {
                        var app = profiles.perApp[p] ?? [:]
                        app[key] = new
                        profiles.perApp[p] = app
                    } else {
                        profiles.global[key] = new
                    }
                }
            })
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.updateProfiles { if $0.perApp[id] == nil { $0.perApp[id] = [:] } }
        profile = id
    }
}

/// One control: Default / Same as All apps / an action, plus gesture directions when supported.
struct ControlRow: View {
    let control: ControlInfo
    @Binding var mapping: ControlMapping?
    let inheriting: Bool

    private enum Choice: Hashable { case none, gestures, kind(ButtonAction.Kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(control.name, selection: Binding(get: { currentChoice }, set: choose)) {
                Text(inheriting ? "Same as All apps" : "Default (what the device normally does)").tag(Choice.none)
                if control.supportsRawXY { Text("Gestures (hold and move)").tag(Choice.gestures) }
                Divider()
                ForEach(ButtonAction.Kind.allCases) { Text($0.label).tag(Choice.kind($0)) }
            }
            if let m = mapping, m.useGestures {
                ForEach(GestureDirection.allCases) { dir in
                    ActionEditor(title: dir.label, action: Binding(
                        get: { m.gestures[dir] },
                        set: { a in var n = m; n.gestures[dir] = a; mapping = n }))
                        .padding(.leading, 20)
                }
            } else if let a = mapping?.action {
                ActionDetail(action: Binding(get: { a }, set: { mapping = ControlMapping(action: $0) }))
                    .padding(.leading, 20)
            }
        }
    }

    private var currentChoice: Choice {
        guard let m = mapping else { return .none }
        if m.useGestures { return .gestures }
        return m.action.map { .kind($0.kind) } ?? .none
    }

    private func choose(_ c: Choice) {
        switch c {
        case .none: mapping = nil
        case .gestures: mapping = ControlMapping(action: nil, gestures: [.tap: .missionControl], useGestures: true)
        case .kind(let k): mapping = ControlMapping(action: .make(k))
        }
    }
}

/// Picker + details for one gesture direction.
struct ActionEditor: View {
    let title: String
    @Binding var action: ButtonAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: Binding(
                get: { action?.kind },
                set: { k in action = k.map(ButtonAction.make) })) {
                Text("Nothing").tag(ButtonAction.Kind?.none)
                ForEach(ButtonAction.Kind.allCases.filter { $0 != .doNothing }) { Text($0.label).tag(ButtonAction.Kind?.some($0)) }
            }
            if let a = action {
                ActionDetail(action: Binding(get: { a }, set: { action = $0 })).padding(.leading, 20)
            }
        }
    }
}

/// The extra field an action needs (shortcut, app, URL, command).
struct ActionDetail: View {
    @Binding var action: ButtonAction
    @State private var text = ""

    var body: some View {
        switch action {
        case .keystroke(let combo):
            LabeledContent("Shortcut") {
                ShortcutRecorder(combo: combo) { action = .keystroke($0) }.frame(width: 160, height: 24)
            }
        case .openApp(let path):
            LabeledContent("App") {
                HStack {
                    Text(path.isEmpty ? "None chosen" : FileManager.default.displayName(atPath: path)).foregroundStyle(.secondary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        if panel.runModal() == .OK, let url = panel.url { action = .openApp(path: url.path) }
                    }
                }
            }
        case .openURL(let url):
            TextField("URL", text: Binding(get: { url }, set: { action = .openURL($0) }))
        case .shell(let command):
            TextField("Command (runs in zsh)", text: Binding(get: { command }, set: { action = .shell($0) }))
                .font(.system(.body, design: .monospaced))
        default:
            EmptyView()
        }
    }
}

/// Click, then press a key combination to record it.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onChange = onChange
        b.combo = combo
        return b
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = onChange
        if !view.recording { view.combo = combo }
    }

    final class RecorderButton: NSButton {
        var onChange: ((KeyCombo) -> Void)?
        var combo: KeyCombo? { didSet { refresh() } }
        private(set) var recording = false
        private var monitor: Any?

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(toggle)
        }
        required init?(coder: NSCoder) { fatalError() }

        private func refresh() { title = recording ? "Type shortcut…" : (combo?.label ?? "Record shortcut") }

        @objc private func toggle() {
            recording ? stop() : start()
        }

        private func start() {
            recording = true
            refresh()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                if e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { self.stop(); return nil }
                let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
                let new = KeyCombo(keyCode: e.keyCode, modifiers: mods.rawValue)
                self.combo = new
                self.onChange?(new)
                self.stop()
                return nil
            }
        }

        private func stop() {
            recording = false
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            refresh()
        }
    }
}
