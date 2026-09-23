import CoreGraphics
import Foundation
import XCTest
@testable import SideCursorCore

final class DisplayLayoutTests: XCTestCase {
    // 13.3" MacBook: 1440 x 900 pt over 287 x 179 mm.
    private let macBook = LayoutScreen(
        id: "mac-built-in",
        name: "Built-in",
        bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
        sizeMm: MillimeterSize(width: 287, height: 179),
        isPrimary: true
    )
    // 27" 4K Dell: 3840 x 2160 px over 597 x 336 mm.
    private let dell = LayoutScreen(
        id: "win-dell",
        name: "DELL S2725QS",
        bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160),
        sizeMm: MillimeterSize(width: 597, height: 336),
        isPrimary: true
    )

    func testSideBySideLinkCoversOnlyThePhysicallySharedStretch() throws {
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: CGPoint(x: 287, y: 0))

        let link = try XCTUnwrap(layout.links.first)
        XCTAssertEqual(layout.links.count, 1)
        XCTAssertEqual(link.macEdge, .right)
        XCTAssertEqual(link.startMm, 0, accuracy: 0.001)
        XCTAssertEqual(link.endMm, 179, accuracy: 0.001)
        // The whole Mac right edge hands off...
        XCTAssertEqual(link.macStart, 0, accuracy: 0.01)
        XCTAssertEqual(link.macEnd, 900, accuracy: 0.01)
        // ...but only the top 179 mm of the 336 mm Windows edge returns.
        XCTAssertEqual(link.windowsStart, 0, accuracy: 0.01)
        XCTAssertEqual(link.windowsEnd, 179 * 2160 / 336, accuracy: 0.01)
    }

    func testEntryPointMapsOneToOnePhysically() throws {
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: CGPoint(x: 287, y: 0))
        let link = try XCTUnwrap(layout.links.first)

        // Halfway down the Mac edge is 89.5 mm from the top, which is 89.5 mm
        // down the Dell too.
        let entry = link.windowsEntryPoint(forMac: CGPoint(x: 1439, y: 450), inset: 8)

        XCTAssertEqual(entry.x, 8, accuracy: 0.01)
        XCTAssertEqual(entry.y, 89.5 * 2160 / 336, accuracy: 0.5)
    }

    func testVerticalOffsetShiftsTheSharedStretch() throws {
        // Dell's top edge 100 mm above the Mac's top edge.
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: CGPoint(x: 287, y: -100))
        let zone = try XCTUnwrap(layout.layoutUpdate.zones.first)

        XCTAssertEqual(zone.edge, .left)
        XCTAssertEqual(zone.start, 100 * 2160 / 336, accuracy: 0.5)
        XCTAssertEqual(zone.end, 279 * 2160 / 336, accuracy: 0.5)
        XCTAssertEqual(zone.mac.edge, .right)
        XCTAssertEqual(zone.mac.line, 1440)
        XCTAssertEqual(zone.mac.start, 0, accuracy: 0.01)
        XCTAssertEqual(zone.mac.end, 900, accuracy: 0.01)
    }

    func testWindowsAboveTheMacLinksTopToBottom() throws {
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: CGPoint(x: -155, y: -336))
        let link = try XCTUnwrap(layout.links.first)

        XCTAssertEqual(link.macEdge, .top)
        XCTAssertEqual(link.windowsEdge, .bottom)
        XCTAssertEqual(link.macStart, 0, accuracy: 0.01)
        XCTAssertEqual(link.macEnd, 1440, accuracy: 0.01)
        XCTAssertEqual(link.windowsStart, 155 * 3840 / 597, accuracy: 0.5)
    }

    func testOverlappingLayoutHasNoLinks() {
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: CGPoint(x: 200, y: 0))

        XCTAssertTrue(layout.overlaps)
        XCTAssertTrue(layout.links.isEmpty)
    }

    func testSnapClosesAGapAndAlignsNearbyTops() throws {
        let snapped = try XCTUnwrap(ResolvedDisplayLayout.snappedOffset(
            CGPoint(x: 300, y: 6),
            macScreens: [macBook],
            windowsScreens: [dell]
        ))

        XCTAssertEqual(snapped.x, 287, accuracy: 0.001)
        XCTAssertEqual(snapped.y, 0, accuracy: 0.001)
    }

    func testSnapPushesAnOverlappingDropOutToTheNearestEdge() throws {
        let snapped = try XCTUnwrap(ResolvedDisplayLayout.snappedOffset(
            CGPoint(x: 250, y: -60),
            macScreens: [macBook],
            windowsScreens: [dell]
        ))
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: snapped)

        XCTAssertFalse(layout.overlaps)
        XCTAssertEqual(layout.links.first?.macEdge, .right)
    }

    func testDefaultPlacementCentresWindowsRightOfTheSourceDisplay() {
        let offset = ResolvedDisplayLayout.defaultOffset(macScreens: [macBook], windowsScreens: [dell], sourceMacID: nil)

        XCTAssertEqual(offset.x, 287, accuracy: 0.001)
        XCTAssertEqual(offset.y, 89.5 - 168, accuracy: 0.001)
    }

    func testArrangementKeepsTouchingDisplaysTouchingInMillimetres() throws {
        // A 24" 1920 x 1080 external above the MacBook, shifted 240 pt left.
        let external = LayoutScreen(
            id: "mac-external",
            name: "External",
            bounds: CGRect(x: -240, y: -1080, width: 1920, height: 1080),
            sizeMm: MillimeterSize(width: 527, height: 296),
            isPrimary: false
        )

        let rects = PhysicalArrangement.rects(for: [macBook, external])
        let rect = try XCTUnwrap(rects["mac-external"])

        XCTAssertEqual(rect.maxY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minX, -240 * 287 / 1440, accuracy: 0.001)
        XCTAssertEqual(rect.width, 527, accuracy: 0.001)
    }

    func testEntryZoneCrossingOnEachEdge() {
        let right = EntryZone(macDisplayID: "m", bounds: macBook.bounds, edge: .right, start: 0, end: 900)
        XCTAssertTrue(right.crosses(CGPoint(x: 1439, y: 450), previous: CGPoint(x: 1430, y: 450), deltaX: 9, deltaY: 0))
        // Parked at the clamp with no movement toward the edge.
        XCTAssertFalse(right.crosses(CGPoint(x: 1439, y: 450), previous: CGPoint(x: 1439, y: 440), deltaX: 0, deltaY: 10))
        // Pushing against the clamp still crosses by raw delta.
        XCTAssertTrue(right.crosses(CGPoint(x: 1439, y: 450), previous: CGPoint(x: 1440, y: 450), deltaX: 3, deltaY: 0))

        let left = EntryZone(macDisplayID: "m", bounds: macBook.bounds, edge: .left, start: 0, end: 900)
        XCTAssertTrue(left.crosses(CGPoint(x: 0, y: 100), previous: CGPoint(x: 6, y: 100), deltaX: -6, deltaY: 0))

        let top = EntryZone(macDisplayID: "m", bounds: macBook.bounds, edge: .top, start: 200, end: 700)
        XCTAssertTrue(top.crosses(CGPoint(x: 300, y: 0), previous: CGPoint(x: 300, y: 5), deltaX: 0, deltaY: -5))
        // Outside the shared stretch the top edge is a plain Mac edge.
        XCTAssertFalse(top.crosses(CGPoint(x: 100, y: 0), previous: CGPoint(x: 100, y: 5), deltaX: 0, deltaY: -5))
    }

    func testDiagonalSizeAndRotation() throws {
        let size = try XCTUnwrap(MillimeterSize.fromDiagonal(inches: 27, pixels: CGSize(width: 3840, height: 2160)))
        XCTAssertEqual(size.width, 597.7, accuracy: 0.1)
        XCTAssertEqual(size.height, 336.2, accuracy: 0.1)
        XCTAssertEqual(size.diagonalInches, 27, accuracy: 0.001)

        let portrait = MillimeterSize(width: 597, height: 336).oriented(toMatch: CGSize(width: 2160, height: 3840))
        XCTAssertEqual(portrait, MillimeterSize(width: 336, height: 597))
    }

    func testLayoutUpdateRoundTripsThroughJSON() throws {
        let layout = ResolvedDisplayLayout(macScreens: [macBook], windowsScreens: [dell], windowsOffsetMm: CGPoint(x: 287, y: 0))
        let data = try JSONEncoder().encode(ProtocolMessage.layout(layout.layoutUpdate))
        let decoded = try JSONDecoder().decode(ProtocolMessage.self, from: data)

        XCTAssertEqual(decoded, .layout(layout.layoutUpdate))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "layout")
    }
}
