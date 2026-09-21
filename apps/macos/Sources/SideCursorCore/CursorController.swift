import AppKit
import CoreGraphics
import Foundation

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
    func hideCursor()
    func unhideCursor()
    func warpMouse(to point: CGPoint) -> CGError
}

public final class ProductionCursorPlatform: CursorPlatform {
    private weak var previousApplication: NSRunningApplication?

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

    public func hideCursor() {
        // NSCursor maintains a global balanced hide count.  This code calls it
        // only once per capture and never retries or captures displays.
        NSCursor.hide()
    }

    public func unhideCursor() {
        NSCursor.unhide()
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
        platform.hideCursor()
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
