import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem

public enum InputGateMode: Equatable {
    case local
    case ready
    case entering
    case remote
    case returning
    case recovering
}

public struct InputGateSnapshot {
    public let mode: InputGateMode
    public let route: EdgeRoute?
    public let handoffBlockedUntil: Date
    public let hotkeys: RemoteHotkeys
}

/// The event tap and SessionController execute on different callback paths.
/// This small lock-protected model makes suppression instantaneous while all
/// socket work remains off the event callback.
public final class InputGate {
    private let lock = NSLock()
    private var mode: InputGateMode = .local
    private var route: EdgeRoute?
    private var handoffBlockedUntil = Date.distantPast
    private var hotkeys = RemoteHotkeys()

    public init() {}

    public func update(phase: SessionPhase, route: EdgeRoute?, hotkeys: RemoteHotkeys) {
        lock.lock()
        defer { lock.unlock() }
        self.route = route
        self.hotkeys = hotkeys
        switch phase {
        case .disconnected, .connecting: mode = .local
        case .ready: mode = .ready
        case .entering: mode = .entering
        case .remote: mode = .remote
        case .returning: mode = .returning
        case .recovering: mode = .recovering
        }
    }

    public func blockNewHandoffs(for seconds: TimeInterval) {
        lock.lock()
        handoffBlockedUntil = Date().addingTimeInterval(max(0, seconds))
        lock.unlock()
    }

    public func snapshot() -> InputGateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return InputGateSnapshot(
            mode: mode,
            route: route,
            handoffBlockedUntil: handoffBlockedUntil,
            hotkeys: hotkeys
        )
    }
}

public enum InputTapAction {
    case edgeCrossed(y: Double)
    case input(NativeInputEvent)
    case command(String)
    case panicHotkey
    case tapFailure(String)
    case handoffProbe(x: Double, y: Double, deltaX: Int64, previousX: Double?, minX: Double, maxX: Double)
}

public enum InputTapError: Error, LocalizedError {
    case accessibilityPermissionMissing
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Grant SideCursor \(AccessibilityPermission.settingsName) access in System Settings before starting input sharing."
        case .creationFailed:
            return "macOS could not create SideCursor's input event tap."
        }
    }
}

public enum AccessibilityPermission {
    /// macOS 27 renamed the user-facing Accessibility privacy pane while the
    /// underlying AX API retained its existing name.
    public static var settingsName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access"
            : "Accessibility"
    }

    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Input Monitoring is separate from Accessibility. macOS needs it before
    /// the event tap can observe and suppress local keyboard input, so remote
    /// mode must not leave the Mac keyboard live.
    public static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent as IOHIDRequestType) == kIOHIDAccessTypeGranted
    }

    public static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        requestInputMonitoring()
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent as IOHIDRequestType)
    }
}

public final class InputEventTap {
    private let gate: InputGate
    private let actionHandler: (InputTapAction) -> Void
    private let actionQueue: DispatchQueue
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// True when macOS installed the tap as a filter (events can be
    /// suppressed).  A tap created before permission was granted is silently
    /// made listen-only, which lets local input leak during remote mode.
    public private(set) var isFiltering = false
    /// Latest motion sample.  The tap callback runs on the main run loop, so
    /// this is only touched from that single path.
    private var lastMotionLocation: CGPoint?
    private var lastProbeAt = Date.distantPast
    /// Key codes whose key-down was consumed as a remote command; their key-up
    /// is swallowed instead of being forwarded as an unmatched key-up.
    private var commandKeyCodes: Set<Int64> = []

    public init(
        gate: InputGate,
        actionQueue: DispatchQueue = .main,
        actionHandler: @escaping (InputTapAction) -> Void
    ) {
        self.gate = gate
        self.actionQueue = actionQueue
        self.actionHandler = actionHandler
    }

    deinit { stop() }

    public var isRunning: Bool { tap != nil }

    public func start() throws {
        guard AccessibilityPermission.isGranted else { throw InputTapError.accessibilityPermissionMissing }
        if tap != nil {
            if isFiltering { return }
            // The system downgraded an earlier tap to listen-only (it was
            // created before permission existed).  Recreate it now that the
            // process is trusted so events can actually be suppressed.
            stop()
        }
        let eventMask = CGEventMask.max
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Input Leap's proven approach: tap at the HID level and return NULL
        // while a remote session owns input.  That suppresses the raw events
        // macOS needs for Dock-driven gestures (Mission Control, Spaces,
        // Launchpad, Show Desktop), so no persistent gesture settings have to
        // be rewritten.  Fall back to the session tap only if HID is denied.
        let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: refcon
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: refcon
        )
        guard let eventTap else {
            throw InputTapError.creationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        tap = eventTap
        runLoopSource = source
        refreshFilteringState()
    }

    /// Re-reads whether our installed tap can suppress events.  Called after
    /// starting and again after the permission poll, because macOS only
    /// upgrades the tap when it is recreated while fully trusted.
    public func refreshFilteringState() {
        isFiltering = Self.installedTapIsFiltering()
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        // Fully release the mach port so the callback can never fire against a
        // deallocated owner after teardown begins.
        CFMachPortInvalidate(tap)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
        isFiltering = false
        commandKeyCodes.removeAll()
        lastMotionLocation = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<InputEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The controller immediately recovers to local input.  Re-enable
            // the tap only to receive later local events; this is not cursor
            // hide retry polling and it never resumes remote forwarding.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            emit(.tapFailure("macOS disabled the input tap"))
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, isPanicHotkey(event) {
            emit(.panicHotkey)
            return nil
        }

        let snapshot = gate.snapshot()
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            return handleMotion(event, snapshot: snapshot)
        }
        if isButton(type) {
            return handleButton(type, event: event, snapshot: snapshot)
        }
        if type == .scrollWheel {
            return handleScroll(event, snapshot: snapshot)
        }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            return handleKey(type, event: event, snapshot: snapshot)
        }
        // Everything else includes the gesture events that drive Mission
        // Control, Spaces, Launchpad, and Show Desktop.  They are dropped
        // while a remote session owns input so those actions never fire.
        switch snapshot.mode {
        case .remote, .entering, .returning, .recovering:
            return nil
        case .local, .ready:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleMotion(_ event: CGEvent, snapshot: InputGateSnapshot) -> Unmanaged<CGEvent>? {
        let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
        let location = event.location
        let previousLocation = lastMotionLocation
        lastMotionLocation = location
        switch snapshot.mode {
        case .remote:
            if dx != 0 || dy != 0 { emit(.input(.pointer(dx: dx, dy: dy))) }
            return nil
        case .ready:
            guard let route = snapshot.route else { return Unmanaged.passUnretained(event) }
            if Date() >= snapshot.handoffBlockedUntil,
               route.crossesFromInside(location, deltaX: Int64(dx), previous: previousLocation) {
                emit(.edgeCrossed(y: route.normalizedY(for: location)))
            } else if route.isNearRightEdge(location), Date().timeIntervalSince(lastProbeAt) >= 1 {
                lastProbeAt = Date()
                emit(.handoffProbe(
                    x: Double(location.x),
                    y: Double(location.y),
                    deltaX: Int64(dx),
                    previousX: previousLocation.map { Double($0.x) },
                    minX: Double(route.display.bounds.x),
                    maxX: Double(route.display.bounds.maxX)
                ))
            }
            return Unmanaged.passUnretained(event)
        case .entering, .returning, .recovering:
            return nil
        case .local:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleButton(_ type: CGEventType, event: CGEvent, snapshot: InputGateSnapshot) -> Unmanaged<CGEvent>? {
        switch snapshot.mode {
        case .remote:
            let rawButton = event.getIntegerValueField(.mouseEventButtonNumber)
            let button: MouseButton = rawButton == 0 ? .left : (rawButton == 1 ? .right : .middle)
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            emit(.input(.button(button: button, down: down)))
            return nil
        case .entering, .returning, .recovering:
            return nil
        case .local, .ready:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleScroll(_ event: CGEvent, snapshot: InputGateSnapshot) -> Unmanaged<CGEvent>? {
        switch snapshot.mode {
        case .remote:
            let vertical = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let horizontal = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            if vertical != 0 || horizontal != 0 {
                emit(.input(.scroll(horizontal: horizontal, vertical: vertical)))
            }
            return nil
        case .entering, .returning, .recovering:
            return nil
        case .local, .ready:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKey(_ type: CGEventType, event: CGEvent, snapshot: InputGateSnapshot) -> Unmanaged<CGEvent>? {
        if snapshot.mode != .remote, !commandKeyCodes.isEmpty {
            // Abandon any command key whose key-up never arrived. Otherwise a
            // later remote session could swallow an unrelated key-up and leave
            // that key stuck down on Windows until a full release-all.
            commandKeyCodes.removeAll()
        }
        switch snapshot.mode {
        case .remote:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyUp, commandKeyCodes.remove(keyCode) != nil {
                // The matching key-down became a remote command, so its key-up
                // must not be forwarded as an unmatched key-up to Windows.
                return nil
            }
            if type == .keyDown, let command = MacVirtualKeyMapper.remoteCommand(
                keyCode: keyCode,
                flags: event.flags,
                hotkeys: snapshot.hotkeys
            ) {
                commandKeyCodes.insert(keyCode)
                emit(.command(command))
                return nil
            }
            guard let mapping = MacVirtualKeyMapper.map(keyCode: keyCode) else {
                // Suppress unmapped keys as well; otherwise local macOS would
                // receive keyboard input while Windows is remote-controlled.
                return nil
            }
            let down: Bool
            if type == .flagsChanged {
                // A modifier's pressed state is read from its own flag bit. A
                // key without a modifier mask must not be reported as pressed
                // just because the empty flag set is always "contained".
                down = mapping.modifierMask.map { event.flags.contains($0) } ?? false
            } else {
                down = type == .keyDown
            }
            emit(.input(.key(vk: mapping.vk, down: down, extended: mapping.extended)))
            return nil
        case .entering, .returning, .recovering:
            return nil
        case .local, .ready:
            return Unmanaged.passUnretained(event)
        }
    }

    private func emit(_ action: InputTapAction) {
        actionQueue.async { [actionHandler] in actionHandler(action) }
    }

    private func isPanicHotkey(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == 100
            && event.flags.contains(.maskControl)
            && event.flags.contains(.maskAlternate)
    }

    private func isButton(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    private static func eventMask(for events: [CGEventType]) -> CGEventMask {
        events.reduce(0) { result, event in result | (CGEventMask(1) << event.rawValue) }
    }

    /// Asks the window server whether SideCursor's own session tap is a
    /// filtering tap.  A listen-only tap cannot delete events, so remote mode
    /// would leak local input even though everything else looks healthy.
    private static func installedTapIsFiltering() -> Bool {
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 256)
        var count: UInt32 = 0
        guard CGGetEventTapList(UInt32(taps.count), &taps, &count) == .success else { return false }
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)
        for tap in taps.prefix(Int(count)) where tap.tappingProcess == processID {
            if tap.options == .defaultTap, tap.enabled { return true }
        }
        return false
    }
}

public struct WindowsKeyMapping: Equatable, Sendable {
    public let vk: Int
    public let extended: Bool
    public let modifierMask: CGEventFlags?

    public init(vk: Int, extended: Bool = false, modifierMask: CGEventFlags? = nil) {
        self.vk = vk
        self.extended = extended
        self.modifierMask = modifierMask
    }
}

public enum MacVirtualKeyMapper {
    private static let table: [Int64: WindowsKeyMapping] = [
        0: .init(vk: 0x41), 1: .init(vk: 0x53), 2: .init(vk: 0x44), 3: .init(vk: 0x46),
        4: .init(vk: 0x48), 5: .init(vk: 0x47), 6: .init(vk: 0x5A), 7: .init(vk: 0x58),
        8: .init(vk: 0x43), 9: .init(vk: 0x56), 11: .init(vk: 0x42), 12: .init(vk: 0x51),
        13: .init(vk: 0x57), 14: .init(vk: 0x45), 15: .init(vk: 0x52), 16: .init(vk: 0x59),
        17: .init(vk: 0x54), 18: .init(vk: 0x31), 19: .init(vk: 0x32), 20: .init(vk: 0x33),
        21: .init(vk: 0x34), 22: .init(vk: 0x36), 23: .init(vk: 0x35), 24: .init(vk: 0xBB),
        25: .init(vk: 0x39), 26: .init(vk: 0x37), 27: .init(vk: 0xBD), 28: .init(vk: 0x38),
        29: .init(vk: 0x30), 30: .init(vk: 0xDD), 31: .init(vk: 0x4F), 32: .init(vk: 0x55),
        33: .init(vk: 0xDB), 34: .init(vk: 0x49), 35: .init(vk: 0x50), 36: .init(vk: 0x0D),
        37: .init(vk: 0x4C), 38: .init(vk: 0x4A), 39: .init(vk: 0xDE), 40: .init(vk: 0x4B),
        41: .init(vk: 0xBA), 42: .init(vk: 0xDC), 43: .init(vk: 0xBC), 44: .init(vk: 0xBF),
        45: .init(vk: 0x4E), 46: .init(vk: 0x4D), 47: .init(vk: 0xBE), 48: .init(vk: 0x09),
        49: .init(vk: 0x20), 50: .init(vk: 0xC0), 51: .init(vk: 0x08), 53: .init(vk: 0x1B),
        54: .init(vk: 0x5C, extended: true, modifierMask: .maskCommand),
        55: .init(vk: 0x5B, modifierMask: .maskCommand),
        56: .init(vk: 0xA0, modifierMask: .maskShift),
        57: .init(vk: 0x14, modifierMask: .maskAlphaShift),
        58: .init(vk: 0xA4, modifierMask: .maskAlternate),
        59: .init(vk: 0xA2, modifierMask: .maskControl),
        60: .init(vk: 0xA1, modifierMask: .maskShift),
        61: .init(vk: 0xA5, extended: true, modifierMask: .maskAlternate),
        62: .init(vk: 0xA3, extended: true, modifierMask: .maskControl),
        96: .init(vk: 0x74), 97: .init(vk: 0x75), 98: .init(vk: 0x76), 99: .init(vk: 0x72),
        100: .init(vk: 0x77), 101: .init(vk: 0x78), 103: .init(vk: 0x7A), 105: .init(vk: 0x7C),
        107: .init(vk: 0x7D), 109: .init(vk: 0x79), 111: .init(vk: 0x7B), 118: .init(vk: 0x73),
        120: .init(vk: 0x71), 122: .init(vk: 0x70),
        123: .init(vk: 0x25, extended: true), 124: .init(vk: 0x27, extended: true),
        125: .init(vk: 0x28, extended: true), 126: .init(vk: 0x26, extended: true),
    ]

    public static func map(keyCode: Int64) -> WindowsKeyMapping? { table[keyCode] }

    public static func remoteCommand(keyCode: Int64, flags: CGEventFlags, hotkeys: RemoteHotkeys) -> String? {
        guard flags.contains(.maskControl), flags.contains(.maskAlternate) else { return nil }
        switch keyCode {
        case 123 where hotkeys.desktopLeftEnabled: return "desktop_left"
        case 124 where hotkeys.desktopRightEnabled: return "desktop_right"
        case 126 where hotkeys.taskViewEnabled: return "task_view"
        case 125 where hotkeys.showDesktopEnabled: return "show_desktop"
        default: return nil
        }
    }
}
