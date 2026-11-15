import AppKit
import Combine
import Network
import Security

/// Crossover: share this Mac's keyboard, mouse and trackpad with a Windows PC whose screen sits
/// next to the Mac's. Runs the listener the PC connects to, the event tap,
/// clipboard sync and the window guard.
@MainActor
final class Crossover: ObservableObject {
    static let shared = Crossover()

    enum Status: Equatable {
        case off
        case waiting                        // listening, no PC connected
        case pairing(code: String, pc: String)
        case confirming(pc: String)         // this Mac confirmed; waiting for the PC's user
        case linked(pc: String)
        case problem(String)

        var summary: String {
            switch self {
            case .off: "Off"
            case .waiting: "Waiting for the PC"
            case .pairing(_, let pc): "Pair with \(pc)?"
            case .confirming(let pc): "Confirm the code on \(pc)"
            case .linked(let pc): "Linked to \(pc)"
            case .problem(let p): p
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var onPC = false
    @Published private(set) var pairedPCs: [String] = []
    /// Files the PC is dragging toward the Mac (offered just before control comes back).
    private var dragFromPC: Incoming?
    /// The drag pasteboard's count when the button went down, to tell a new drag from an old one.
    private var dragCountAtDown = -1

    @Published var enabled: Bool { didSet { save("enabled", enabled); restart() } }
    @Published var pcScreenName: String { didSet { save("screen", pcScreenName); configure() } }
    @Published var style: KeyMap.ModifierStyle { didSet { save("style", style.rawValue); configure() } }
    @Published var pointerSpeed: Double { didSet { save("pointerSpeed", pointerSpeed); configure() } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed); configure() } }
    @Published var shareClipboard: Bool { didSet { save("clipboard", shareClipboard) } }
    @Published var guardWindows: Bool { didSet { save("guardWindows", guardWindows); configure() } }

    let setupServer = PCSetupServer()

    private let capture = InputCapture()
    private let clipboard = ClipboardBridge()
    private let transfers = FileTransfers()
    /// Copied files bigger than this stay put (dragged files have no limit).
    static let clipboardFileLimit: UInt64 = 2 << 30
    private let windowGuard = WindowGuard()
    private let pins = MacPins()
    private var listener: NWListener?
    private var discovery: DiscoveryResponder?
    private var session: CrossoverSession?
    private var screenObserver: NSObjectProtocol?
    private lazy var identity: CrossoverIdentity = Self.loadIdentity()

    private init() {
        let d = UserDefaults.standard
        func key(_ k: String) -> String { "crossover." + k }
        enabled = d.object(forKey: key("enabled")) as? Bool ?? true
        pcScreenName = d.string(forKey: key("screen")) ?? ""
        style = KeyMap.ModifierStyle(rawValue: d.string(forKey: key("style")) ?? "") ?? .commandIsCtrl
        pointerSpeed = d.object(forKey: key("pointerSpeed")) as? Double ?? 1
        scrollSpeed = d.object(forKey: key("scrollSpeed")) as? Double ?? 1
        shareClipboard = d.object(forKey: key("clipboard")) as? Bool ?? true
        guardWindows = d.object(forKey: key("guardWindows")) as? Bool ?? true
        pairedPCs = pins.names

        transfers.send = { [weak self] m, done in self?.session?.sendBulk(m, done: done) ?? false }
        transfers.onOffer = { [weak self] i in self?.offered(i) }
        capture.onMouseDown = { [weak self] in
            MainActor.assumeIsolated { self?.dragCountAtDown = NSPasteboard(name: .drag).changeCount }
        }
        capture.onDragAtEdge = { [weak self] in MainActor.assumeIsolated { self?.dragAtEdge() } }
        capture.onEntered = { [weak self] point in MainActor.assumeIsolated { self?.entered(point) } }
        capture.onEmergencyReturn = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.onPC else { return }
                self.onPC = false
                CrossoverLog.write("control → Mac (⌃⌥⌘ Esc)")
            }
        }
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "crossover." + key) }

    var screenNames: [String] { InputCapture.quartzFrames().map(\.name) }
    var macName: String { identity.name }

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configure() }
            }
        restart()
    }

    private func restart() {
        session?.close("Crossover restarted")
        session = nil
        listener?.cancel(); listener = nil
        discovery = nil
        returnToMac(at: nil, tellPC: false)
        capture.disable()
        windowGuard.stop()
        guard enabled else { status = .off; return }
        startListening()
        // First-time setup: share the PC installer until a PC is paired (or for 30 minutes).
        if pins.names.isEmpty, PCSetupServer.installerURL != nil { setupServer.start() }
    }

    // MARK: Network

    private func startListening() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Wire.tcpPort)!)
            l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] s in
                MainActor.assumeIsolated {
                    if case .failed(let e) = s { self?.status = .problem("Can't listen on port \(Wire.tcpPort): \(e)") }
                }
            }
            l.start(queue: .main)
            listener = l
            status = .waiting
            CrossoverLog.write("listening on TCP \(Wire.tcpPort)")
        } catch {
            status = .problem("Can't listen on port \(Wire.tcpPort): \(error)")
        }
        startDiscovery()
    }

    /// Answers the PC's "where is the Mac?" broadcast on UDP 47821.
    private func startDiscovery() {
        var w = ByteWriter()
        w.raw(Data("MXC1!".utf8)); w.u16(Wire.tcpPort); w.string(identity.name)
        discovery = DiscoveryResponder(reply: w.data)
    }

    private func accept(_ connection: NWConnection) {
        CrossoverLog.write("connection from \(connection.endpoint)")
        // A new connection from the PC replaces the old one (the PC may have restarted).
        if let old = session { old.onState = nil; old.close("replaced") ; lost() }
        let s = CrossoverSession(role: .mac, identity: identity, pins: pins, connection: connection)
        s.onState = { [weak self, weak s] state in
            guard let self, let s, self.session === s else { return }
            self.sessionState(state, s)
        }
        s.onMessage = { [weak self] m in self?.received(m) }
        session = s
        s.start()
    }

    private func sessionState(_ state: CrossoverSession.State, _ s: CrossoverSession) {
        CrossoverLog.write("session with \(s.peerName): \(state)")
        switch state {
        case .handshaking: break
        case .pairing(let code):
            status = .pairing(code: code, pc: s.peerName)
            PairingPanel.show(code: code, pc: s.peerName)
        case .waitingForPeer:
            status = .confirming(pc: s.peerName)
            PairingPanel.close()
        case .trusted:
            PairingPanel.close()
            setupServer.stop()
            pairedPCs = pins.names
            status = .linked(pc: s.peerName)
            capture.setSink(s)
            configure()
        case .closed:
            PairingPanel.close()
            session = nil
            lost()
        }
    }

    private func lost() {
        capture.setSink(nil)
        dragFromPC = nil
        transfers.reset()
        returnToMac(at: nil, tellPC: false)
        capture.disable()
        windowGuard.stop()
        if enabled, listener != nil { status = .waiting }
    }

    func confirmPairing() { session?.confirmPairing() }
    func cancelPairing() { session?.close("pairing cancelled") }

    func forgetPCs() {
        pins.removeAll()
        pairedPCs = []
        session?.close("forgotten")
    }

    // MARK: Crossing

    /// Applies the settings (and the PC screen's current position) to the capture.
    private func configure() {
        let pc = InputCapture.quartzFrames().first { $0.name == pcScreenName }?.frame ?? .null
        windowGuard.pcScreen = pc
        let pcPixels = CGFloat(session?.screenSize.0 ?? 0)
        let scale = (pcPixels > 0 && !pc.isNull ? pcPixels / pc.width : 1) * pointerSpeed
        let (scroll, style) = (scrollSpeed, style)
        capture.update { c in
            c.pcScreen = pc
            c.pointerScale = scale
            c.scrollSpeed = scroll
            c.style = style
        }
        guard let session, session.state == .trusted else { return }
        if pc.isNull {
            returnToMac(at: nil, tellPC: true)
            capture.disable()
            windowGuard.stop()
            status = .problem(pcScreenName.isEmpty ? "Choose the PC’s display in Crossover settings" : "\(pcScreenName) isn’t connected to this Mac")
            return
        }
        if !capture.isEnabled && !capture.enable() {
            status = .problem("Needs Accessibility permission")
            return
        }
        status = .linked(pc: session.peerName)
        if guardWindows { windowGuard.start() } else { windowGuard.stop() }
    }

    /// The input thread already handed control to the PC; this catches up the rest.
    private func entered(_ point: CGPoint) {
        guard capture.onPC else { return }   // already back
        guard let session, session.state == .trusted else { capture.leavePC(at: nil); return }
        onPC = true
        // After the enter, so a big clipboard can't hold up the pointer.
        sendClipboard()
        CrossoverLog.write(String(format: "control → PC (entered at %.2f, %.2f)", point.x, point.y))
    }

    private func returnToMac(at y: CGFloat?, tellPC: Bool) {
        if tellPC { session?.send(.leave) }
        let wasOnPC = capture.leavePC(at: y)
        if let drag = dragFromPC {
            // The PC is dragging files across: carry on the drag here (only if it came off the edge).
            dragFromPC = nil
            if y != nil { startDragFromPC(drag) } else { endDragFromPC(drag, dropped: false) }
        }
        if onPC || wasOnPC { CrossoverLog.write(tellPC ? "control → Mac (⌃⌥⌘ Esc)" : y == nil ? "control → Mac (link lost)" : "control → Mac (PC's left edge)") }
        onPC = false
    }

    // MARK: Dragging files across

    /// Something is being dragged into the PC's screen. If it's files from Finder, send them and
    /// carry the drag over; the drop happens wherever the button comes up on the PC.
    private func dragAtEdge() {
        let pb = NSPasteboard(name: .drag)
        guard let session, session.state == .trusted, pb.changeCount != dragCountAtDown,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, let id = transfers.send(urls, purpose: .drag)
        else { capture.dragCheckDone(crossed: false); return }
        guard capture.enterPCWithDrag() else {
            transfers.cancelOutgoing(id)
            capture.dragCheckDone(crossed: false)
            return
        }
        // The Mac's own drag is still going, now over a screen nobody's looking at: cancel it, so
        // letting go on the PC can't also drop the files somewhere on the Mac.
        InputCapture.postKey(53) // Esc
        CrossoverLog.write("drag to PC: \(urls.count) item(s)")
    }

    private func startDragFromPC(_ incoming: Incoming) {
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            endDragFromPC(incoming, dropped: false)
            return
        }
        MacDragSource.begin(incoming) { [weak self] dropped in self?.endDragFromPC(incoming, dropped: dropped) }
    }

    /// Lets the PC finish its side of the drag, and stops the transfer if nothing was dropped.
    private func endDragFromPC(_ incoming: Incoming, dropped: Bool) {
        session?.send(.dragEnded(id: incoming.id, dropped: dropped))
        if !dropped { transfers.cancelIncoming(incoming.id) }
    }

    /// Sends what was copied on the Mac, if it changed: text and images directly, files as a transfer.
    private func sendClipboard() {
        guard shareClipboard, let session, let payload = clipboard.payloadIfChanged() else { return }
        switch payload {
        case .data(let kind, let data): session.send(.clipboard(kind: kind, data: data))
        case .files(let urls): transfers.send(urls, purpose: .clipboard, maxBytes: Self.clipboardFileLimit)
        }
    }

    /// Files are on their way from the PC.
    private func offered(_ incoming: Incoming) {
        switch incoming.purpose {
        case .clipboard:
            let since = clipboard.changeCount
            incoming.whenDone { [weak self] ok in
                guard ok, let self, self.shareClipboard else { return }
                self.clipboard.writeFiles(incoming.topLevel, ifUnchangedSince: since)
            }
        case .drag:
            dragFromPC = incoming
        }
    }

    private func received(_ m: WireMessage) {
        switch m {
        case .filesOffer, .fileData, .filesDone, .filesCancel: transfers.received(m)
        case .returned(let y): returnToMac(at: CGFloat(y), tellPC: false)
        case .clipboard(let kind, let data): if shareClipboard { clipboard.write(kind: kind, data: data) }
        case .screen: configure()
        default: break
        }
    }

    // MARK: Remapped buttons while on the PC

    /// Sends a remapped button's action to the PC. Returns false for actions that only make
    /// sense on the Mac (open app, URL, shell), which then run on the Mac as usual.
    func performRemote(_ action: ButtonAction) -> Bool {
        guard onPC, let session else { return false }
        func tap(_ mods: [KeyMap.WinKey], _ key: KeyMap.WinKey) {
            for m in mods { session.send(.key(scan: m.scan, extended: m.extended, down: true)) }
            session.send(.key(scan: key.scan, extended: key.extended, down: true))
            session.send(.key(scan: key.scan, extended: key.extended, down: false))
            for m in mods.reversed() { session.send(.key(scan: m.scan, extended: m.extended, down: false)) }
        }
        func vkey(_ vk: UInt16) { session.send(.vkey(vk, down: true)); session.send(.vkey(vk, down: false)) }
        func click(_ button: UInt8) { session.send(.button(button, down: true)); session.send(.button(button, down: false)) }
        let win = KeyMap.lWin
        switch action {
        case .keystroke(let k):
            if let vk = KeyMap.volumeKeys[Int(k.keyCode)] { vkey(vk); return true }
            guard let key = KeyMap.key(Int(k.keyCode)) else { return true }
            var flags: CGEventFlags = []
            if k.flags.contains(.command) { flags.insert(.maskCommand) }
            if k.flags.contains(.option) { flags.insert(.maskAlternate) }
            if k.flags.contains(.shift) { flags.insert(.maskShift) }
            if k.flags.contains(.control) { flags.insert(.maskControl) }
            tap(KeyMap.modifiers(for: flags, style: style), key)
        case .missionControl, .appExpose: tap([win], KeyMap.tab)
        case .showDesktop: tap([win], KeyMap.letterD)
        case .apps, .spotlight:
            session.send(.key(scan: win.scan, extended: true, down: true))
            session.send(.key(scan: win.scan, extended: true, down: false))
        case .playPause: vkey(0xB3)
        case .nextTrack: vkey(0xB0)
        case .previousTrack: vkey(0xB1)
        case .volumeUp: vkey(0xAF)
        case .volumeDown: vkey(0xAE)
        case .mute: vkey(0xAD)
        case .back: click(3)
        case .forward: click(4)
        case .openApp, .openURL, .shell: return false
        case .doNothing: break
        }
        return true
    }

    // MARK: Identity (Keychain)

    private static let service = "app.mxcontrol.Crossover.pairing"

    private static func loadIdentity() -> CrossoverIdentity {
        let name = Host.current().localizedName ?? "Mac"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "mac-identity", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let id = CrossoverIdentity(stored: data, name: name) { return id }
        let id = CrossoverIdentity.make(name: name)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "mac-identity", kSecValueData as String: id.stored,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        return id
    }
}

/// Paired PCs, kept in UserDefaults (public keys only).
final class MacPins: CrossoverPins {
    private let key = "crossover.pairedPCs"
    private var all: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    var names: [String] { all.values.compactMap { $0["name"] }.sorted() }
    func key(for peerID: Data) -> Data? { all[peerID.hex]?["key"].flatMap { Data(base64Encoded: $0) } }
    func pin(peerID: Data, name: String, key: Data) { all[peerID.hex] = ["name": name, "key": key.base64EncodedString()] }
    var anyPinnedKey: Data? { all.values.first?["key"].flatMap { Data(base64Encoded: $0) } }
    func removeAll() { all = [:] }
}
