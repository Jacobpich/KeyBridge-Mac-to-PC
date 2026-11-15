import AppKit

/// Where the PC's screen sits relative to the Mac's screens: against one side of one Mac screen,
/// like a display in System Settings → Displays → Arrange.
struct PCPlacement: Codable, Equatable {
    enum Side: String, Codable, CaseIterable, Identifiable {
        case right, left, above, below
        var id: String { rawValue }
        var label: String {
            switch self {
            case .right: "Right of"
            case .left: "Left of"
            case .above: "Above"
            case .below: "Below"
            }
        }
        /// The PC screen's edge that faces the Mac, as sent to the PC (`WireMessage.layout`).
        var pcEdge: UInt8 {
            switch self {
            case .right: 0   // PC is to the right, so its left edge faces the Mac
            case .left: 1
            case .above: 3   // PC is above, so its bottom edge faces the Mac
            case .below: 2
            }
        }
        var isHorizontal: Bool { self == .left || self == .right }
    }

    /// The Mac screen the PC sits against (its name).
    var display: String
    var side: Side
    /// Along that edge, where the PC starts relative to the Mac screen: for left/right, the PC's
    /// top minus the screen's top; for above/below, the PC's left minus the screen's left. Points.
    var offset: Double
}

/// A Mac screen as Crossover sees it.
struct MacDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect      // global top-left (Quartz) coordinates
}

/// The arrangement resolved into screen rectangles, used by the event tap.
struct CrossoverLayout: Equatable {
    var mac: CGRect = .null        // the Mac screen the PC sits against
    var pc: CGRect = .null         // where the PC's screen is, in the Mac's coordinates
    var side: PCPlacement.Side = .right
    /// The PC's monitor when it's also plugged into the Mac (the pointer can wander onto it), else null.
    var attached: CGRect = .null

    var isValid: Bool { !mac.isNull && !pc.isNull }

    /// Whether the pointer at `p`, moving by (dx, dy), should go to the PC.
    func crosses(at p: CGPoint, dx: Double, dy: Double) -> Bool {
        guard isValid else { return false }
        if !attached.isNull, attached.contains(p) { return true }
        if pc.contains(p) { return true }
        // No Mac screen beyond the edge: the pointer stops there, still pushing outward.
        switch side {
        case .right: return p.x >= mac.maxX - 1.5 && dx > 0 && p.y >= pc.minY && p.y < pc.maxY
        case .left: return p.x <= mac.minX + 0.5 && dx < 0 && p.y >= pc.minY && p.y < pc.maxY
        case .above: return p.y <= mac.minY + 0.5 && dy < 0 && p.x >= pc.minX && p.x < pc.maxX
        case .below: return p.y >= mac.maxY - 1.5 && dy > 0 && p.x >= pc.minX && p.x < pc.maxX
        }
    }

    /// Where on the PC's screen (fractions 0…1) the pointer at `p` arrives.
    func entryFraction(for p: CGPoint) -> CGPoint {
        let area = !attached.isNull && attached.contains(p) ? attached : pc
        return CGPoint(x: min(max((p.x - area.minX) / area.width, 0), 1),
                       y: min(max((p.y - area.minY) / area.height, 0), 1))
    }

    /// Where the hidden Mac pointer waits while control is on the PC: just inside the Mac screen,
    /// next to where it crossed.
    func parkPoint(near p: CGPoint) -> CGPoint {
        let x = min(max(p.x, mac.minX + 1), mac.maxX - 2), y = min(max(p.y, mac.minY + 1), mac.maxY - 2)
        switch side {
        case .right: return CGPoint(x: mac.maxX - 2, y: y)
        case .left: return CGPoint(x: mac.minX + 1, y: y)
        case .above: return CGPoint(x: x, y: mac.minY + 1)
        case .below: return CGPoint(x: x, y: mac.maxY - 2)
        }
    }

    /// Where the pointer comes back onto the Mac when it leaves the PC `fraction` of the way
    /// along the PC's edge that faces the Mac.
    func returnPoint(fraction f: CGFloat) -> CGPoint {
        let f = min(max(f, 0), 1)
        switch side {
        case .right, .left:
            let y = min(max(pc.minY + f * pc.height, mac.minY + 1), mac.maxY - 2)
            return CGPoint(x: side == .right ? mac.maxX - 3 : mac.minX + 2, y: y)
        case .above, .below:
            let x = min(max(pc.minX + f * pc.width, mac.minX + 1), mac.maxX - 2)
            return CGPoint(x: x, y: side == .above ? mac.minY + 2 : mac.maxY - 3)
        }
    }
}

enum Arrangement {
    /// The Mac's screens (main thread only).
    @MainActor
    static func displays() -> [MacDisplay] {
        NSScreen.screens.compactMap { s in
            guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return MacDisplay(id: id, name: s.localizedName, frame: CGDisplayBounds(id))
        }
    }

    /// The PC's screen size in Mac points: the attached monitor's size if it's plugged into the
    /// Mac too, otherwise its pixels (a PC pixel moves like a Mac point).
    static func pcSize(pixels: (UInt16, UInt16), attached: CGRect) -> CGSize {
        if !attached.isNull { return attached.size }
        guard pixels.0 > 0, pixels.1 > 0 else { return CGSize(width: 1920, height: 1080) }
        return CGSize(width: CGFloat(pixels.0), height: CGFloat(pixels.1))
    }

    /// The PC's rectangle for a placement against `mac`.
    static func pcRect(_ placement: PCPlacement, against mac: CGRect, size: CGSize) -> CGRect {
        let o = CGFloat(placement.offset)
        switch placement.side {
        case .right: return CGRect(x: mac.maxX, y: mac.minY + o, width: size.width, height: size.height)
        case .left: return CGRect(x: mac.minX - size.width, y: mac.minY + o, width: size.width, height: size.height)
        case .above: return CGRect(x: mac.minX + o, y: mac.minY - size.height, width: size.width, height: size.height)
        case .below: return CGRect(x: mac.minX + o, y: mac.maxY, width: size.width, height: size.height)
        }
    }

    /// Keeps at least part of the PC's edge against the Mac screen's, so there's somewhere to cross.
    static func clampOffset(_ offset: CGFloat, side: PCPlacement.Side, mac: CGRect, size: CGSize) -> CGFloat {
        let (macLen, pcLen) = side.isHorizontal ? (mac.height, size.height) : (mac.width, size.width)
        let overlap = min(macLen, pcLen) * 0.25
        return min(max(offset, overlap - pcLen), macLen - overlap)
    }

    /// Reads a placement off the real layout: where the PC's monitor sits among the Mac's screens.
    static func placement(of attached: CGRect, among screens: [MacDisplay]) -> PCPlacement? {
        var best: (PCPlacement, CGFloat)?
        for s in screens where s.frame != attached {
            let f = s.frame
            let vOverlap = min(f.maxY, attached.maxY) - max(f.minY, attached.minY)
            let hOverlap = min(f.maxX, attached.maxX) - max(f.minX, attached.minX)
            var options: [(PCPlacement.Side, CGFloat, CGFloat)] = []  // side, gap, overlap
            if vOverlap > 0 {
                options.append((.right, abs(attached.minX - f.maxX), vOverlap))
                options.append((.left, abs(f.minX - attached.maxX), vOverlap))
            }
            if hOverlap > 0 {
                options.append((.below, abs(attached.minY - f.maxY), hOverlap))
                options.append((.above, abs(f.minY - attached.maxY), hOverlap))
            }
            for (side, gap, overlap) in options where gap < 2 {
                let offset = side.isHorizontal ? attached.minY - f.minY : attached.minX - f.minX
                if best == nil || overlap > best!.1 {
                    best = (PCPlacement(display: s.name, side: side, offset: Double(offset)), overlap)
                }
            }
        }
        return best?.0
    }

    /// Moves the PC's monitor (when it's also plugged into the Mac) to match the placement, so
    /// macOS's arrangement and Crossover's agree. Returns false if macOS refused.
    static func moveDisplay(_ id: CGDirectDisplayID, to origin: CGPoint) -> Bool {
        guard id != CGMainDisplayID() else { return false }  // the main screen is always at 0,0
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded())) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
