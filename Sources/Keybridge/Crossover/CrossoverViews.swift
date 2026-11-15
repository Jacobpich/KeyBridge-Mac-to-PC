import AppKit
import SwiftUI

/// Small section in the menu-bar dropdown.
struct CrossoverMenuSection: View {
    @ObservedObject var crossover = Crossover.shared
    var openSettings: () -> Void
    @AppStorage("crossover.showArrangement") private var showArrangement = false

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
            if crossover.needsAccessibility {
                Button("Allow in Accessibility settings…") { crossover.askForAccessibility(force: true) }.controlSize(.small)
            }
            if crossover.enabled {
                DisclosureGroup(isExpanded: $showArrangement) {
                    ArrangementView(height: 110).padding(.top, 4)
                } label: {
                    Text("Arrange screens").font(.caption)
                }
                if crossover.pcNeedsUpdate { UpdatePCNote() }
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
                if crossover.needsAccessibility {
                    Button("Allow in Accessibility settings…") { crossover.askForAccessibility(force: true) }
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
                Text("Move the pointer onto the PC's screen to control the PC, and back the way it came to return. ⌃⌥⌘ Esc always brings it back. Everything sent to the PC is encrypted.")
            }
            if crossover.pcNeedsUpdate {
                Section { UpdatePCNote() }
            }

            Section {
                ArrangementView(height: 200)
                Picker("PC's monitor is also plugged into this Mac", selection: $crossover.pcScreenName) {
                    Text("No").tag("")
                    ForEach(Array(Set(crossover.screenNames + [crossover.pcScreenName].filter { !$0.isEmpty })).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                if !crossover.pcScreenName.isEmpty {
                    Toggle("Keep Mac windows off that monitor while linked", isOn: $crossover.guardWindows)
                }
            } header: { Text("Arrangement") } footer: {
                Text("If one monitor is connected to both computers, pick it so Keybridge follows its place in System Settings → Displays.")
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
                Toggle("Share the clipboard (text, images and files)", isOn: $crossover.shareClipboard)
            }

            Section {
                Toggle("Share the PC installer on the network", isOn: Binding(
                    get: { setup.running }, set: { $0 ? setup.start() : setup.stop() }))
                if setup.running {
                    ForEach(setup.addresses, id: \.self) { a in
                        LabeledContent("On the PC, open") { Text(a).textSelection(.enabled).font(.body.monospaced()) }
                    }
                    if PCSetupServer.installerURL == nil {
                        Text("The PC app isn't built into this copy of Keybridge yet.").foregroundStyle(.orange)
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
        p.title = "Keybridge Crossover"
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

/// Drag the PC's screen to where it sits next to the Mac's, like Displays → Arrange. It snaps to
/// the nearest side of a Mac screen.
struct ArrangementView: View {
    @ObservedObject var crossover = Crossover.shared
    var height: CGFloat

    @State private var dragStart: CGRect?      // the PC's rect when the drag began
    @State private var freeRect: CGRect?       // where the pointer is carrying it
    @State private var snapped: PCPlacement?   // where it will land
    @State private var frozenBounds: CGRect?   // the view doesn't rescale mid-drag

    private var macs: [MacDisplay] {
        Arrangement.displays().filter { crossover.layout.attached.isNull || $0.frame != crossover.layout.attached }
    }

    var body: some View {
        let layout = crossover.layout
        let macs = self.macs
        VStack(alignment: .leading, spacing: 6) {
            if !layout.isValid || macs.isEmpty {
                Text("No screens found.").foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    let bounds = frozenBounds ?? Self.bounds(macs: macs, pc: layout.pc)
                    let scale = min(geo.size.width / bounds.width, geo.size.height / bounds.height)
                    let inset = CGPoint(x: (geo.size.width - bounds.width * scale) / 2,
                                        y: (geo.size.height - bounds.height * scale) / 2)
                    let map = { (r: CGRect) -> CGRect in
                        CGRect(x: inset.x + (r.minX - bounds.minX) * scale, y: inset.y + (r.minY - bounds.minY) * scale,
                               width: r.width * scale, height: r.height * scale)
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(macs, id: \.id) { d in
                            screen(map(d.frame), title: d.name, symbol: "display", tint: .secondary)
                        }
                        if let snapped, let target = rect(for: snapped, macs: macs) {
                            let r = map(target)
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        }
                        let pcRect = map(freeRect ?? layout.pc)
                        screen(pcRect, title: crossover.linkedPCName ?? "PC", symbol: "pc", tint: .accentColor)
                            .opacity(freeRect == nil ? 1 : 0.85)
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { g in
                                        if dragStart == nil {
                                            dragStart = layout.pc
                                            frozenBounds = bounds
                                        }
                                        guard let start = dragStart else { return }
                                        let moved = start.offsetBy(dx: g.translation.width / scale, dy: g.translation.height / scale)
                                        freeRect = moved
                                        snapped = Self.snap(moved, macs: macs)
                                    }
                                    .onEnded { _ in
                                        if let snapped { crossover.setPlacement(snapped) }
                                        dragStart = nil; freeRect = nil; snapped = nil; frozenBounds = nil
                                    }
                            )
                            .help("Drag to where the PC's screen is")
                    }
                }
                .frame(height: height)
                Text(description(layout)).font(.caption).foregroundStyle(.secondary)
                if crossover.pcNeedsUpdate && layout.side != .right {
                    Text("Update Keybridge on the PC to use this side; until then, it only works to the right.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func screen(_ r: CGRect, title: String, symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.7), lineWidth: 1))
            .overlay(
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: 10))
                    if r.height > 34 { Text(title).font(.system(size: 9)).lineLimit(1).truncationMode(.middle) }
                }
                .padding(.horizontal, 3)
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
            )
            .frame(width: max(r.width, 4), height: max(r.height, 4))
            .position(x: r.midX, y: r.midY)
    }

    private func description(_ layout: CrossoverLayout) -> String {
        let name = macs.first { $0.frame == layout.mac }?.name ?? "the Mac's screen"
        let side: String = switch layout.side {
        case .right: "to the right of"
        case .left: "to the left of"
        case .above: "above"
        case .below: "below"
        }
        let how = layout.attached.isNull ? "Drag it to change." : "Drag it to change (this also moves it in System Settings → Displays)."
        return "The PC is \(side) \(name). \(how)"
    }

    private func rect(for p: PCPlacement, macs: [MacDisplay]) -> CGRect? {
        guard let anchor = macs.first(where: { $0.name == p.display }) else { return nil }
        return Arrangement.pcRect(p, against: anchor.frame, size: crossover.layout.pc.size)
    }

    /// Room for the PC on every side of the Mac's screens.
    private static func bounds(macs: [MacDisplay], pc: CGRect) -> CGRect {
        let all = macs.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return all.insetBy(dx: -pc.width * 0.85, dy: -pc.height * 0.85).union(pc).insetBy(dx: -40, dy: -40)
    }

    /// The placement nearest to where the PC was dragged: against some side of some Mac screen,
    /// not covering another one.
    static func snap(_ r: CGRect, macs: [MacDisplay]) -> PCPlacement? {
        var best: (PCPlacement, CGFloat)?
        for d in macs {
            for side in PCPlacement.Side.allCases {
                let raw = side.isHorizontal ? r.minY - d.frame.minY : r.minX - d.frame.minX
                let offset = Arrangement.clampOffset(raw, side: side, mac: d.frame, size: r.size)
                let p = PCPlacement(display: d.name, side: side, offset: Double(offset))
                let candidate = Arrangement.pcRect(p, against: d.frame, size: r.size)
                let blocked = macs.contains { o in
                    o.id != d.id && o.frame.intersection(candidate).width > 1 && o.frame.intersection(candidate).height > 1
                }
                if blocked { continue }
                let dist = hypot(candidate.midX - r.midX, candidate.midY - r.midY)
                if best == nil || dist < best!.1 { best = (p, dist) }
            }
        }
        return best?.0
    }
}

/// The linked PC runs an older Keybridge: say so, and offer the installer.
struct UpdatePCNote: View {
    @ObservedObject var setup = Crossover.shared.setupServer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("The PC needs the new Keybridge for dragging and copying files.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            if setup.running, let address = setup.addresses.first {
                Text("On the PC, open \(address)").font(.caption.monospaced()).textSelection(.enabled)
            } else {
                Button("Share the PC installer") { setup.start() }.controlSize(.small)
            }
        }
    }
}
