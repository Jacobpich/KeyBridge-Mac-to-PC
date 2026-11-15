import CryptoKit
import Foundation
import Network
import Security

/// This side's long-term identity.
struct CrossoverIdentity {
    let id: Data   // 16 bytes
    let name: String
    let key: P256.KeyAgreement.PrivateKey
    var publicKey: Data { key.publicKey.x963Representation }

    static func make(name: String) -> CrossoverIdentity {
        var id = Data(count: 16)
        _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return CrossoverIdentity(id: id, name: name, key: P256.KeyAgreement.PrivateKey())
    }

    /// 16-byte id + 32-byte raw private key.
    var stored: Data { id + key.rawRepresentation }

    init(id: Data, name: String, key: P256.KeyAgreement.PrivateKey) { self.id = id; self.name = name; self.key = key }

    init?(stored: Data, name: String) {
        guard stored.count == 48, let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored.suffix(32)) else { return nil }
        self.init(id: stored.prefix(16), name: name, key: key)
    }
}

/// Paired peers: their id → static public key.
protocol CrossoverPins: AnyObject {
    func key(for peerID: Data) -> Data?
    func pin(peerID: Data, name: String, key: Data)
    /// Any pinned key, so a side can say "I know you" before it has seen the peer's id.
    var anyPinnedKey: Data? { get }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// One encrypted Crossover connection, used by both the Mac (server) and the PC side
/// (`--fake-pc` here, the Windows app in C#).
@MainActor
final class CrossoverSession {
    enum State: Equatable { case handshaking, pairing(code: String), waitingForPeer, trusted, closed(String) }

    let role: WireHello.Role
    let identity: CrossoverIdentity
    let pins: CrossoverPins
    let connection: NWConnection
    /// PC side: its screen size in pixels, sent in the hello.
    var screenSize: (UInt16, UInt16) = (0, 0)

    private(set) var state: State = .handshaking {
        didSet {
            guard state != oldValue else { return }
            sendLock.lock(); inputOpen = state == .trusted; sendLock.unlock()
            onState?(state)
        }
    }
    private(set) var peer: WireHello?
    var peerName: String { peer?.name ?? "PC" }

    var onState: ((State) -> Void)?
    var onMessage: ((WireMessage) -> Void)?

    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private var myHello = Data()
    // The send side is shared with the input thread (`sendInput`), so it sits behind a lock.
    private let sendLock = NSLock()
    nonisolated(unsafe) private var sendKey: SymmetricKey?
    nonisolated(unsafe) private var sendCounter: UInt64 = 0
    nonisolated(unsafe) private var inputOpen = false
    private var receiveKey: SymmetricKey?
    private var receiveCounter: UInt64 = 0
    private var buffer = Data()
    private var localTrust = false   // I have the peer's key pinned (or my user just confirmed it)
    private var remoteTrust = false  // the peer has my key pinned (or its user just confirmed)
    private var lastHeard = Date()
    private var heartbeat: Timer?

    init(role: WireHello.Role, identity: CrossoverIdentity, pins: CrossoverPins, connection: NWConnection) {
        self.role = role
        self.identity = identity
        self.pins = pins
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch s {
                case .ready: self.sendHello()
                case .failed(let e): self.close("connection failed: \(e)")
                case .cancelled: self.close("connection closed")
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func close(_ reason: String) {
        if case .closed = state { return }
        heartbeat?.invalidate(); heartbeat = nil
        connection.cancel()
        state = .closed(reason)
    }

    /// The user checked that both screens show the same code.
    func confirmPairing() {
        guard case .pairing = state, let peer else { return }
        pins.pin(peerID: peer.id, name: peer.name, key: peer.staticKey)
        localTrust = true
        send(.pairConfirm, force: true)
        updateTrust()
    }

    func send(_ message: WireMessage) { send(message, force: false) }

    private func send(_ message: WireMessage, force: Bool) {
        sendLock.lock(); defer { sendLock.unlock() }
        guard force || inputOpen else { return }
        sealAndWrite(message)
    }

    /// Sends from any thread (the event tap's). Does nothing unless the link is trusted.
    nonisolated func sendInput(_ message: WireMessage) {
        sendLock.lock(); defer { sendLock.unlock() }
        guard inputOpen else { return }
        sealAndWrite(message)
    }

    /// Sends file data: `done` runs once the connection has taken it, so the sender can keep only
    /// a few chunks queued ahead of the pointer and keys. Returns false if the link isn't up.
    nonisolated func sendBulk(_ message: WireMessage, done: (@Sendable () -> Void)?) -> Bool {
        sendLock.lock(); defer { sendLock.unlock() }
        guard inputOpen else { return false }
        return sealAndWrite(message, done: done)
    }

    /// Call with `sendLock` held, so frames go out in counter order.
    @discardableResult
    nonisolated private func sealAndWrite(_ message: WireMessage, done: (@Sendable () -> Void)? = nil) -> Bool {
        guard let sendKey, let body = try? WireCrypto.seal(message.encode(), key: sendKey, counter: sendCounter) else { return false }
        sendCounter += 1
        Self.write(body, to: connection, done: done)
        return true
    }

    // MARK: Internals

    private func write(_ body: Data) { Self.write(body, to: connection) }

    nonisolated private static func write(_ body: Data, to connection: NWConnection, done: (@Sendable () -> Void)? = nil) {
        var w = ByteWriter(); w.u32(UInt32(body.count)); w.raw(body)
        connection.send(content: w.data, completion: .contentProcessed { _ in done?() })
    }

    private func sendHello() {
        let pinned = pins.anyPinnedKey.map(WireCrypto.fingerprint) ?? Data(count: 32)
        let hello = WireHello(role: role, id: identity.id, name: identity.name, staticKey: identity.publicKey,
                              ephemeralKey: ephemeral.publicKey.x963Representation, peerFingerprint: pinned,
                              screenWidth: screenSize.0, screenHeight: screenSize.1)
        myHello = hello.encode()
        write(myHello)
    }

    private func tick() {
        sendLock.lock(); let keyed = sendKey != nil; sendLock.unlock()
        guard keyed else {
            if Date().timeIntervalSince(lastHeard) > 5 { close("no hello") }
            return
        }
        send(.heartbeat, force: true)
        // Waiting on a person to confirm the code can take a while; otherwise 1.5 s of silence
        // means the other side is gone.
        let limit: TimeInterval = (state == .trusted) ? 1.5 : 120
        if Date().timeIntervalSince(lastHeard) > limit { close("timed out") }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.lastHeard = Date()
                    self.buffer.append(data)
                    self.drain()
                }
                if let error { self.close("receive failed: \(error)"); return }
                if complete { self.close("peer closed the connection"); return }
                if case .closed = self.state { return }
                self.receive()
            }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let b = Array(buffer.prefix(4))
            let length = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            guard length <= Wire.maxFrame else { close(WireError.tooLarge.description); return }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
            do { try frame(body) } catch { close("\(error)"); return }
            if case .closed = state { return }
        }
    }

    private func frame(_ body: Data) throws {
        guard let receiveKey else { return try hello(body) }
        let plain = try WireCrypto.open(body, key: receiveKey, counter: receiveCounter)
        receiveCounter += 1
        let message = try WireMessage.decode(plain)
        switch message {
        case .heartbeat: return
        case .pairConfirm: remoteTrust = true; updateTrust()
        default:
            guard state == .trusted else { return }
            onMessage?(message)
        }
    }

    private func hello(_ body: Data) throws {
        let h = try WireHello.decode(body)
        guard h.role != role else { throw WireError.badRole }
        if myHello.isEmpty { sendHello() }
        peer = h
        let (pcHello, macHello) = role == .pc ? (myHello, body) : (body, myHello)
        let (p2m, m2p) = try WireCrypto.sessionKeys(myStatic: identity.key, myEphemeral: ephemeral,
                                                   peerStatic: h.staticKey, peerEphemeral: h.ephemeralKey,
                                                   pcHello: pcHello, macHello: macHello)
        let (mine, theirs) = role == .pc ? (p2m, m2p) : (m2p, p2m)
        sendLock.lock(); sendKey = mine; sendLock.unlock()
        receiveKey = theirs
        if role == .mac { screenSize = (h.screenWidth, h.screenHeight) }
        localTrust = pins.key(for: h.id) == h.staticKey
        remoteTrust = h.peerFingerprint == WireCrypto.fingerprint(identity.publicKey)
        // Tell the peer I already trust it, in case its hello's fingerprint check couldn't (a side
        // with several pinned peers only sends one fingerprint).
        if localTrust { send(.pairConfirm, force: true) }
        updateTrust()
    }

    private func updateTrust() {
        guard let peer else { return }
        if localTrust && remoteTrust { state = .trusted }
        else if !localTrust {
            let (mac, pc) = role == .mac ? (identity.publicKey, peer.staticKey) : (peer.staticKey, identity.publicKey)
            state = .pairing(code: WireCrypto.pairingCode(macKey: mac, pcKey: pc))
        } else { state = .waitingForPeer }
    }
}
