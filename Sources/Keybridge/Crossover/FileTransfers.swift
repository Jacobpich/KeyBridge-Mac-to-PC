import Foundation

/// Sends and receives files over the Crossover link: copied files (clipboard) and dragged files.
///
/// Sending: an offer listing every file and folder, then each file's bytes in order in 256 KB
/// chunks, then "done". At most a few chunks are queued on the connection at once, so the
/// pointer and keyboard (which share the connection) never wait behind a big file.
@MainActor
final class FileTransfers {
    nonisolated static let chunkSize = 256 * 1024
    nonisolated static let inFlight = 4
    /// Received files live here until they're pasted or dropped; cleared after a week.
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keybridge/Transfers", isDirectory: true)

    /// Sends a message; `done` runs once it's on its way (used to pace file data). Returns false
    /// if there's no link.
    var send: ((WireMessage, (@Sendable () -> Void)?) -> Bool)?
    /// A transfer was offered to this Mac (it's already being received into `Incoming.folder`).
    var onOffer: ((Incoming) -> Void)?

    private var incoming: [UInt32: Incoming] = [:]
    private var outgoing: [UInt32: Outgoing] = [:]
    private var nextID = UInt32.random(in: 1...0x7FFF_FFFF)

    init() {
        Self.sweep()
    }

    // MARK: Sending

    /// Starts sending `urls` (files and folders). Returns the transfer id, or nil if there's
    /// nothing to send, it's over `maxBytes`, or there's no link.
    @discardableResult
    func send(_ urls: [URL], purpose: WireTransferPurpose, maxBytes: UInt64 = .max) -> UInt32? {
        let (entries, sources) = Self.list(urls)
        guard !entries.isEmpty, let send else { return nil }
        let total = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard total <= maxBytes else {
            CrossoverLog.write("not sending \(Self.bytes(entries)) for \(purpose): over the limit")
            return nil
        }
        // A new transfer of the same kind replaces one still going.
        for (id, o) in outgoing where o.purpose == purpose { o.cancel(); outgoing[id] = nil }
        nextID &+= 1
        let id = nextID
        guard send(.filesOffer(id: id, purpose: purpose.rawValue, entries: entries), nil) else { return nil }
        let o = Outgoing(id: id, purpose: purpose, sources: sources, send: send)
        outgoing[id] = o
        CrossoverLog.write("sending \(entries.count) item(s) (\(Self.bytes(entries))) for \(purpose)")
        o.start { [weak self] ok in
            Task { @MainActor in
                self?.outgoing[id] = nil
                CrossoverLog.write("sent transfer \(id): \(ok ? "complete" : "stopped")")
            }
        }
        return id
    }

    func cancelOutgoing(_ id: UInt32) { outgoing[id]?.cancel(); outgoing[id] = nil }

    /// Every file and folder under `urls`, as relative entries, plus the file each entry reads from.
    private static func list(_ urls: [URL]) -> ([WireFileEntry], [URL?]) {
        var entries: [WireFileEntry] = [], sources: [URL?] = []
        let fm = FileManager.default
        for top in urls {
            let name = top.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: top.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                entries.append(WireFileEntry(path: name, size: size(of: top), isDirectory: false)); sources.append(top)
                continue
            }
            entries.append(WireFileEntry(path: name, size: 0, isDirectory: true)); sources.append(nil)
            let walker = fm.enumerator(at: top, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            while let url = walker?.nextObject() as? URL {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { continue }
                let rel = name + "/" + url.path.dropFirst(top.path.count).drop { $0 == "/" }
                if v?.isDirectory == true {
                    entries.append(WireFileEntry(path: rel, size: 0, isDirectory: true)); sources.append(nil)
                } else {
                    entries.append(WireFileEntry(path: rel, size: size(of: url), isDirectory: false)); sources.append(url)
                }
            }
        }
        return (entries, sources)
    }

    private static func size(of url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func bytes(_ entries: [WireFileEntry]) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }), countStyle: .file)
    }

    // MARK: Receiving

    func received(_ m: WireMessage) {
        switch m {
        case .filesOffer(let id, let purpose, let entries):
            guard let purpose = WireTransferPurpose(rawValue: purpose) else { return }
            // A new offer of the same kind replaces an unfinished one.
            for (old, i) in incoming where i.purpose == purpose && !i.finished { i.finish(false); incoming[old] = nil }
            guard let i = Incoming(id: id, purpose: purpose, entries: entries) else {
                _ = send?(.filesCancel(id: id), nil)
                return
            }
            incoming[id] = i
            CrossoverLog.write("receiving \(entries.count) item(s) (\(Self.bytes(entries))) for \(purpose)")
            onOffer?(i)
        case .fileData(let id, let index, let data):
            incoming[id]?.write(index: Int(index), data: data)
        case .filesDone(let id, let complete):
            guard let i = incoming[id] else { return }
            incoming[id] = nil
            i.finish(complete)
            CrossoverLog.write("received transfer \(id): \(complete ? "complete" : "stopped")")
        case .filesCancel(let id):
            cancelOutgoing(id)
        default: break
        }
    }

    /// Stops receiving `id` and tells the sender.
    func cancelIncoming(_ id: UInt32) {
        guard let i = incoming[id] else { return }
        incoming[id] = nil
        i.finish(false)
        _ = send?(.filesCancel(id: id), nil)
    }

    /// The link went away: everything in flight stops.
    func reset() {
        for o in outgoing.values { o.cancel() }
        outgoing = [:]
        for i in incoming.values { i.finish(false) }
        incoming = [:]
    }

    /// Deletes received files older than a week.
    private static func sweep() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in items where ((try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < cutoff {
            try? fm.removeItem(at: item)
        }
    }
}

// MARK: - Outgoing

/// Reads files on a background queue and sends them in order, a few chunks in flight at a time.
final class Outgoing: @unchecked Sendable {
    let id: UInt32
    let purpose: WireTransferPurpose
    private let sources: [URL?]
    private let send: (WireMessage, (@Sendable () -> Void)?) -> Bool
    private let queue = DispatchQueue(label: "Keybridge file send", qos: .utility)
    /// Room for chunks in flight. Starts at 0 and is raised to the window size: libdispatch
    /// crashes the app if a semaphore is freed below its starting value, which happens when a
    /// transfer stops with chunks still in flight.
    private let window = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false

    init(id: UInt32, purpose: WireTransferPurpose, sources: [URL?],
         send: @escaping (WireMessage, (@Sendable () -> Void)?) -> Bool) {
        self.id = id; self.purpose = purpose; self.sources = sources; self.send = send
        for _ in 0..<FileTransfers.inFlight { window.signal() }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func start(_ finished: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let ok = run()
            _ = sendOnMain(.filesDone(id: id, complete: ok), done: nil)
            finished(ok)
        }
    }

    private func run() -> Bool {
        for (index, source) in sources.enumerated() {
            guard let source else { continue }
            guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
            defer { try? handle.close() }
            while true {
                if isCancelled { return false }
                guard let chunk = try? handle.read(upToCount: FileTransfers.chunkSize), !chunk.isEmpty else { break }
                // Wait for room in the window; give up if the link stalls for 15 s.
                guard window.wait(timeout: .now() + 15) == .success else { return false }
                let message = WireMessage.fileData(id: id, index: UInt32(index), data: chunk)
                guard sendOnMain(message, done: { [window] in window.signal() }) else { return false }
            }
        }
        return !isCancelled
    }

    /// `send` belongs to the main actor's world (the session); hop there for each message.
    private func sendOnMain(_ m: WireMessage, done: (@Sendable () -> Void)?) -> Bool {
        let send = self.send
        return DispatchQueue.main.sync { send(m, done) }
    }
}

// MARK: - Incoming

/// A transfer being received into its own folder under `FileTransfers.folder`.
@MainActor
final class Incoming {
    let id: UInt32
    let purpose: WireTransferPurpose
    let entries: [WireFileEntry]
    let folder: URL
    /// The top-level files and folders, once they're here (they exist as soon as the offer
    /// arrives, empty until the data does).
    let topLevel: [URL]
    private(set) var finished = false
    /// Set once the files are closed: true if everything arrived.
    private(set) var result: Bool?
    private var waiters: [(Bool) -> Void] = []
    private let writer: Writer

    init?(id: UInt32, purpose: WireTransferPurpose, entries: [WireFileEntry]) {
        self.id = id; self.purpose = purpose; self.entries = entries
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = FileTransfers.folder.appendingPathComponent("\(stamp)-\(id)", isDirectory: true)
        self.folder = folder
        let fm = FileManager.default
        var paths: [URL?] = []
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for e in entries {
                guard let rel = Self.safe(e.path) else { return nil }
                let url = folder.appendingPathComponent(rel, isDirectory: e.isDirectory)
                if e.isDirectory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    paths.append(nil)
                } else {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
                    paths.append(url)
                }
            }
        } catch { return nil }
        topLevel = entries.filter { !$0.path.contains("/") }.compactMap { Self.safe($0.path) }
            .map { folder.appendingPathComponent($0) }
        writer = Writer(paths: paths)
    }

    /// A relative path that stays inside the transfer folder, or nil.
    private static func safe(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }

    func write(index: Int, data: Data) { writer.write(index: index, data: data) }

    func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        writer.close { [weak self] wroteOK in
            Task { @MainActor in
                guard let self else { return }
                let complete = ok && wroteOK
                self.result = complete
                if !complete { try? FileManager.default.removeItem(at: self.folder) }
                let waiters = self.waiters; self.waiters = []
                for w in waiters { w(complete) }
            }
        }
    }

    /// Runs `body` once every file is here (true) or the transfer stopped (false).
    func whenDone(_ body: @escaping (Bool) -> Void) {
        if let result { body(result) } else { waiters.append(body) }
    }

    /// Writes on a background queue, one open file at a time.
    private final class Writer: @unchecked Sendable {
        private let paths: [URL?]
        private let queue = DispatchQueue(label: "Keybridge file receive", qos: .utility)
        private var handle: FileHandle?
        private var current = -1
        private var failed = false

        init(paths: [URL?]) { self.paths = paths }

        func write(index: Int, data: Data) {
            queue.async { [self] in
                guard !failed, paths.indices.contains(index), let url = paths[index] else { failed = true; return }
                if index != current {
                    try? handle?.close()
                    handle = try? FileHandle(forWritingTo: url)
                    current = index
                }
                guard let handle else { failed = true; return }
                do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { failed = true }
            }
        }

        func close(_ done: @escaping @Sendable (Bool) -> Void) {
            queue.async { [self] in
                try? handle?.close(); handle = nil
                done(!failed)
            }
        }
    }
}
