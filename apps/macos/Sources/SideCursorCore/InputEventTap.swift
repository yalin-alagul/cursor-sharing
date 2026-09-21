import ApplicationServices
import CoreGraphics
import Foundation

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
}

public enum InputTapError: Error, LocalizedError {
    case accessibilityPermissionMissing
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Grant SideCursor Accessibility access in System Settings before starting input sharing."
        case .creationFailed:
            return "macOS could not create SideCursor's input event tap."
        }
    }
}

public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    public static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

public final class InputEventTap {
    private let gate: InputGate
    private let actionHandler: (InputTapAction) -> Void
    private let actionQueue: DispatchQueue
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
        guard tap == nil else { return }
        let eventMask = Self.eventMask(for: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ])
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: refcon
        ) else {
            throw InputTapError.creationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        tap = eventTap
        runLoopSource = source
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
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
        return Unmanaged.passUnretained(event)
    }

    private func handleMotion(_ event: CGEvent, snapshot: InputGateSnapshot) -> Unmanaged<CGEvent>? {
        let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
        switch snapshot.mode {
        case .remote:
            if dx != 0 || dy != 0 { emit(.input(.pointer(dx: dx, dy: dy))) }
            return nil
        case .ready:
            guard Date() >= snapshot.handoffBlockedUntil,
                  let route = snapshot.route,
                  route.crossesFromInside(event.location, deltaX: Int64(dx))
            else { return Unmanaged.passUnretained(event) }
            emit(.edgeCrossed(y: route.normalizedY(for: event.location)))
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
        switch snapshot.mode {
        case .remote:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, let command = MacVirtualKeyMapper.remoteCommand(
                keyCode: keyCode,
                flags: event.flags,
                hotkeys: snapshot.hotkeys
            ) {
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
                down = event.flags.contains(mapping.modifierMask ?? [])
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
}

public struct WindowsKeyMapping: Equatable {
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
