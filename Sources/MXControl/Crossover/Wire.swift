import CryptoKit
import Foundation

// Crossover wire protocol, version 1. The Windows companion (Windows/MXLink.Core) implements the
// same bytes; keep the two in step.
//
// Every frame on the TCP stream: u32 little-endian length, then the body.
// The first frame in each direction is a plaintext Hello. After that every body is
// AES-256-GCM ciphertext + 16-byte tag. Each direction has its own key, and the 12-byte nonce is
// 4 zero bytes + a u64 little-endian counter that starts at 0 and goes up by one per frame, so
// frames that are replayed, dropped or reordered fail to decrypt and end the connection.
//
// Keys: ikm = ECDH(ephemeral, peer ephemeral) || ECDH(static, peer static)   (P-256, raw X)
//       salt = SHA256(pcHello || macHello), info = "MXC1 session"
//       HKDF-SHA256 → 64 bytes: [0..<32] PC→Mac key, [32..<64] Mac→PC key.
// Pairing code (shown on both screens the first time) =
//       first 4 bytes of SHA256("MXC1 pair" || macStaticKey || pcStaticKey), big-endian, mod 1,000,000.

enum Wire {
    static let magic = Data("MXC1".utf8)
    static let version: UInt8 = 1
    static let tcpPort: UInt16 = 47820
    static let discoveryPort: UInt16 = 47821
    static let setupPort: UInt16 = 47822
    static let maxFrame = 32 << 20
    static let maxClipboard = 20 << 20
    static let bonjourType = "_mxcontrol._tcp"
}

enum WireError: Error, CustomStringConvertible {
    case short, badMagic, badVersion, badRole, badKey, tooLarge, unknownMessage(UInt8), decrypt
    var description: String {
        switch self {
        case .short: "message too short"
        case .badMagic: "not an MX Control connection"
        case .badVersion: "different Crossover version"
        case .badRole: "unexpected role"
        case .badKey: "bad public key"
        case .tooLarge: "frame too large"
        case .unknownMessage(let t): "unknown message type \(t)"
        case .decrypt: "message failed authentication"
        }
    }
}

// MARK: Little-endian bytes

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func raw(_ d: Data) { data.append(d) }
    mutating func string(_ s: String) {
        let bytes = Data(s.utf8.prefix(200))
        u16(UInt16(bytes.count)); data.append(bytes)
    }
    /// A string of up to 65,535 UTF-8 bytes (file paths), never cut short.
    mutating func longString(_ s: String) {
        let bytes = Data(s.utf8)
        u16(UInt16(min(bytes.count, 65_535))); data.append(bytes.prefix(65_535))
    }
}

struct ByteReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var remaining: Int { data.count - offset }
    mutating func raw(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw WireError.short }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }
    mutating func u8() throws -> UInt8 { try raw(1)[0] }
    mutating func u16() throws -> UInt16 { let d = try raw(2); return UInt16(d[0]) | UInt16(d[1]) << 8 }
    mutating func u32() throws -> UInt32 {
        let d = try raw(4); return UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    }
    mutating func u64() throws -> UInt64 { UInt64(try u32()) | UInt64(try u32()) << 32 }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func string() throws -> String { String(decoding: try raw(Int(try u16())), as: UTF8.self) }
    mutating func rest() -> Data { defer { offset = data.count }; return data.subdata(in: offset..<data.count) }
}

// MARK: Hello

struct WireHello {
    enum Role: UInt8 { case mac = 0x4D /* M */, pc = 0x50 /* P */ }
    var role: Role
    var id: Data             // 16 bytes, stable per install
    var name: String
    var staticKey: Data      // 65-byte X9.63 P-256 public key
    var ephemeralKey: Data   // 65-byte X9.63 P-256 public key, new per connection
    var peerFingerprint: Data // SHA256 of the peer static key this side has pinned, or 32 zero bytes
    var screenWidth: UInt16  // PC: its screen in pixels. Mac: 0.
    var screenHeight: UInt16

    func encode() -> Data {
        var w = ByteWriter()
        w.raw(Wire.magic); w.u8(Wire.version); w.u8(role.rawValue)
        w.raw(id); w.string(name); w.raw(staticKey); w.raw(ephemeralKey); w.raw(peerFingerprint)
        w.u16(screenWidth); w.u16(screenHeight)
        return w.data
    }

    static func decode(_ data: Data) throws -> WireHello {
        var r = ByteReader(data)
        guard try r.raw(4) == Wire.magic else { throw WireError.badMagic }
        guard try r.u8() == Wire.version else { throw WireError.badVersion }
        guard let role = Role(rawValue: try r.u8()) else { throw WireError.badRole }
        return WireHello(role: role, id: try r.raw(16), name: try r.string(), staticKey: try r.raw(65),
                         ephemeralKey: try r.raw(65), peerFingerprint: try r.raw(32),
                         screenWidth: try r.u16(), screenHeight: try r.u16())
    }
}

// MARK: Messages (inside the encrypted frames)

/// One file or folder in a transfer. `path` is relative, with "/" between folders; a transfer's
/// top-level items are the entries without a "/".
struct WireFileEntry: Equatable {
    var path: String
    var size: UInt64
    var isDirectory: Bool
}

enum WireTransferPurpose: UInt8 {
    case clipboard = 1   // copied files: they go on the other side's clipboard
    case drag = 2        // dragged across: they're dropped where the pointer lets go
}

enum WireMessage: Equatable {
    case heartbeat                                   // 0x01 both ways
    case pairConfirm                                 // 0x02 both ways: "my user confirmed the code"
    case enter(x: Float, y: Float)                   // 0x10 Mac→PC: pointer enters at this fraction of the PC screen
    case move(dx: Float, dy: Float)                  // 0x11 Mac→PC: pixels on the PC screen
    case button(UInt8, down: Bool)                   // 0x12 Mac→PC: 0 left, 1 right, 2 middle, 3 back, 4 forward
    case scroll(vertical: Float, horizontal: Float)  // 0x13 Mac→PC: wheel notches; + is up / right (Windows sense)
    case key(scan: UInt16, extended: Bool, down: Bool) // 0x14 Mac→PC: Windows set-1 scan code
    case vkey(UInt16, down: Bool)                    // 0x15 Mac→PC: Windows virtual key (media keys)
    case leave                                       // 0x16 Mac→PC: control went back to the Mac
    case returned(y: Float)                          // 0x20 PC→Mac: pointer left the PC's left edge at this height
    case clipboard(kind: UInt8, data: Data)          // 0x30 both ways: 1 = UTF-8 text, 2 = PNG
    case screen(width: UInt16, height: UInt16)       // 0x40 PC→Mac: PC screen size changed
    // File transfers, both ways. The sender offers the list, then sends each file's bytes in
    // order (entry `index`, in chunks), then says it's done.
    case filesOffer(id: UInt32, purpose: UInt8, entries: [WireFileEntry]) // 0x50
    case fileData(id: UInt32, index: UInt32, data: Data)                  // 0x51
    case filesDone(id: UInt32, complete: Bool)                            // 0x52 sender: all sent (or gave up)
    case filesCancel(id: UInt32)                                          // 0x53 receiver: stop sending
    case dragEnded(id: UInt32, dropped: Bool)                             // 0x54 Mac→PC: a drag from the PC finished on the Mac

    func encode() -> Data {
        var w = ByteWriter()
        switch self {
        case .heartbeat: w.u8(0x01)
        case .pairConfirm: w.u8(0x02)
        case .enter(let x, let y): w.u8(0x10); w.f32(x); w.f32(y)
        case .move(let dx, let dy): w.u8(0x11); w.f32(dx); w.f32(dy)
        case .button(let b, let down): w.u8(0x12); w.u8(b); w.u8(down ? 1 : 0)
        case .scroll(let v, let h): w.u8(0x13); w.f32(v); w.f32(h)
        case .key(let scan, let ext, let down): w.u8(0x14); w.u16(scan); w.u8((ext ? 1 : 0) | (down ? 2 : 0))
        case .vkey(let vk, let down): w.u8(0x15); w.u16(vk); w.u8(down ? 1 : 0)
        case .leave: w.u8(0x16)
        case .returned(let y): w.u8(0x20); w.f32(y)
        case .clipboard(let kind, let data): w.u8(0x30); w.u8(kind); w.raw(data)
        case .screen(let width, let height): w.u8(0x40); w.u16(width); w.u16(height)
        case .filesOffer(let id, let purpose, let entries):
            w.u8(0x50); w.u32(id); w.u8(purpose); w.u32(UInt32(entries.count))
            for e in entries { w.longString(e.path); w.u64(e.size); w.u8(e.isDirectory ? 1 : 0) }
        case .fileData(let id, let index, let data): w.u8(0x51); w.u32(id); w.u32(index); w.raw(data)
        case .filesDone(let id, let complete): w.u8(0x52); w.u32(id); w.u8(complete ? 1 : 0)
        case .filesCancel(let id): w.u8(0x53); w.u32(id)
        case .dragEnded(let id, let dropped): w.u8(0x54); w.u32(id); w.u8(dropped ? 1 : 0)
        }
        return w.data
    }

    static func decode(_ data: Data) throws -> WireMessage {
        var r = ByteReader(data)
        let type = try r.u8()
        switch type {
        case 0x01: return .heartbeat
        case 0x02: return .pairConfirm
        case 0x10: return .enter(x: try r.f32(), y: try r.f32())
        case 0x11: return .move(dx: try r.f32(), dy: try r.f32())
        case 0x12: return .button(try r.u8(), down: try r.u8() != 0)
        case 0x13: return .scroll(vertical: try r.f32(), horizontal: try r.f32())
        case 0x14:
            let scan = try r.u16(), flags = try r.u8()
            return .key(scan: scan, extended: flags & 1 != 0, down: flags & 2 != 0)
        case 0x15: return .vkey(try r.u16(), down: try r.u8() != 0)
        case 0x16: return .leave
        case 0x20: return .returned(y: try r.f32())
        case 0x30: return .clipboard(kind: try r.u8(), data: r.rest())
        case 0x40: return .screen(width: try r.u16(), height: try r.u16())
        case 0x50:
            let id = try r.u32(), purpose = try r.u8(), count = try r.u32()
            guard count <= 1_000_000 else { throw WireError.tooLarge }
            var entries: [WireFileEntry] = []
            for _ in 0..<count {
                entries.append(WireFileEntry(path: try r.string(), size: try r.u64(), isDirectory: try r.u8() != 0))
            }
            return .filesOffer(id: id, purpose: purpose, entries: entries)
        case 0x51: return .fileData(id: try r.u32(), index: try r.u32(), data: r.rest())
        case 0x52: return .filesDone(id: try r.u32(), complete: try r.u8() != 0)
        case 0x53: return .filesCancel(id: try r.u32())
        case 0x54: return .dragEnded(id: try r.u32(), dropped: try r.u8() != 0)
        default: throw WireError.unknownMessage(type)
        }
    }
}

// MARK: Crypto

enum WireCrypto {
    static func fingerprint(_ key: Data) -> Data { Data(SHA256.hash(data: key)) }

    static func pairingCode(macKey: Data, pcKey: Data) -> String {
        var input = Data("MXC1 pair".utf8); input.append(macKey); input.append(pcKey)
        let h = Array(SHA256.hash(data: input))
        let n = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
        return String(format: "%06u", n % 1_000_000)
    }

    /// Returns (PC→Mac key, Mac→PC key).
    static func sessionKeys(myStatic: P256.KeyAgreement.PrivateKey, myEphemeral: P256.KeyAgreement.PrivateKey,
                            peerStatic: Data, peerEphemeral: Data,
                            pcHello: Data, macHello: Data) throws -> (SymmetricKey, SymmetricKey) {
        guard let ps = try? P256.KeyAgreement.PublicKey(x963Representation: peerStatic),
              let pe = try? P256.KeyAgreement.PublicKey(x963Representation: peerEphemeral) else { throw WireError.badKey }
        let ee = try myEphemeral.sharedSecretFromKeyAgreement(with: pe)
        let ss = try myStatic.sharedSecretFromKeyAgreement(with: ps)
        var ikm = Data()
        ee.withUnsafeBytes { ikm.append(contentsOf: $0) }
        ss.withUnsafeBytes { ikm.append(contentsOf: $0) }
        var transcript = pcHello; transcript.append(macHello)
        let salt = Data(SHA256.hash(data: transcript))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                         info: Data("MXC1 session".utf8), outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var w = ByteWriter(); w.u32(0); w.u64(counter)
        return try! AES.GCM.Nonce(data: w.data)
    }

    static func seal(_ plain: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(counter))
        return box.ciphertext + box.tag
    }

    static func open(_ body: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        guard body.count >= 16 else { throw WireError.decrypt }
        let box = try AES.GCM.SealedBox(nonce: nonce(counter), ciphertext: body.dropLast(16), tag: body.suffix(16))
        do { return try AES.GCM.open(box, using: key) } catch { throw WireError.decrypt }
    }
}
