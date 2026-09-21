import Foundation

/// The native v2 state machine.  It deliberately has no implicit transition
/// from a pointer event directly into Remote: Windows must acknowledge entry
/// and macOS must capture its cursor first.
public enum SessionPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case ready = "Ready"
    case entering = "Entering"
    case remote = "Remote"
    case returning = "Returning"
    case recovering = "Recovering"

    public var isInputSuppressed: Bool {
        self == .entering || self == .remote || self == .returning || self == .recovering
    }
}

public enum SessionEvent: Equatable, Sendable {
    case beginConnecting
    case peerReady
    case requestEntry
    case entryAcknowledged
    case cursorCaptured
    case requestReturn
    case returnAcknowledged
    case recover
    case localInputRestored
    case disconnect
}

public enum SessionStateError: Error, Equatable, LocalizedError, Sendable {
    case invalidTransition(phase: SessionPhase, event: SessionEvent)

    public var errorDescription: String? {
        switch self {
        case let .invalidTransition(phase, event):
            return "Cannot apply \(event) while SideCursor is \(phase.rawValue)."
        }
    }
}

public struct SessionMachine: Equatable {
    public private(set) var phase: SessionPhase

    public init(phase: SessionPhase = .disconnected) {
        self.phase = phase
    }

    public mutating func transition(_ event: SessionEvent) throws {
        if event == .recover {
            phase = .recovering
            return
        }
        if event == .disconnect {
            phase = .disconnected
            return
        }

        let next: SessionPhase?
        switch (phase, event) {
        case (.disconnected, .beginConnecting):
            next = .connecting
        case (.ready, .beginConnecting):
            next = .connecting
        case (.connecting, .peerReady):
            next = .ready
        case (.ready, .requestEntry):
            next = .entering
        case (.entering, .entryAcknowledged):
            next = .entering
        case (.entering, .cursorCaptured):
            next = .remote
        case (.remote, .requestReturn):
            next = .returning
        case (.returning, .returnAcknowledged):
            next = .ready
        case (.recovering, .localInputRestored):
            next = .ready
        default:
            next = nil
        }

        guard let next else {
            throw SessionStateError.invalidTransition(phase: phase, event: event)
        }
        phase = next
    }
}
