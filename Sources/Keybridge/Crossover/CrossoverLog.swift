import Foundation

/// ~/Library/Logs/Keybridge.log — connection events, for troubleshooting.
enum CrossoverLog {
    private static let queue = DispatchQueue(label: "crossover.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Keybridge.log")

    static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space))
        queue.async {
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: url) }
        }
    }
}
