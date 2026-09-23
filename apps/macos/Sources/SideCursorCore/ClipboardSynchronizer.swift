import AppKit
import CryptoKit
import Foundation

/// What a clipboard change carries between the computers.
public enum ClipboardContent: Equatable {
    case text(String)
    /// An image, always as PNG bytes.
    case png(Data)

    public var byteCount: Int {
        switch self {
        case let .text(text): return text.utf8.count
        case let .png(data): return data.count
        }
    }

    /// Tagged so identical bytes as text and as an image never collide.
    fileprivate var fingerprint: Data {
        switch self {
        case let .text(text): return Data("text:".utf8) + Data(text.utf8)
        case let .png(data): return Data("png:".utf8) + data
        }
    }
}

/// Stateless enough to unit-test the loop-prevention policy separately from
/// NSPasteboard and timers.
public struct ClipboardLoopGuard: Equatable {
    private var pendingRemoteDigest: Data?
    private var lastSentDigest: Data?

    public init() {}

    public mutating func markRemote(_ content: ClipboardContent) {
        pendingRemoteDigest = digest(content)
    }

    public mutating func shouldForwardLocal(_ content: ClipboardContent) -> Bool {
        let value = digest(content)
        if value == pendingRemoteDigest {
            pendingRemoteDigest = nil
            return false
        }
        guard value != lastSentDigest else { return false }
        lastSentDigest = value
        return true
    }

    public mutating func markRemoteText(_ text: String) {
        markRemote(.text(text))
    }

    public mutating func shouldForwardLocalText(_ text: String) -> Bool {
        shouldForwardLocal(.text(text))
    }

    private func digest(_ content: ClipboardContent) -> Data {
        Data(SHA256.hash(data: content.fingerprint))
    }
}

public protocol ClipboardSynchronizing: AnyObject {
    func start(onLocal: @escaping (ClipboardContent) -> Void)
    func stop()
    func applyRemote(_ content: ClipboardContent)
}

/// Polling `changeCount` is the supported pasteboard observation mechanism.
/// It never touches input capture, cursor visibility, or system gestures.
public final class ClipboardMonitor: ClipboardSynchronizing {
    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    /// Image conversion stays off the main thread, which also runs the
    /// pointer event tap. User-initiated: it answers a copy the user just
    /// made, and utility work is throttled for background apps.
    private let imageQueue = DispatchQueue(label: "com.yalinalagul.sidecursor.clipboard-images", qos: .userInitiated)
    private var timer: Timer?
    private var lastChangeCount = -1
    private var onLocal: ((ClipboardContent) -> Void)?
    private var loopGuard = ClipboardLoopGuard()
    public var maximumBytes = ProtocolV2.maximumClipboardBytes

    public init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.25) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
    }

    public func start(onLocal: @escaping (ClipboardContent) -> Void) {
        self.onLocal = onLocal
        lastChangeCount = pasteboard.changeCount
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        onLocal = nil
    }

    public func applyRemote(_ content: ClipboardContent) {
        guard content.byteCount <= maximumBytes else { return }
        loopGuard.markRemote(content)
        pasteboard.clearContents()
        switch content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .png(data):
            // PNG only. Offering TIFF would mean encoding it on the main
            // thread (which runs the pointer tap) whenever an app asks for it.
            pasteboard.setData(data, forType: .png)
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// Runs on the poll timer; tests call it directly.
    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        // Text wins when a copy offers both (spreadsheet cells, rich text).
        if let text = pasteboard.string(forType: .string) {
            deliver(.text(text))
            return
        }
        let types = pasteboard.types ?? []
        // A copied file carries its icon as an image; files are not shared.
        guard !types.contains(.fileURL) else { return }
        if let png = pasteboard.data(forType: .png) {
            deliver(.png(png))
        } else if let tiff = pasteboard.data(forType: .tiff), tiff.count <= maximumBytes * 8 {
            imageQueue.async { [weak self] in
                guard let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                DispatchQueue.main.async {
                    // Skip if something newer was copied while converting.
                    guard let self, self.pasteboard.changeCount == changeCount else { return }
                    self.deliver(.png(png))
                }
            }
        }
    }

    private func deliver(_ content: ClipboardContent) {
        guard content.byteCount <= maximumBytes, loopGuard.shouldForwardLocal(content) else { return }
        onLocal?(content)
    }
}
