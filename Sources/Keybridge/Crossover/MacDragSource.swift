import AppKit
import UniformTypeIdentifiers

/// Files dragged off the PC's left edge become a real drag on the Mac. The button is still held,
/// so a see-through panel goes under the pointer, a press is posted onto it, and that press
/// starts a drag of file promises: where they're dropped, the files are written once they've
/// arrived from the PC.
@MainActor
final class MacDragSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    private static var current: MacDragSource?

    private let incoming: Incoming
    private let onEnd: (Bool) -> Void
    private let panel: NSPanel
    private let view = SourceView()
    nonisolated(unsafe) private let queue = OperationQueue()
    private var started = false
    private var ended = false

    /// Starts the drag. `onEnd` gets whether the files were dropped somewhere.
    static func begin(_ incoming: Incoming, onEnd: @escaping (Bool) -> Void) {
        current?.finish(false)
        let s = MacDragSource(incoming, onEnd)
        current = s
        s.start()
    }

    private init(_ incoming: Incoming, _ onEnd: @escaping (Bool) -> Void) {
        self.incoming = incoming
        self.onEnd = onEnd
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)  // fully clear windows don't get clicks
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
        view.owner = self
        queue.qualityOfService = .userInitiated
    }

    private func start() {
        placeUnderPointer()
        panel.orderFrontRegardless()
        // Give the window server a moment to know the panel is there, then press on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, !self.ended else { return }
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { self.finish(false); return }
            self.placeUnderPointer()
            InputCapture.postMouseDown()
        }
        // The press never arrived (or the button came up first): give up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.started else { return }
            self.finish(false)
        }
    }

    private func placeUnderPointer() {
        let p = NSEvent.mouseLocation
        panel.setFrame(NSRect(x: p.x - 60, y: p.y - 60, width: 120, height: 120), display: false)
    }

    fileprivate func pressed(_ event: NSEvent) {
        guard !started, !ended else { return }
        started = true
        let tops = incoming.entries.filter { !$0.path.contains("/") }
        let origin = view.convert(event.locationInWindow, from: nil)
        let items = zip(tops, incoming.topLevel).enumerated().map { i, pair -> NSDraggingItem in
            let (entry, url) = pair
            let type: UTType = entry.isDirectory ? .folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = url
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: type)
            let offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: origin.x - 32 + offset, y: origin.y - 32 - offset, width: 64, height: 64), contents: icon)
            return item
        }
        guard !items.isEmpty else { finish(false); return }
        view.beginDraggingSession(with: items, event: event, source: self)
        CrossoverLog.write("drag from PC: started on the Mac with \(items.count) item(s)")
    }

    private func finish(_ dropped: Bool) {
        guard !ended else { return }
        ended = true
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
        CrossoverLog.write("drag from PC: \(dropped ? "dropped" : "cancelled")")
        onEnd(dropped)
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { finish(operation != []) }
    }

    // MARK: File promises

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? URL)?.lastPathComponent ?? "File from PC"
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let source = provider.userInfo as? URL else { completionHandler(CocoaError(.fileNoSuchFile)); return }
        let done = UnsafeSendable(completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.incoming }.whenDone { ok in
                guard ok else { done.value(CocoaError(.fileReadUnknown)); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        do { try FileManager.default.moveItem(at: source, to: url) }
                        catch { try FileManager.default.copyItem(at: source, to: url) }
                        done.value(nil)
                    } catch {
                        done.value(error)
                    }
                }
            }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The panel's content: takes the posted press and starts the drag.
private final class SourceView: NSView {
    weak var owner: MacDragSource?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.pressed(event) }
}
