import AppKit
import CryptoKit
import Foundation

/// Stateless enough to unit-test the loop-prevention policy separately from
/// NSPasteboard and timers.
public struct ClipboardLoopGuard: Equatable {
    private var pendingRemoteDigest: Data?
    private var lastSentDigest: Data?

    public init() {}

    public mutating func markRemoteText(_ text: String) {
        pendingRemoteDigest = digest(text)
    }

    public mutating func shouldForwardLocalText(_ text: String) -> Bool {
        let value = digest(text)
        if value == pendingRemoteDigest {
            pendingRemoteDigest = nil
            return false
        }
        guard value != lastSentDigest else { return false }
        lastSentDigest = value
        return true
    }

    private func digest(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}

public protocol ClipboardSynchronizing: AnyObject {
    func start(onLocalText: @escaping (String) -> Void)
    func stop()
    func applyRemoteText(_ text: String)
}

/// Polling `changeCount` is the supported pasteboard observation mechanism.
/// It never touches input capture, cursor visibility, or system gestures.
public final class ClipboardMonitor: ClipboardSynchronizing {
    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount = -1
    private var onLocalText: ((String) -> Void)?
    private var loopGuard = ClipboardLoopGuard()
    public var maximumBytes = ProtocolV2.maximumClipboardBytes

    public init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.25) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
    }

    public func start(onLocalText: @escaping (String) -> Void) {
        self.onLocalText = onLocalText
        lastChangeCount = pasteboard.changeCount
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        onLocalText = nil
    }

    public func applyRemoteText(_ text: String) {
        guard text.lengthOfBytes(using: .utf8) <= maximumBytes else { return }
        loopGuard.markRemoteText(text)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let text = pasteboard.string(forType: .string),
              text.lengthOfBytes(using: .utf8) <= maximumBytes,
              loopGuard.shouldForwardLocalText(text)
        else { return }
        onLocalText?(text)
    }
}
