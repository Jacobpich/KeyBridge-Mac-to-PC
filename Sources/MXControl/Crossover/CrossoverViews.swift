import AppKit
import SwiftUI

/// Small section in the menu-bar dropdown.
struct CrossoverMenuSection: View {
    @ObservedObject var crossover = Crossover.shared
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "rectangle.on.rectangle")
                Text("Crossover").bold()
                Spacer()
                Toggle("", isOn: $crossover.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(crossover.onPC ? "Controlling the PC (⌃⌥⌘ Esc to come back)" : crossover.status.summary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…", action: openSettings).controlSize(.small)
            }
        }
    }

    private var color: Color {
        switch crossover.status {
        case .linked: crossover.onPC ? .blue : .green
        case .pairing, .confirming: .orange
        case .problem: .red
        default: .secondary
        }
    }
}

/// The Crossover page in the main window.
struct CrossoverSettingsView: View {
    @ObservedObject var crossover = Crossover.shared
    @ObservedObject var setup = Crossover.shared.setupServer

    var body: some View {
        Form {
            Section {
                Toggle("Share this Mac's keyboard, mouse and trackpad with a PC", isOn: $crossover.enabled)
                LabeledContent("Status") {
                    Text(crossover.onPC ? "Controlling the PC" : crossover.status.summary)
                }
                if case .pairing(let code, let pc) = crossover.status {
                    LabeledContent("Code") {
                        HStack {
                            Text(code).font(.title2.monospacedDigit().bold())
                            Button("Pair with \(pc)") { crossover.confirmPairing() }.buttonStyle(.borderedProminent)
                            Button("Cancel") { crossover.cancelPairing() }
                        }
                    }
                }
            } header: { Text("Crossover") } footer: {
                Text("Move the pointer onto the PC's screen to control the PC; push it off the PC's left edge to come back. ⌃⌥⌘ Esc always brings it back. Everything sent to the PC is encrypted.")
            }

            Section("Layout") {
                Picker("PC's screen", selection: $crossover.pcScreenName) {
                    Text("Select a display").tag("")
                    let displays = crossover.screenNames + [crossover.pcScreenName]
                    ForEach(Set(displays.filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Toggle("Keep Mac windows off the PC's screen while linked", isOn: $crossover.guardWindows)
            }

            Section("On the PC") {
                Picker("Modifier keys", selection: $crossover.style) {
                    ForEach(KeyMap.ModifierStyle.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Pointer speed") {
                    HStack { Slider(value: $crossover.pointerSpeed, in: 0.5...2.5); Text(String(format: "%.1f×", crossover.pointerSpeed)).monospacedDigit().frame(width: 40) }
                }
                LabeledContent("Scroll speed") {
                    HStack { Slider(value: $crossover.scrollSpeed, in: 0.25...3); Text(String(format: "%.1f×", crossover.scrollSpeed)).monospacedDigit().frame(width: 40) }
                }
                Toggle("Share the clipboard (text and images)", isOn: $crossover.shareClipboard)
            }

            Section {
                Toggle("Share the PC installer on the network", isOn: Binding(
                    get: { setup.running }, set: { $0 ? setup.start() : setup.stop() }))
                if setup.running {
                    ForEach(setup.addresses, id: \.self) { a in
                        LabeledContent("On the PC, open") { Text(a).textSelection(.enabled).font(.body.monospaced()) }
                    }
                    if PCSetupServer.installerURL == nil {
                        Text("The PC app isn't built into this copy of MX Control yet.").foregroundStyle(.orange)
                    }
                    if setup.downloads > 0 { LabeledContent("Downloads", value: "\(setup.downloads)") }
                }
            } header: { Text("Set up the PC") } footer: {
                Text("Turns itself off after 30 minutes.")
            }

            Section("Paired PCs") {
                if crossover.pairedPCs.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    ForEach(crossover.pairedPCs, id: \.self) { Text($0) }
                    Button("Forget all PCs", role: .destructive) { crossover.forgetPCs() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A floating window asking to confirm the pairing code.
@MainActor
enum PairingPanel {
    private static var panel: NSPanel?

    static func show(code: String, pc: String) {
        close()
        let view = VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 30))
            Text("Pair with \(pc)?").font(.title3.bold())
            Text("Check that the PC shows the same code:").foregroundStyle(.secondary)
            Text(code).font(.system(size: 34, weight: .bold, design: .monospaced))
            HStack {
                Button("Cancel") { Crossover.shared.cancelPairing() }.keyboardShortcut(.cancelAction)
                Button("Pair") { Crossover.shared.confirmPairing() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 320)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "MX Control Crossover"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        p.center()
        p.orderFrontRegardless()
        NSApp.activate()
        p.makeKey()
        panel = p
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}
