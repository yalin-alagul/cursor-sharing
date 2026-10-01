import AppKit
import SwiftUI
import XCTest
@testable import SideCursorCore
@testable import SideCursorMac

/// Renders every settings page and the menu-bar popup to PNGs for visual
/// review, without Screen Recording permission. Skipped unless
/// SIDECURSOR_SNAPSHOT_DIR is set:
///
///     SIDECURSOR_SNAPSHOT_DIR=/tmp/shots swift test --filter UISnapshotTests
@MainActor
final class UISnapshotTests: XCTestCase {
    func testRenderSettingsAndMenuSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SIDECURSOR_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set SIDECURSOR_SNAPSHOT_DIR to render UI snapshots.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        var configuration = SideCursorConfiguration()
        configuration.layout.knownWindowsDisplays = [
            RemoteDisplay(id: "dell", name: "DELL S2725QS", x: 0, y: 0, width: 3840, height: 2160, widthMm: 597, heightMm: 336, primary: true),
        ]
        let session = SessionController(
            configurationStore: SnapshotConfigurationStore(configuration),
            pairingSecretStore: SnapshotSecretStore()
        )
        let model = SideCursorAppModel(session: session, isLive: false)

        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for page in SettingsPage.allCases {
                try render(
                    SettingsView(model: model, initialPage: page),
                    size: CGSize(width: 880, height: 660),
                    appearance: appearance,
                    to: "\(directory)/\(page.rawValue)-\(suffix).png"
                )
            }
            try render(MenuBarView(model: model), size: nil, appearance: appearance, to: "\(directory)/menu-\(suffix).png")
        }
    }

    private func render<Content: View>(_ view: Content, size: CGSize?, appearance: NSAppearance.Name, to path: String) throws {
        let hosting = NSHostingView(rootView: view)
        let frameSize = size ?? hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: frameSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: frameSize)
        // Sidebars and switches only draw fully in an ordered-in window, so
        // show it far outside every display.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Let SwiftUI settle (lists, forms and onAppear run asynchronously).
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw XCTSkip("Could not create a bitmap for \(path)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // Prefer the window server's own composite of this window: it
        // includes sidebar materials that cacheDisplay cannot draw.
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           image.width > 1 {
            let rep = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            return
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

private final class SnapshotConfigurationStore: ConfigurationStoring {
    private var configuration: SideCursorConfiguration

    init(_ configuration: SideCursorConfiguration) {
        self.configuration = configuration
    }

    func load() -> SideCursorConfiguration { configuration }
    func save(_ configuration: SideCursorConfiguration) { self.configuration = configuration }
}

private final class SnapshotSecretStore: PairingSecretStoring {
    func load(account: String) throws -> Data? { Data(repeating: 7, count: 32) }
    func save(_ secret: Data, account: String) throws {}
    func delete(account: String) throws {}
}
