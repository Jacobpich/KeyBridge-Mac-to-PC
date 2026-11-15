import AppKit
import HIDPP
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DeviceStore.shared.start()
            Crossover.shared.start()
        }

        // Closing the window keeps Keybridge running in the menu bar (no Dock icon) so Crossover
        // keeps working (and, with a Logitech device, settings and remapped buttons keep applying).
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let closing = note.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
                DispatchQueue.main.async {
                    let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
                    if !open { NSApp.setActivationPolicy(.accessory) }
                }
            }
    }

    /// Opens the main window. Set by the menu-bar label, which always exists.
    @MainActor static var openMainWindow: (() -> Void)?

    /// Shows the main window (with a Dock icon while it's open). Closing it goes back to
    /// menu-bar only.
    @MainActor
    static func showMainWindow(_ open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate()
    }

    /// Opening Keybridge again from Finder or Spotlight shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if let open = AppDelegate.openMainWindow { AppDelegate.showMainWindow(open) }
        }
        return false
    }

    /// Give remapped buttons back to the device so they work normally after quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await DeviceStore.shared.releaseAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct KeybridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DeviceStore.shared

    var body: some Scene {
        Window("Keybridge", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 860, height: 620)
        // Start in the menu bar only; the window opens from there.
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keyboard and mouse battery levels side by side, e.g. ⌨ 95%  🖱 85%⚡.
struct MenuBarLabel: View {
    @EnvironmentObject var store: DeviceStore
    @ObservedObject private var crossover = Crossover.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The menu bar flattens a label to plain text and drops inline symbols, so the
        // icons + percentages are drawn into one template image instead.
        let image = rendered
        // A new identity whenever the text changes; otherwise the menu bar keeps the first
        // image it drew (e.g. "–" for a mouse that connected a second after launch).
        Image(nsImage: image)
            .id(image.accessibilityDescription ?? "")
            .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }

    private var rendered: NSImage {
        let renderer = ImageRenderer(content: LabelContent(devices: store.devices,
                                                           accessories: store.accessories.filter { $0.percent != nil },
                                                           onPC: crossover.onPC))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)!
        image.isTemplate = true  // black/white to match the menu bar in light and dark mode
        image.accessibilityDescription = (store.devices.map { d in
            "\(d.name) \(d.state.battery?.percent.map { "\($0)%" } ?? "unknown")"
        } + store.accessories.compactMap { a in a.percent.map { "\(a.name) \($0)%\(a.charging ? " charging" : "")" } })
            .joined(separator: ", ") + (crossover.onPC ? ", controlling the PC" : "")
        return image
    }
}

private struct LabelContent: View {
    let devices: [DeviceModel]
    let accessories: [Accessory]   // the ones with a battery level
    let onPC: Bool

    var body: some View {
        let sorted = devices.sorted { $0.kind.rawValue < $1.kind.rawValue }
        HStack(spacing: 8) {
            if onPC {
                Image(systemName: "arrow.right.square.fill")  // Crossover: input is going to the PC
            }
            if sorted.isEmpty && accessories.isEmpty {
                Image(systemName: "keyboard")   // nothing with a battery to show
            }
            ForEach(sorted) { d in
                HStack(spacing: 3) {
                    Image(systemName: d.symbol)
                    if let b = d.state.battery {
                        Text(b.percent.map { "\($0)%" } ?? b.level)
                        if b.charging == .charging || b.charging == .chargingSlow {
                            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                        }
                    } else if let last = d.lastKnownPercent {
                        Text("\(last)%")  // asleep since launch; last reading
                    } else {
                        Text("–")
                    }
                }
            }
            ForEach(accessories) { a in
                HStack(spacing: 3) {
                    AccessoryIcon(accessory: a)
                    Text("\(a.percent ?? 0)%")
                    if a.charging {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.black)
        .lineLimit(1)
        .fixedSize()  // never truncate the percentages
        .frame(height: 18)
    }
}

// MARK: Main window

/// Lets the menu bar open the main window on a given page.
@MainActor
final class MainSelection: ObservableObject {
    static let shared = MainSelection()
    @Published var selection: String?
}

struct ContentView: View {
    @EnvironmentObject var store: DeviceStore
    @ObservedObject private var main = MainSelection.shared
    private var selection: String? { main.selection }

    var body: some View {
        NavigationSplitView {
            List(selection: $main.selection) {
                if !store.devices.isEmpty || !store.accessories.isEmpty {
                    Section("Devices") {
                        ForEach(store.devices) { d in DeviceRow(model: d).tag(d.id) }
                        ForEach(store.accessories) { a in AccessoryRow(accessory: a).tag("accessory-\(a.id)") }
                    }
                }
                Section("Mac and PC") {
                    Label("Crossover", systemImage: "rectangle.on.rectangle").tag("crossover")
                }
                if !store.receivers.isEmpty {
                    Section("Receivers") {
                        ForEach(store.receivers) { r in
                            Label(r.name, systemImage: "cable.connector").tag("receiver-\(r.id)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button { store.reconnectAll(); store.accessoryMonitor.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Re-read every device")
                }
            }
        } detail: {
            if selection == "crossover" {
                CrossoverSettingsView()
            } else if let id = selection, let d = store.devices.first(where: { $0.id == id }) {
                DeviceDetailView(model: d).id(d.id)
            } else if let id = selection, let r = store.receivers.first(where: { "receiver-\($0.id)" == id }) {
                ReceiverView(receiver: r)
            } else if let id = selection, let a = store.accessories.first(where: { "accessory-\($0.id)" == id }) {
                AccessoryDetailView(accessory: a)
            } else {
                ContentUnavailableView("Pick a device", systemImage: "keyboard")
            }
        }
        // Start on the first device with settings of its own, else on Crossover.
        .onAppear { if main.selection == nil { main.selection = store.devices.first?.id ?? "crossover" } }
        .onChange(of: store.devices.map(\.id)) { _, ids in if main.selection == nil { main.selection = ids.first } }
    }
}

struct DeviceRow: View {
    @ObservedObject var model: DeviceModel
    var body: some View {
        HStack {
            Image(systemName: model.symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                Text(model.online ? (model.state.battery?.summary ?? "Connected") : "Asleep / not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let b = model.state.battery { BatteryIcon(battery: b) }
        }
        .opacity(model.online ? 1 : 0.6)
    }
}

struct AccessoryRow: View {
    let accessory: Accessory
    var body: some View {
        HStack {
            AccessoryIcon(accessory: accessory).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(accessory.name)
                Text(accessory.percent.map { "\($0)%\(accessory.charging ? ", charging" : "")" } ?? accessory.connectionLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let pct = accessory.percent { Image(systemName: batterySymbol(percent: pct, charging: accessory.charging)) }
        }
    }
}

struct BatteryIcon: View {
    let battery: BatteryInfo
    var body: some View {
        let pct = battery.percent ?? 50
        let name = battery.charging == .charging || battery.charging == .chargingSlow ? "battery.100percent.bolt"
            : pct > 87 ? "battery.100percent" : pct > 62 ? "battery.75percent" : pct > 37 ? "battery.50percent"
            : pct > 12 ? "battery.25percent" : "battery.0percent"
        Image(systemName: name)
            .foregroundStyle(pct <= 15 && battery.charging == .discharging ? .red : .primary)
            .help(battery.summary)
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", keyboard = "Keyboard", pointer = "Pointer & Scroll", buttons = "Buttons", connections = "Connections"
    var id: String { rawValue }
}

struct DeviceDetailView: View {
    @ObservedObject var model: DeviceModel
    @State private var tab: DetailTab = .overview

    private var tabs: [DetailTab] {
        DetailTab.allCases.filter { t in
            switch t {
            case .keyboard: model.state.backlight != nil || model.state.fnKeys != nil
            case .pointer: model.state.dpi != nil || model.state.smartShift != nil || model.state.wheel != nil
            case .buttons: !model.state.controls.isEmpty
            default: true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.symbol).font(.system(size: 30)).frame(width: 44)
                VStack(alignment: .leading) {
                    Text(model.name).font(.title2.bold())
                    Text(model.online ? "Connected" : "Asleep or out of range. Press a key or move it to wake it.")
                        .foregroundStyle(model.online ? Color.green : Color.secondary)
                        .font(.callout)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if let b = model.state.battery { BatteryIcon(battery: b).font(.title2) }
            }
            .padding()
            Picker("", selection: $tab) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.top, 6)
            }
            Group {
                switch tab {
                case .overview: OverviewView(model: model)
                case .keyboard: KeyboardView(model: model)
                case .pointer: PointerView(model: model)
                case .buttons: ButtonsView(model: model)
                case .connections: ConnectionsView(model: model)
                }
            }
            .disabled(!model.online && tab != .overview)
        }
    }
}
