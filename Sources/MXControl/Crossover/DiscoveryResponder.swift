import Foundation

/// Answers "MXC1?" on UDP 47821 with "MXC1!" + port + name. A plain IPv4 socket, because an
/// IPv6 (dual-stack) socket doesn't receive IPv4 broadcasts, which is how the PC asks.
final class DiscoveryResponder {
    private let fd: Int32
    private let source: DispatchSourceRead

    init?(reply: Data) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Wire.discoveryPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); return nil }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64)
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard n >= 5, Data(buffer[0..<5]) == Data("MXC1?".utf8) else { return }
            let sent = reply.withUnsafeBytes { bytes in
                withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, fromLength) }
                }
            }
            let who = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            }
            CrossoverLog.write("discovery request from \(who): " + (sent >= 0 ? "answered" : "reply failed, errno \(errno) (\(String(cString: strerror(errno))))"))
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
