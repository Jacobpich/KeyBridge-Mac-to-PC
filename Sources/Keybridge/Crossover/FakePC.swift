import Foundation
import Network

/// `Keybridge --fake-pc` — a stand-in for the Windows companion, for testing Crossover on the Mac.
/// It connects to Keybridge, pairs, logs every message, and tracks a pretend PC screen: when the
/// pointer is pushed past the edge facing the Mac it sends `returned`, like the real PC app does.
///
///   --host 127.0.0.1      Mac to connect to (default: this Mac)
///   --state <file>        where to keep its identity and pinned Mac key (default: a temp file)
///   --auto-confirm        confirm the pairing code on this side automatically
///   --screen 2560x1440    the pretend screen
///   --seconds 60          quit after this long
///   --old                 act like a PC app from before file sharing (no feature bits)
/// Commands on stdin: `return <0-1>`, `clip <text>`, `quit`.
@MainActor
enum FakePC {
    static func run() {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let host = value("--host") ?? "127.0.0.1"
        let statePath = value("--state") ?? NSTemporaryDirectory() + "keybridge-fake-pc.json"
        let autoConfirm = args.contains("--auto-confirm")
        let size = (value("--screen") ?? "2560x1440").split(separator: "x").compactMap { UInt16($0) }
        let (width, height) = size.count == 2 ? (size[0], size[1]) : (2560, 1440)
        let seconds = Double(value("--seconds") ?? "") ?? 3600

        let store = FilePins(path: statePath)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Wire.tcpPort)!,
                                      using: { let t = NWProtocolTCP.Options(); t.noDelay = true; return NWParameters(tls: nil, tcp: t) }())
        let session = CrossoverSession(role: .pc, identity: store.identity, pins: store, connection: connection)
        session.screenSize = (width, height)
        if args.contains("--old") { session.features = 0 }
        var x = 0.0, y = 0.0, active = false
        var edge: UInt8 = 0   // the edge facing the Mac: 0 left, 1 right, 2 top, 3 bottom
        var moves = 0

        func log(_ s: String) { print("[fake-pc] \(s)"); fflush(stdout) }

        session.onState = { state in
            log("state: \(state)")
            if case .pairing(let code) = state {
                log("pairing code \(code)")
                if autoConfirm { session.confirmPairing() }
            }
            if case .closed = state { exit(0) }
        }
        session.onMessage = { m in
            switch m {
            case .enter(let fx, let fy):
                x = Double(fx) * Double(width); y = Double(fy) * Double(height); active = true; moves = 0
                log(String(format: "enter at %.0f,%.0f", x, y))
            case .layout(let e):
                edge = e; log("layout: edge \(e)")
            case .move(let dx, let dy):
                guard active else { return }
                x += Double(dx); y += Double(dy)
                moves += 1
                if moves % 25 == 1 { log(String(format: "pointer %.0f,%.0f", x, y)) }
                let (w, h) = (Double(width - 1), Double(height - 1))
                let past = switch edge { case 1: x > w; case 2: y < 0; case 3: y > h; default: x < 0 }
                x = min(max(x, 0), w); y = min(max(y, 0), h)
                if past {
                    active = false
                    let along = edge >= 2 ? x / w : y / h
                    log(String(format: "edge %d at %.2f → returned", edge, along))
                    session.send(.returned(y: Float(along)))
                }
            case .clipboard(let kind, let data):
                log(kind == 1 ? "clipboard text: \(String(decoding: data.prefix(80), as: UTF8.self))" : "clipboard image: \(data.count) bytes")
            case .leave: active = false; log("leave")
            default: log("\(m)")
            }
        }
        session.start()
        log("connecting to \(host):\(Wire.tcpPort) as \(store.identity.name), screen \(width)x\(height)")

        Thread.detachNewThread {
            while let line = readLine() {
                DispatchQueue.main.async {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    switch parts.first {
                    case "return":
                        let fy = Float(parts.count > 1 ? parts[1] : "0.5") ?? 0.5
                        active = false
                        session.send(.returned(y: fy)); log("sent returned \(fy)")
                    case "clip":
                        session.send(.clipboard(kind: 1, data: Data((parts.count > 1 ? parts[1] : "").utf8))); log("sent clipboard")
                    case "quit": exit(0)
                    default: break
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        RunLoop.main.run()
    }
}

/// The fake PC's identity and pinned Mac, in a JSON file.
final class FilePins: CrossoverPins {
    let path: String
    private var json: [String: String]
    let identity: CrossoverIdentity

    init(path: String) {
        self.path = path
        json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: String] ?? [:]
        if let stored = json["identity"].flatMap({ Data(base64Encoded: $0) }),
           let id = CrossoverIdentity(stored: stored, name: "Fake PC") {
            identity = id
        } else {
            identity = CrossoverIdentity.make(name: "Fake PC")
            json["identity"] = identity.stored.base64EncodedString()
        }
        save()
    }

    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: json) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    func key(for peerID: Data) -> Data? { json["peer." + peerID.hex].flatMap { Data(base64Encoded: $0) } }
    func pin(peerID: Data, name: String, key: Data) { json["peer." + peerID.hex] = key.base64EncodedString(); save() }
    var anyPinnedKey: Data? { json.first { $0.key.hasPrefix("peer.") }.flatMap { Data(base64Encoded: $0.value) } }
}
