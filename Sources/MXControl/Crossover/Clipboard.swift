import AppKit
import UniformTypeIdentifiers

/// Moves the clipboard across when control changes sides: text, an image (as PNG), or copied
/// files and folders (sent as a file transfer). Passwords copied from a password manager stay on
/// the Mac.
@MainActor
final class ClipboardBridge {
    static let text: UInt8 = 1, png: UInt8 = 2

    enum Payload {
        case data(kind: UInt8, data: Data)
        case files([URL])
    }

    private let board = NSPasteboard.general
    private var lastSent = -1      // -1: the first crossing sends whatever is already copied
    private var lastWritten = -1

    /// Marks password managers put on secrets (nspasteboard.org); those never leave this Mac.
    private static let secretMarkers = ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword"]
        .map { NSPasteboard.PasteboardType($0) }

    var changeCount: Int { board.changeCount }

    /// The clipboard, if it changed since it was last sent or received.
    func payloadIfChanged() -> Payload? {
        let count = board.changeCount
        guard count != lastSent, count != lastWritten else { return nil }
        lastSent = count
        let types = board.types ?? []
        if types.contains(where: Self.secretMarkers.contains) { return nil }
        let string = board.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
        let richText = types.contains(.rtf) || types.contains(.rtfd)

        // Files or folders copied in Finder.
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        // Copied text from an editor can carry a picture of itself too; that's still text.
        if let string, richText || !(types.contains(.png) || types.contains(.tiff)) {
            return Self.textPayload(string)
        }
        if let png = board.data(forType: .png) ?? Self.pngFromTIFF(board.data(forType: .tiff)), png.count <= Wire.maxClipboard {
            return .data(kind: Self.png, data: png)
        }
        if let string { return Self.textPayload(string) }
        return nil
    }

    private static func textPayload(_ s: String) -> Payload? {
        let d = Data(s.utf8)
        return d.count <= Wire.maxClipboard ? .data(kind: text, data: d) : nil
    }

    func write(kind: UInt8, data: Data) {
        board.clearContents()
        switch kind {
        case Self.text: board.setString(String(decoding: data, as: UTF8.self), forType: .string)
        case Self.png:
            board.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        default: return
        }
        lastWritten = board.changeCount
    }

    /// Puts received files on the clipboard (⌘V in Finder copies them), unless something else
    /// was copied on this Mac since `since`. A single picture also goes on as an image, so it
    /// pastes into Messages, Notes and the like.
    func writeFiles(_ urls: [URL], ifUnchangedSince since: Int) {
        guard board.changeCount == since || board.changeCount == lastWritten else { return }
        board.clearContents()
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        if urls.count == 1, let url = urls.first,
           (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true,
           let png = Self.png(fromFile: url) {
            items[0].setData(png, forType: .png)
        }
        board.writeObjects(items)
        lastWritten = board.changeCount
    }

    private static func png(fromFile url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Wire.maxClipboard,
              let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "png" { return data }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else { return nil }
        return pngFromTIFF(tiff)
    }

    private static func pngFromTIFF(_ tiff: Data?) -> Data? {
        guard let tiff, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
