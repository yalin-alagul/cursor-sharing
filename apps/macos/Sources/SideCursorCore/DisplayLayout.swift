import CoreGraphics
import Foundation

/// A side of a display. Quartz and Windows both use y-down desktop
/// coordinates, so `top` is the smaller y on both platforms.
public enum ScreenEdge: String, Codable, CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom

    public var opposite: ScreenEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// Left and right edges run along y; top and bottom edges run along x.
    public var runsAlongY: Bool { self == .left || self == .right }
}

public struct MillimeterSize: Codable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isUsable: Bool {
        width.isFinite && height.isFinite && width >= 20 && height >= 20
    }

    public var diagonalInches: Double { (width * width + height * height).squareRoot() / 25.4 }

    /// Monitors report their size in landscape. A rotated display has
    /// portrait pixel bounds, so swap the reported size to match.
    public func oriented(toMatch pixels: CGSize) -> MillimeterSize {
        guard pixels.width > 0, pixels.height > 0 else { return self }
        return (pixels.width >= pixels.height) == (width >= height)
            ? self
            : MillimeterSize(width: height, height: width)
    }

    /// A size from a diagonal in inches, assuming square pixels.
    public static func fromDiagonal(inches: Double, pixels: CGSize) -> MillimeterSize? {
        guard inches > 0, pixels.width > 0, pixels.height > 0 else { return nil }
        let diagonal = (pixels.width * pixels.width + pixels.height * pixels.height).squareRoot()
        let millimeters = inches * 25.4
        return MillimeterSize(
            width: millimeters * pixels.width / diagonal,
            height: millimeters * pixels.height / diagonal
        )
    }

    /// Used when a display does not report a usable physical size.
    public static func assumed(for pixels: CGSize, unitsPerInch: Double) -> MillimeterSize {
        MillimeterSize(width: pixels.width / unitsPerInch * 25.4, height: pixels.height / unitsPerInch * 25.4)
    }
}

/// A Windows display as reported by the Windows companion, in Windows
/// virtual-desktop pixels.
public struct RemoteDisplay: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let widthMm: Double
    public let heightMm: Double
    public let primary: Bool

    public init(id: String, name: String, x: Int, y: Int, width: Int, height: Int, widthMm: Double, heightMm: Double, primary: Bool) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.widthMm = widthMm
        self.heightMm = heightMm
        self.primary = primary
    }

    public var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One display placed in the physical layout. `bounds` are in the owning
/// OS's desktop units: points on the Mac, pixels on Windows.
public struct LayoutScreen: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bounds: CGRect
    public let sizeMm: MillimeterSize
    public let isPrimary: Bool

    public init(id: String, name: String, bounds: CGRect, sizeMm: MillimeterSize, isPrimary: Bool) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.sizeMm = sizeMm
        self.isPrimary = isPrimary
    }

    var unitsPerMmX: Double { bounds.width / sizeMm.width }
    var unitsPerMmY: Double { bounds.height / sizeMm.height }
}

/// Persisted placement of the Windows displays around the Mac displays.
public struct DisplayLayoutConfiguration: Codable, Equatable {
    /// Where the Windows primary display's top-left corner sits in the Mac
    /// layout, in millimetres from the Mac main display's top-left corner.
    /// `nil` places Windows to the right of the Mac source display.
    public var windowsOffsetMm: MillimeterPoint?
    /// User-corrected physical sizes, keyed by `sizeKey(windows:id:)`.
    public var sizeOverridesMm: [String: MillimeterSize]
    /// The last Windows displays the companion reported, so the layout can
    /// be edited and used before Windows reconnects.
    public var knownWindowsDisplays: [RemoteDisplay]

    public init(
        windowsOffsetMm: MillimeterPoint? = nil,
        sizeOverridesMm: [String: MillimeterSize] = [:],
        knownWindowsDisplays: [RemoteDisplay] = []
    ) {
        self.windowsOffsetMm = windowsOffsetMm
        self.sizeOverridesMm = sizeOverridesMm
        self.knownWindowsDisplays = knownWindowsDisplays
    }

    public static func sizeKey(windows: Bool, id: String) -> String {
        (windows ? "windows:" : "mac:") + id
    }
}

public struct MillimeterPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Converts one OS's display arrangement into millimetres. Each display
/// keeps its real physical size; a display that touches an already-placed
/// display stays touching along the same edge, with its offset along that
/// edge converted using the placed display's pixel density.
public enum PhysicalArrangement {
    public static func rects(for screens: [LayoutScreen]) -> [String: CGRect] {
        guard let root = screens.first(where: \.isPrimary) ?? screens.first else { return [:] }
        var placed: [String: CGRect] = [
            root.id: CGRect(x: 0, y: 0, width: root.sizeMm.width, height: root.sizeMm.height),
        ]
        var pending = screens.filter { $0.id != root.id }
        while !pending.isEmpty {
            var progressed = false
            for screen in pending {
                for anchor in screens {
                    guard let anchorRect = placed[anchor.id], anchor.id != screen.id else { continue }
                    if let rect = place(screen, beside: anchor, anchorRect: anchorRect) {
                        placed[screen.id] = rect
                        progressed = true
                        break
                    }
                }
            }
            pending.removeAll { placed[$0.id] != nil }
            if !progressed {
                // A display that touches nothing keeps its offset from the
                // primary display, converted with the primary's density.
                for screen in pending {
                    placed[screen.id] = CGRect(
                        x: (screen.bounds.minX - root.bounds.minX) / root.unitsPerMmX,
                        y: (screen.bounds.minY - root.bounds.minY) / root.unitsPerMmY,
                        width: screen.sizeMm.width,
                        height: screen.sizeMm.height
                    )
                }
                pending.removeAll()
            }
        }
        return placed
    }

    private static func place(_ screen: LayoutScreen, beside anchor: LayoutScreen, anchorRect: CGRect) -> CGRect? {
        let tolerance: CGFloat = 1
        let s = screen.bounds
        let a = anchor.bounds
        let width = screen.sizeMm.width
        let height = screen.sizeMm.height
        if s.minY < a.maxY, s.maxY > a.minY {
            let y = anchorRect.minY + (s.minY - a.minY) / anchor.unitsPerMmY
            if abs(s.minX - a.maxX) <= tolerance {
                return CGRect(x: anchorRect.maxX, y: y, width: width, height: height)
            }
            if abs(s.maxX - a.minX) <= tolerance {
                return CGRect(x: anchorRect.minX - width, y: y, width: width, height: height)
            }
        }
        if s.minX < a.maxX, s.maxX > a.minX {
            let x = anchorRect.minX + (s.minX - a.minX) / anchor.unitsPerMmX
            if abs(s.minY - a.maxY) <= tolerance {
                return CGRect(x: x, y: anchorRect.maxY, width: width, height: height)
            }
            if abs(s.maxY - a.minY) <= tolerance {
                return CGRect(x: x, y: anchorRect.minY - height, width: width, height: height)
            }
        }
        return nil
    }
}

/// A stretch of edge where a Mac display physically touches a Windows
/// display. Along-edge coordinates increase in the same direction on both
/// platforms, so the mapping between them is linear and order-preserving.
public struct HandoffLink: Equatable {
    public let mac: LayoutScreen
    public let windows: LayoutScreen
    /// The Mac display's edge; the Windows display touches it with the
    /// opposite edge.
    public let macEdge: ScreenEdge
    public let macRectMm: CGRect
    public let windowsRectMm: CGRect
    /// The shared stretch, in layout millimetres along the edge.
    public let startMm: Double
    public let endMm: Double

    public var windowsEdge: ScreenEdge { macEdge.opposite }
    public var lengthMm: Double { endMm - startMm }

    public func macAlong(mm: Double) -> Double {
        macEdge.runsAlongY
            ? mac.bounds.minY + (mm - macRectMm.minY) * mac.unitsPerMmY
            : mac.bounds.minX + (mm - macRectMm.minX) * mac.unitsPerMmX
    }

    public func mm(macAlong along: Double) -> Double {
        macEdge.runsAlongY
            ? macRectMm.minY + (along - mac.bounds.minY) / mac.unitsPerMmY
            : macRectMm.minX + (along - mac.bounds.minX) / mac.unitsPerMmX
    }

    public func windowsAlong(mm: Double) -> Double {
        macEdge.runsAlongY
            ? windows.bounds.minY + (mm - windowsRectMm.minY) * windows.unitsPerMmY
            : windows.bounds.minX + (mm - windowsRectMm.minX) * windows.unitsPerMmX
    }

    /// Mac along-edge range (points) that hands off to Windows.
    public var macStart: Double { macAlong(mm: startMm) }
    public var macEnd: Double { macAlong(mm: endMm) }
    /// Windows along-edge range (pixels) that returns to the Mac.
    public var windowsStart: Double { windowsAlong(mm: startMm) }
    public var windowsEnd: Double { windowsAlong(mm: endMm) }

    /// The Mac display's edge line, in points.
    public var macLine: Double {
        switch macEdge {
        case .left: return mac.bounds.minX
        case .right: return mac.bounds.maxX
        case .top: return mac.bounds.minY
        case .bottom: return mac.bounds.maxY
        }
    }

    /// The Windows display's touching edge line, in pixels.
    public var windowsLine: Double {
        switch windowsEdge {
        case .left: return windows.bounds.minX
        case .right: return windows.bounds.maxX
        case .top: return windows.bounds.minY
        case .bottom: return windows.bounds.maxY
        }
    }

    /// The Windows pixel a pointer leaving the Mac at `point` arrives at,
    /// `inset` pixels inside the Windows display.
    public func windowsEntryPoint(forMac point: CGPoint, inset: Double) -> CGPoint {
        let along = macEdge.runsAlongY ? point.y : point.x
        let mm = min(max(mm(macAlong: along), startMm), endMm)
        return Self.inset(point: windowsAlong(mm: mm), from: windowsEdge, of: windows.bounds, by: inset)
    }

    /// A Mac point `inset` points inside the Mac display at `along`.
    public func macPoint(along: Double, inset: Double) -> CGPoint {
        Self.inset(point: along, from: macEdge, of: mac.bounds, by: inset)
    }

    public static func inset(point along: Double, from edge: ScreenEdge, of bounds: CGRect, by inset: Double) -> CGPoint {
        let depth = max(0, min(inset, (edge.runsAlongY ? bounds.width : bounds.height) - 1))
        switch edge {
        case .left:
            return CGPoint(x: bounds.minX + depth, y: clamp(along, bounds.minY, bounds.maxY - 1))
        case .right:
            return CGPoint(x: bounds.maxX - 1 - depth, y: clamp(along, bounds.minY, bounds.maxY - 1))
        case .top:
            return CGPoint(x: clamp(along, bounds.minX, bounds.maxX - 1), y: bounds.minY + depth)
        case .bottom:
            return CGPoint(x: clamp(along, bounds.minX, bounds.maxX - 1), y: bounds.maxY - 1 - depth)
        }
    }

    public var entryZone: EntryZone {
        EntryZone(macDisplayID: mac.id, bounds: mac.bounds, edge: macEdge, start: macStart, end: macEnd)
    }

    public var returnZone: ReturnZone {
        ReturnZone(
            display: windows.id,
            edge: windowsEdge,
            line: windowsLine,
            start: windowsStart,
            end: windowsEnd,
            mac: ReturnZone.MacSide(display: mac.id, edge: macEdge, line: macLine, start: macStart, end: macEnd)
        )
    }
}

private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), max(lower, upper))
}

/// A stretch of a Mac display edge that hands off to Windows, in Mac
/// points. Used on the event-tap hot path, so it is a small value type.
public struct EntryZone: Equatable {
    public let macDisplayID: String
    public let bounds: CGRect
    public let edge: ScreenEdge
    public let start: Double
    public let end: Double

    public init(macDisplayID: String, bounds: CGRect, edge: ScreenEdge, start: Double, end: Double) {
        self.macDisplayID = macDisplayID
        self.bounds = bounds
        self.edge = edge
        self.start = start
        self.end = end
    }

    /// How far inside the display `point` is from this edge (negative when
    /// the reported point has overshot past it).
    func depth(of point: CGPoint) -> Double {
        switch edge {
        case .left: return point.x - bounds.minX
        case .right: return bounds.maxX - point.x
        case .top: return point.y - bounds.minY
        case .bottom: return bounds.maxY - point.y
        }
    }

    func contains(along point: CGPoint) -> Bool {
        let along = edge.runsAlongY ? point.y : point.x
        return along >= start && along < end
    }

    /// macOS clamps the pointer at the desktop's outer edge (right/bottom
    /// one point inside), and the sample that reaches the edge can carry a
    /// zero delta or overshoot. A crossing is a pointer within `threshold`
    /// of the edge, inside the shared stretch, that moved toward the edge by
    /// position or by raw delta, and did not come from far beyond it.
    public func crosses(
        _ point: CGPoint,
        previous: CGPoint?,
        deltaX: Int64,
        deltaY: Int64,
        threshold: Double = 2,
        overshoot: Double = 24
    ) -> Bool {
        guard contains(along: point), depth(of: point) <= threshold else { return false }
        let delta: Int64
        switch edge {
        case .left: delta = -deltaX
        case .right: delta = deltaX
        case .top: delta = -deltaY
        case .bottom: delta = deltaY
        }
        var movingToward = delta > 0
        if let previous {
            let priorDepth = depth(of: previous)
            guard priorDepth > -overshoot else { return false }
            movingToward = movingToward || depth(of: point) < priorDepth
        }
        return movingToward
    }

    public func isNear(_ point: CGPoint, margin: Double = 8) -> Bool {
        contains(along: point) && depth(of: point) <= margin
    }
}

/// A stretch of a Windows display edge that returns to the Mac, sent to
/// the Windows companion. Along-edge ranges map linearly start-to-start.
public struct ReturnZone: Codable, Equatable {
    public struct MacSide: Codable, Equatable {
        public let display: String
        public let edge: ScreenEdge
        public let line: Double
        public let start: Double
        public let end: Double
    }

    public let display: String
    public let edge: ScreenEdge
    public let line: Double
    public let start: Double
    public let end: Double
    public let mac: MacSide
}

/// The Windows displays' effective physical sizes and the return zones,
/// sent to Windows whenever the layout changes.
public struct LayoutUpdate: Codable, Equatable {
    public struct DisplaySize: Codable, Equatable {
        public let id: String
        public let widthMm: Double
        public let heightMm: Double
    }

    public let displays: [DisplaySize]
    public let zones: [ReturnZone]

    public init(displays: [DisplaySize], zones: [ReturnZone]) {
        self.displays = displays
        self.zones = zones
    }
}

/// Mac and Windows displays placed together in millimetres, with the edge
/// stretches where they touch.
public struct ResolvedDisplayLayout: Equatable {
    public static let touchTolerance = 0.5
    public static let minimumSharedLength = 2.0
    public static let alignmentSnap = 10.0

    public let macScreens: [LayoutScreen]
    public let windowsScreens: [LayoutScreen]
    public let macRectsMm: [String: CGRect]
    /// Windows displays in Mac layout millimetres (the offset is applied).
    public let windowsRectsMm: [String: CGRect]
    public let windowsOffsetMm: CGPoint
    public let overlaps: Bool
    public let links: [HandoffLink]

    public init(macScreens: [LayoutScreen], windowsScreens: [LayoutScreen], windowsOffsetMm: CGPoint) {
        self.init(
            macScreens: macScreens,
            windowsScreens: windowsScreens,
            macRectsMm: PhysicalArrangement.rects(for: macScreens),
            windowsGroupRectsMm: PhysicalArrangement.rects(for: windowsScreens),
            windowsOffsetMm: windowsOffsetMm
        )
    }

    init(
        macScreens: [LayoutScreen],
        windowsScreens: [LayoutScreen],
        macRectsMm: [String: CGRect],
        windowsGroupRectsMm: [String: CGRect],
        windowsOffsetMm: CGPoint
    ) {
        self.macScreens = macScreens
        self.windowsScreens = windowsScreens
        self.macRectsMm = macRectsMm
        self.windowsOffsetMm = windowsOffsetMm
        let windowsRects = windowsGroupRectsMm.mapValues { $0.offsetBy(dx: windowsOffsetMm.x, dy: windowsOffsetMm.y) }
        windowsRectsMm = windowsRects
        overlaps = Self.overlaps(macRects: Array(macRectsMm.values), windowsRects: Array(windowsRects.values))
        links = overlaps ? [] : Self.links(
            macScreens: macScreens,
            windowsScreens: windowsScreens,
            macRects: macRectsMm,
            windowsRects: windowsRects
        )
    }

    public var entryZones: [EntryZone] { links.map(\.entryZone) }

    public var layoutUpdate: LayoutUpdate {
        LayoutUpdate(
            displays: windowsScreens.map { .init(id: $0.id, widthMm: $0.sizeMm.width, heightMm: $0.sizeMm.height) },
            zones: links.map(\.returnZone)
        )
    }

    /// The link a crossing at `point` on `edge` of a Mac display belongs to.
    public func link(macDisplayID: String, edge: ScreenEdge, at point: CGPoint) -> HandoffLink? {
        let along = edge.runsAlongY ? point.y : point.x
        let candidates = links.filter { $0.mac.id == macDisplayID && $0.macEdge == edge }
        return candidates.first { along >= $0.macStart && along < $0.macEnd }
            ?? candidates.min { abs(Self.distance(along, $0)) < abs(Self.distance(along, $1)) }
    }

    private static func distance(_ along: Double, _ link: HandoffLink) -> Double {
        along < link.macStart ? link.macStart - along : max(0, along - link.macEnd)
    }

    private static func overlaps(macRects: [CGRect], windowsRects: [CGRect]) -> Bool {
        for mac in macRects {
            for windows in windowsRects {
                let shared = mac.intersection(windows)
                if !shared.isNull, shared.width > touchTolerance, shared.height > touchTolerance {
                    return true
                }
            }
        }
        return false
    }

    private static func links(
        macScreens: [LayoutScreen],
        windowsScreens: [LayoutScreen],
        macRects: [String: CGRect],
        windowsRects: [String: CGRect]
    ) -> [HandoffLink] {
        var links: [HandoffLink] = []
        for mac in macScreens {
            guard let m = macRects[mac.id] else { continue }
            for windows in windowsScreens {
                guard let w = windowsRects[windows.id] else { continue }
                func add(_ edge: ScreenEdge, _ start: Double, _ end: Double) {
                    guard end - start >= minimumSharedLength else { return }
                    links.append(HandoffLink(
                        mac: mac,
                        windows: windows,
                        macEdge: edge,
                        macRectMm: m,
                        windowsRectMm: w,
                        startMm: start,
                        endMm: end
                    ))
                }
                if abs(m.maxX - w.minX) <= touchTolerance { add(.right, max(m.minY, w.minY), min(m.maxY, w.maxY)) }
                if abs(m.minX - w.maxX) <= touchTolerance { add(.left, max(m.minY, w.minY), min(m.maxY, w.maxY)) }
                if abs(m.maxY - w.minY) <= touchTolerance { add(.bottom, max(m.minX, w.minX), min(m.maxX, w.maxX)) }
                if abs(m.minY - w.maxY) <= touchTolerance { add(.top, max(m.minX, w.minX), min(m.maxX, w.maxX)) }
            }
        }
        return links
    }

    /// Windows placed to the right of the Mac source display, with the
    /// Windows primary display centred on it.
    public static func defaultOffset(
        macScreens: [LayoutScreen],
        windowsScreens: [LayoutScreen],
        sourceMacID: String?
    ) -> CGPoint {
        let macRects = PhysicalArrangement.rects(for: macScreens)
        let windowsRects = PhysicalArrangement.rects(for: windowsScreens)
        let sourceID = sourceMacID.flatMap { macRects[$0] != nil ? $0 : nil }
            ?? macScreens.first(where: \.isPrimary)?.id
            ?? macScreens.first?.id
        guard let source = sourceID.flatMap({ macRects[$0] }),
              let group = windowsRects.values.reduce(nil, { (partial: CGRect?, rect) in partial?.union(rect) ?? rect })
        else { return .zero }
        let primary = windowsScreens.first(where: \.isPrimary).flatMap { windowsRects[$0.id] } ?? group
        let proposed = CGPoint(x: source.maxX - group.minX, y: source.midY - primary.midY)
        return snappedOffset(proposed, macScreens: macScreens, windowsScreens: windowsScreens) ?? proposed
    }

    /// The nearest offset to `proposed` where the Windows displays touch a
    /// Mac display edge without overlapping any Mac display. Along the
    /// touching edge, starts, ends and centres snap into alignment when
    /// they are within `alignmentSnap` millimetres.
    public static func snappedOffset(
        _ proposed: CGPoint,
        macScreens: [LayoutScreen],
        windowsScreens: [LayoutScreen]
    ) -> CGPoint? {
        let macRects = PhysicalArrangement.rects(for: macScreens)
        let groupRects = PhysicalArrangement.rects(for: windowsScreens)
        var candidates: [(distance: Double, offset: CGPoint, edgeRunsAlongY: Bool, mac: CGRect, windows: CGRect)] = []
        for m in macRects.values {
            for groupRect in groupRects.values {
                let w = groupRect.offsetBy(dx: proposed.x, dy: proposed.y)
                let moves: [(CGFloat, CGFloat, Bool)] = [
                    (m.maxX - w.minX, 0, true),
                    (m.minX - w.maxX, 0, true),
                    (0, m.maxY - w.minY, false),
                    (0, m.minY - w.maxY, false),
                ]
                for (dx, dy, runsAlongY) in moves {
                    let moved = w.offsetBy(dx: dx, dy: dy)
                    // Slide along the edge if needed so the two displays share
                    // at least a little of it.
                    let slide: CGFloat
                    if runsAlongY {
                        slide = moved.maxY <= m.minY + minimumSharedLength ? m.minY + minimumSharedLength * 2 - moved.maxY
                            : moved.minY >= m.maxY - minimumSharedLength ? m.maxY - minimumSharedLength * 2 - moved.minY
                            : 0
                    } else {
                        slide = moved.maxX <= m.minX + minimumSharedLength ? m.minX + minimumSharedLength * 2 - moved.maxX
                            : moved.minX >= m.maxX - minimumSharedLength ? m.maxX - minimumSharedLength * 2 - moved.minX
                            : 0
                    }
                    let offset = CGPoint(
                        x: proposed.x + dx + (runsAlongY ? 0 : slide),
                        y: proposed.y + dy + (runsAlongY ? slide : 0)
                    )
                    let distance = hypot(offset.x - proposed.x, offset.y - proposed.y)
                    candidates.append((distance, offset, runsAlongY, m, groupRect.offsetBy(dx: offset.x, dy: offset.y)))
                }
            }
        }
        for candidate in candidates.sorted(by: { $0.distance < $1.distance }) {
            let aligned = aligned(candidate.offset, runsAlongY: candidate.edgeRunsAlongY, mac: candidate.mac, windows: candidate.windows)
            for offset in [aligned, candidate.offset] {
                let layout = ResolvedDisplayLayout(
                    macScreens: macScreens,
                    windowsScreens: windowsScreens,
                    macRectsMm: macRects,
                    windowsGroupRectsMm: groupRects,
                    windowsOffsetMm: offset
                )
                if !layout.overlaps, !layout.links.isEmpty { return offset }
            }
        }
        return nil
    }

    private static func aligned(_ offset: CGPoint, runsAlongY: Bool, mac: CGRect, windows: CGRect) -> CGPoint {
        let shifts: [CGFloat] = runsAlongY
            ? [mac.minY - windows.minY, mac.maxY - windows.maxY, mac.midY - windows.midY]
            : [mac.minX - windows.minX, mac.maxX - windows.maxX, mac.midX - windows.midX]
        guard let shift = shifts.min(by: { abs($0) < abs($1) }), abs(shift) <= alignmentSnap else { return offset }
        return runsAlongY ? CGPoint(x: offset.x, y: offset.y + shift) : CGPoint(x: offset.x + shift, y: offset.y)
    }
}

/// Builds the layout from live Mac displays, the reported Windows displays
/// and the user's saved placement and size corrections.
public enum DisplayLayoutBuilder {
    /// Used only when a display reports no usable physical size.
    public static let assumedMacPointsPerInch = 110.0
    public static let assumedWindowsPixelsPerInch = 96.0

    public static func macScreens(_ displays: [DisplayDescriptor], overrides: [String: MillimeterSize]) -> [LayoutScreen] {
        displays.map { display in
            LayoutScreen(
                id: display.stableID,
                name: display.name,
                bounds: display.cgBounds,
                sizeMm: overrides[DisplayLayoutConfiguration.sizeKey(windows: false, id: display.stableID)]
                    ?? display.sizeMm
                    ?? MillimeterSize.assumed(for: display.cgBounds.size, unitsPerInch: assumedMacPointsPerInch),
                isPrimary: display.isMain
            )
        }
    }

    public static func windowsScreens(_ displays: [RemoteDisplay], overrides: [String: MillimeterSize]) -> [LayoutScreen] {
        displays.map { display in
            LayoutScreen(
                id: display.id,
                name: display.name,
                bounds: display.bounds,
                sizeMm: overrides[DisplayLayoutConfiguration.sizeKey(windows: true, id: display.id)]
                    ?? detectedSize(of: display)
                    ?? MillimeterSize.assumed(for: display.bounds.size, unitsPerInch: assumedWindowsPixelsPerInch),
                isPrimary: display.primary
            )
        }
    }

    public static func detectedSize(of display: RemoteDisplay) -> MillimeterSize? {
        let size = MillimeterSize(width: display.widthMm, height: display.heightMm).oriented(toMatch: display.bounds.size)
        return size.isUsable ? size : nil
    }

    /// `nil` until the Windows companion has reported its displays.
    public static func resolve(
        configuration: SideCursorConfiguration,
        macDisplays: [DisplayDescriptor]
    ) -> ResolvedDisplayLayout? {
        let layout = configuration.layout
        guard !macDisplays.isEmpty, !layout.knownWindowsDisplays.isEmpty else { return nil }
        let mac = macScreens(macDisplays, overrides: layout.sizeOverridesMm)
        let windows = windowsScreens(layout.knownWindowsDisplays, overrides: layout.sizeOverridesMm)
        let offset = layout.windowsOffsetMm?.cgPoint ?? ResolvedDisplayLayout.defaultOffset(
            macScreens: mac,
            windowsScreens: windows,
            sourceMacID: configuration.sourceDisplayID
        )
        return ResolvedDisplayLayout(macScreens: mac, windowsScreens: windows, windowsOffsetMm: offset)
    }
}
