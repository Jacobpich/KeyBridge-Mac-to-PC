import Combine
import Foundation
import Network

/// A tiny web page on the local network (port 47822) for getting the Windows companion onto
/// the PC: open http://<this Mac's IP>:47822 in the PC's browser and download MXControlPC.exe.
/// Only runs while switched on, and turns itself off after 30 minutes.
@MainActor
final class PCSetupServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var downloads = 0

    private var listener: NWListener?
    private var stopTimer: Timer?

    static var installerURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("MXControlPC.exe")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var addresses: [String] { Self.localIPv4().map { "http://\($0):\(Wire.setupPort)" } }

    func start() {
        guard listener == nil, let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Wire.setupPort)!) else { return }
        l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.serve(c) } }
        l.start(queue: .main)
        listener = l
        running = true
        stopTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        stopTimer?.invalidate(); stopTimer = nil
        running = false
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self?.respond(c, path: path)
            }
        }
    }

    private func respond(_ c: NWConnection, path: String) {
        func send(_ status: String, _ type: String, _ body: Data, extra: String = "") {
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
        switch path {
        case "/MXControlPC.exe":
            guard let url = Self.installerURL, let data = try? Data(contentsOf: url) else {
                send("404 Not Found", "text/plain", Data("The PC app hasn't been built yet.".utf8)); return
            }
            downloads += 1
            send("200 OK", "application/octet-stream", data,
                 extra: "Content-Disposition: attachment; filename=\"MXControlPC.exe\"\r\n")
        case "/":
            send("200 OK", "text/html; charset=utf-8", Data(page.utf8))
        default:
            send("404 Not Found", "text/plain", Data("Not found".utf8))
        }
    }

    private var page: String {
        let ready = Self.installerURL != nil
        let name = Host.current().localizedName ?? "this Mac"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>MX Control for PC</title>
        <style>body{font:16px -apple-system,Segoe UI,sans-serif;max-width:640px;margin:48px auto;padding:0 16px;line-height:1.5}
        a.button{display:inline-block;background:#0a64d8;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:600}
        li{margin:6px 0}</style></head><body>
        <h1>MX Control for PC</h1>
        <p>Use the keyboard, mouse and trackpad from <b>\(name)</b> on this PC.</p>
        \(ready ? "<p><a class=\"button\" href=\"/MXControlPC.exe\">Download MXControlPC.exe</a></p>"
                : "<p><b>The PC app hasn't been built yet.</b></p>")
        <ol>
        <li>Run <b>MXControlPC.exe</b>. If Windows says it protected your PC, click <b>More info → Run anyway</b>.</li>
        <li>It finds \(name) on the network by itself. Both screens then show the same 6-digit code: confirm it on both.</li>
        <li>Move the pointer off the right edge of the Mac's screen to reach the PC, and off the PC's left edge to come back.
        ⌃⌥⌘ Esc always brings it back to the Mac.</li>
        </ol></body></html>
        """
    }

    static func localIPv4() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
