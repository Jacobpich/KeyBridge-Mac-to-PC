import Foundation
import IOKit.hid

public let logitechVendorID = 0x046D

/// Known Logitech receivers (product IDs). Anything else on usage page 0xFF00 is treated as a
/// device connected directly (Bluetooth or USB cable), addressed at index 0xFF.
public let receiverProductIDs: [Int: String] = [
    0xC548: "Logi Bolt Receiver",
    0xC52B: "Unifying Receiver",
    0xC532: "Unifying Receiver",
    0xC534: "Nano Receiver",
    0xC539: "Lightspeed Receiver",
    0xC547: "Lightspeed Receiver",
]

public enum HIDPPError: Error, CustomStringConvertible {
    case timeout
    case hidpp10(code: UInt8)
    case hidpp20(code: UInt8)
    case writeFailed(IOReturn)
    case featureMissing(UInt16)
    case disconnected

    public var description: String {
        switch self {
        case .timeout: return "no reply (device asleep or out of range)"
        case .hidpp10(let c): return "HID++ 1.0 error 0x\(String(c, radix: 16)) (\(Self.name10(c)))"
        case .hidpp20(let c): return "HID++ 2.0 error 0x\(String(c, radix: 16)) (\(Self.name20(c)))"
        case .writeFailed(let r): return "write failed (IOReturn 0x\(String(UInt32(bitPattern: r), radix: 16)))"
        case .featureMissing(let f): return "device doesn't support feature 0x\(String(f, radix: 16))"
        case .disconnected: return "device disconnected"
        }
    }

    static func name10(_ c: UInt8) -> String {
        [0x01: "invalid sub-ID", 0x02: "invalid address", 0x03: "invalid value", 0x04: "connect fail",
         0x05: "too many devices", 0x06: "already exists", 0x07: "busy", 0x08: "unknown device",
         0x09: "resource error", 0x0A: "request unavailable", 0x0B: "invalid param value", 0x0C: "wrong PIN"][c] ?? "unknown"
    }

    static func name20(_ c: UInt8) -> String {
        [0x01: "unknown", 0x02: "invalid argument", 0x03: "out of range", 0x04: "hardware error",
         0x05: "logitech internal", 0x06: "invalid feature index", 0x07: "invalid function",
         0x08: "busy", 0x09: "unsupported"][c] ?? "unknown"
    }
}

/// An HID++ message: [reportID, deviceIndex, subID/featureIndex, address/function|swID, params…]
public struct HIDPPMessage: CustomStringConvertible {
    public static let shortID: UInt8 = 0x10, longID: UInt8 = 0x11, veryLongID: UInt8 = 0x12
    public var bytes: [UInt8]

    public var reportID: UInt8 { bytes[0] }
    public var deviceIndex: UInt8 { bytes[1] }
    public var subID: UInt8 { bytes[2] }
    public var address: UInt8 { bytes[3] }
    public var params: [UInt8] { Array(bytes.dropFirst(4)) }
    public var function: UInt8 { address >> 4 }
    public var softwareID: UInt8 { address & 0x0F }

    public var description: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// One HID++ endpoint: a receiver, or a device connected directly.
@MainActor
public final class HIDPPChannel {
    public let device: IOHIDDevice
    public let productID: Int
    public let productName: String
    public let serialNumber: String?
    public let transport: String
    public var isReceiver: Bool { receiverProductIDs[productID] != nil }

    /// Called for every message that isn't a reply to a pending request (notifications, events).
    public var onNotification: ((HIDPPMessage) -> Void)?

    private var buffer = [UInt8](repeating: 0, count: 64)
    private var pending: [(id: Int, match: (HIDPPMessage) -> Bool, done: (Result<HIDPPMessage, Error>) -> Void)] = []
    private var nextID = 0
    private var queueTail: Task<Void, Never>?
    private let maxOutputLong: Int

    init(device: IOHIDDevice) {
        self.device = device
        productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Logitech device"
        serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "?"
        maxOutputLong = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 20
    }

    func open() -> IOReturn {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { return result }
        let context = Unmanaged.passUnretained(self).toOpaque()
        buffer.withUnsafeMutableBufferPointer { ptr in
            IOHIDDeviceRegisterInputReportCallback(device, ptr.baseAddress!, ptr.count, { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let channel = Unmanaged<HIDPPChannel>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                MainActor.assumeIsolated { channel.received(bytes, reportID: UInt8(truncatingIfNeeded: reportID)) }
            }, context)
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return result
    }

    func close() {
        for p in pending { p.done(.failure(HIDPPError.disconnected)) }
        pending.removeAll()
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func received(_ raw: [UInt8], reportID: UInt8) {
        var bytes = raw
        let hidppIDs = [HIDPPMessage.shortID, HIDPPMessage.longID, HIDPPMessage.veryLongID]
        // Over Bluetooth the same HID device also sends ordinary key and mouse reports; skip those.
        guard hidppIDs.contains(reportID) || (reportID == 0 && bytes.first.map(hidppIDs.contains) == true) else { return }
        // Some paths deliver the report without its ID byte.
        if let first = bytes.first, !hidppIDs.contains(first) {
            bytes.insert(reportID, at: 0)
        }
        guard bytes.count >= 7 else { return }
        let message = HIDPPMessage(bytes: bytes)
        if let index = pending.firstIndex(where: { $0.match(message) }) {
            let p = pending.remove(at: index)
            p.done(.success(message))
        } else {
            onNotification?(message)
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), $0.baseAddress!, $0.count)
        }
        if result != kIOReturnSuccess { throw HIDPPError.writeFailed(result) }
    }

    /// Sends one request and waits for its reply. Requests on a channel run one at a time.
    func request(_ bytes: [UInt8], timeout: Double, match: @escaping (HIDPPMessage) -> Bool,
                 error: @escaping (HIDPPMessage) -> HIDPPError?) async throws -> HIDPPMessage {
        let previous = queueTail
        let gate = Task<Void, Never> { _ = await previous?.value }
        let work = Task<HIDPPMessage, Error> { @MainActor in
            await gate.value
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HIDPPMessage, Error>) in
                var finished = false
                let finish: (Result<HIDPPMessage, Error>) -> Void = { result in
                    guard !finished else { return }
                    finished = true
                    cont.resume(with: result)
                }
                nextID += 1
                let id = nextID
                pending.append((id: id, match: { m in match(m) || error(m) != nil }, done: { result in
                    if case .success(let m) = result, let e = error(m) { finish(.failure(e)) } else { finish(result) }
                }))
                do { try write(bytes) } catch {
                    pending.removeAll { $0.id == id }
                    finish(.failure(error))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    guard !finished else { return }
                    self.pending.removeAll { $0.id == id }
                    finish(.failure(HIDPPError.timeout))
                }
            }
        }
        queueTail = Task { _ = try? await work.value }
        return try await work.value
    }

    // MARK: HID++ 1.0 (receiver registers)

    public func readRegister(_ register: UInt8, params: [UInt8] = [], long: Bool = false, index: UInt8 = 0xFF) async throws -> [UInt8] {
        let sub: UInt8 = long ? 0x83 : 0x81
        var p = params; p += [UInt8](repeating: 0, count: max(0, 3 - p.count))
        let bytes = [HIDPPMessage.shortID, index, sub, register] + p.prefix(3)
        let reply = try await request(bytes, timeout: 1.5,
            match: { $0.deviceIndex == index && $0.subID == sub && $0.address == register },
            error: { m in (m.deviceIndex == index && m.subID == 0x8F && m.params.first == sub && m.params.dropFirst().first == register)
                ? HIDPPError.hidpp10(code: m.params.count > 2 ? m.params[2] : 0) : nil })
        return reply.params
    }

    public func writeRegister(_ register: UInt8, params: [UInt8], index: UInt8 = 0xFF) async throws {
        var p = params; p += [UInt8](repeating: 0, count: max(0, 3 - p.count))
        let bytes = [HIDPPMessage.shortID, index, 0x80, register] + p.prefix(3)
        _ = try await request(bytes, timeout: 1.5,
            match: { $0.deviceIndex == index && $0.subID == 0x80 && $0.address == register },
            error: { m in (m.deviceIndex == index && m.subID == 0x8F && m.params.first == 0x80)
                ? HIDPPError.hidpp10(code: m.params.count > 2 ? m.params[2] : 0) : nil })
    }

    // MARK: HID++ 2.0 (feature calls)

    static let softwareID: UInt8 = 0x0A

    public func call(index: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8] = [], timeout: Double = 2.0) async throws -> [UInt8] {
        let address = (function << 4) | Self.softwareID
        var bytes = [HIDPPMessage.longID, index, featureIndex, address] + params
        bytes += [UInt8](repeating: 0, count: max(0, 20 - bytes.count))
        let reply = try await request(Array(bytes.prefix(20)), timeout: timeout,
            match: { $0.deviceIndex == index && $0.subID == featureIndex && $0.address == address },
            error: { m in
                if m.deviceIndex == index && m.subID == 0xFF && m.address == featureIndex && m.params.first == address {
                    return .hidpp20(code: m.params.count > 1 ? m.params[1] : 0)
                }
                // A receiver answers for a sleeping/unknown device with an HID++ 1.0 error.
                if m.deviceIndex == index && m.subID == 0x8F && m.address == featureIndex {
                    return .hidpp10(code: m.params.count > 1 ? m.params[1] : 0)
                }
                return nil
            })
        return reply.params
    }
}

/// Finds Logitech HID++ endpoints and keeps them open.
@MainActor
public final class HIDPPManager {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    public private(set) var channels: [HIDPPChannel] = []
    public var onChannelAdded: ((HIDPPChannel) -> Void)?
    public var onChannelRemoved: ((HIDPPChannel) -> Void)?
    public private(set) var lastOpenError: IOReturn?

    public init() {}

    /// HID++ lives on usage page 0xFF00 for receivers and USB, and 0xFF43 for Bluetooth LE.
    static let hidppUsagePages = [0xFF00, 0xFF43]
    /// Devices that couldn't be opened yet (Bluetooth needs Input Monitoring), retried shortly.
    private var unopened: [IOHIDDevice] = []
    private var retryTimer: Timer?

    public func start() {
        let matching: [[String: Any]] = Self.hidppUsagePages.map {
            [kIOHIDVendorIDKey: logitechVendorID, kIOHIDDeviceUsagePageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func added(_ device: IOHIDDevice) {
        guard !channels.contains(where: { $0.device === device }) else { return }
        // Only the interface that carries HID++ long reports: usage 0xFF00/0x0002 (receiver, USB)
        // or 0xFF43/0x0202 (Bluetooth LE) in its collections.
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]]) ?? []
        let hasLong = pairs.contains {
            ($0[kIOHIDDeviceUsagePageKey] == 0xFF00 && $0[kIOHIDDeviceUsageKey] == 0x0002)
                || ($0[kIOHIDDeviceUsagePageKey] == 0xFF43 && $0[kIOHIDDeviceUsageKey] == 0x0202)
        } || (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0) >= 20
        guard hasLong else { return }
        let channel = HIDPPChannel(device: device)
        let result = channel.open()
        guard result == kIOReturnSuccess else {
            lastOpenError = result
            // A Bluetooth keyboard or mouse is one HID device with its keys on it, so macOS only
            // lets an app open it with Input Monitoring. Ask once, then keep retrying.
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            if !unopened.contains(where: { $0 === device }) { unopened.append(device) }
            scheduleRetry()
            return
        }
        unopened.removeAll { $0 === device }
        channels.append(channel)
        onChannelAdded?(channel)
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let waiting = self.unopened
                self.unopened.removeAll()
                for device in waiting { self.added(device) }
                if self.unopened.isEmpty { timer.invalidate(); self.retryTimer = nil }
            }
        }
    }

    private func removed(_ device: IOHIDDevice) {
        unopened.removeAll { $0 === device }
        guard let index = channels.firstIndex(where: { $0.device === device }) else { return }
        let channel = channels.remove(at: index)
        channel.close()
        onChannelRemoved?(channel)
    }
}
