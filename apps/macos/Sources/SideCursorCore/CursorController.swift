import AppKit
import CoreGraphics
import Foundation

/// CoreGraphics connection API that Input Leap has relied on for years.
///
/// SideCursor runs as a background menu-bar agent, and the WindowServer only
/// lets the *frontmost* connection own the cursor image by default.  When the
/// pointer rests on a non-full-screen window's right edge, that window pushes a
/// resize cursor, the WindowServer honours it over our hide, and the pointer
/// reappears on the Mac (usually at the wrong scale, which is the tiny
/// adjusting pointer) while Windows already owns it.  The discarded hide also
/// desynchronizes the per-display hide counter, after which no later
/// `CGDisplayHideCursor` can hide the cursor again.
///
/// Marking the connection with `SetsCursorInBackground` lets the hide persist
/// even while another application is frontmost.  These are the same private
/// symbols Input Leap uses, resolved from the CoreGraphics framework.
private enum CursorBackgroundControl {
    private static var enabled = false

    @_silgen_name("_CGSDefaultConnection")
    private static func defaultConnection() -> Int32

    @_silgen_name("CGSSetConnectionProperty")
    private static func setConnectionProperty(
        _ connection: Int32,
        _ target: Int32,
        _ key: CFString,
        _ value: CFTypeRef
    ) -> CGError

    static func enable() {
        guard !enabled else { return }
        let connection = defaultConnection()
        let property = "SetsCursorInBackground" as CFString
        _ = setConnectionProperty(connection, connection, property, kCFBooleanTrue)
        enabled = true
    }
}

public enum CursorControllerError: Error, Equatable, LocalizedError {
    case associationFailed(CGError)
    case warpFailed(CGError)

    public var errorDescription: String? {
        switch self {
        case let .associationFailed(error): return "macOS could not associate the mouse cursor (\(error.rawValue))."
        case let .warpFailed(error): return "macOS could not return the mouse cursor (\(error.rawValue))."
        }
    }
}

/// Abstraction keeps the one-hide/one-unhide invariant testable without
/// manipulating the test runner's cursor.
public protocol CursorPlatform: AnyObject {
    func rememberFrontmostApplication()
    func restoreRememberedApplication()
    func disassociateMouse() -> CGError
    func associateMouse() -> CGError
    func hideCursor(on display: DisplayDescriptor)
    func unhideCursor()
    func warpMouse(to point: CGPoint) -> CGError
}

public final class ProductionCursorPlatform: CursorPlatform {
    private weak var previousApplication: NSRunningApplication?
    private var hiddenDisplayIDs: [CGDirectDisplayID] = []

    public init() {}

    public func rememberFrontmostApplication() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == currentPID ? nil : frontmost
    }

    public func restoreRememberedApplication() {
        defer { previousApplication = nil }
        guard let previousApplication, !previousApplication.isTerminated else { return }
        previousApplication.activate(options: [.activateIgnoringOtherApps])
    }

    public func disassociateMouse() -> CGError {
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    public func associateMouse() -> CGError {
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func hideCursor(on display: DisplayDescriptor) {
        // NSCursor's balanced counter is not enough for a background
        // menu-bar agent: an inactive app's hide is undone when the system
        // redraws the pointer.  The per-display CoreGraphics counter keeps the
        // pointer hidden while the remote session owns it.  Capturing displays
        // or showing a shield is intentionally never done.
        CursorBackgroundControl.enable()
        if CGDisplayHideCursor(display.runtimeID) == .success {
            hiddenDisplayIDs.append(display.runtimeID)
        }
    }

    public func unhideCursor() {
        CursorBackgroundControl.enable()
        while let displayID = hiddenDisplayIDs.popLast() {
            CGDisplayShowCursor(displayID)
        }
    }

    public func warpMouse(to point: CGPoint) -> CGError {
        CGWarpMouseCursorPosition(point)
    }
}

/// Owns exactly one global cursor hide while a remote session is active.
/// It intentionally never calls CGCaptureDisplay or CGCaptureAllDisplays.
public final class CursorController {
    private let platform: CursorPlatform
    private var capturedDisplay: DisplayDescriptor?
    private var didHideCursor = false

    public init(platform: CursorPlatform = ProductionCursorPlatform()) {
        self.platform = platform
    }

    public var isCaptured: Bool { capturedDisplay != nil }

    public func capture(on display: DisplayDescriptor) throws {
        guard capturedDisplay == nil else { return }
        platform.rememberFrontmostApplication()
        let association = platform.disassociateMouse()
        guard association == .success else {
            platform.restoreRememberedApplication()
            throw CursorControllerError.associationFailed(association)
        }
        platform.hideCursor(on: display)
        didHideCursor = true
        capturedDisplay = display
    }

    /// Returns the pointer inside the configured source display before making
    /// it local again, avoiding immediate edge re-entry.
    public func release(returnY: Double, inset: Double = 24) throws {
        guard let display = capturedDisplay else { return }
        let y = min(1, max(0, returnY))
        let safeInset = max(4, min(inset, max(4, display.bounds.width / 2)))
        let point = CGPoint(
            x: display.bounds.maxX - safeInset,
            y: display.bounds.y + y * max(1, display.bounds.height - 1)
        )

        let warp = platform.warpMouse(to: point)
        let association = platform.associateMouse()
        if didHideCursor {
            platform.unhideCursor()
            didHideCursor = false
        }
        capturedDisplay = nil
        platform.restoreRememberedApplication()

        if warp != .success { throw CursorControllerError.warpFailed(warp) }
        if association != .success { throw CursorControllerError.associationFailed(association) }
    }

    /// Best-effort cleanup for process shutdown and error recovery.  A failed
    /// warp must never keep the cursor hidden or the mouse disassociated.
    public func forceRestore(returnY: Double = 0.5) {
        do {
            try release(returnY: returnY)
        } catch {
            _ = platform.associateMouse()
            if didHideCursor {
                platform.unhideCursor()
                didHideCursor = false
            }
            capturedDisplay = nil
            platform.restoreRememberedApplication()
        }
    }
}
