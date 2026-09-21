import AppKit
import CoreGraphics
import Foundation

public enum TransportKind: String, Codable, CaseIterable, Identifiable {
    case tailscaleTCP
    case bluetoothRFCOMM

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tailscaleTCP: return "Tailscale TCP"
        case .bluetoothRFCOMM: return "Bluetooth RFCOMM"
        }
    }
}

public enum HorizontalEdge: String, Codable, CaseIterable, Identifiable {
    case right

    public var id: String { rawValue }
    public var displayName: String { "Right edge" }
}

public struct RemoteHotkeys: Codable, Equatable {
    public var desktopLeftEnabled: Bool
    public var desktopRightEnabled: Bool
    public var taskViewEnabled: Bool
    public var showDesktopEnabled: Bool

    public init(
        desktopLeftEnabled: Bool = true,
        desktopRightEnabled: Bool = true,
        taskViewEnabled: Bool = true,
        showDesktopEnabled: Bool = true
    ) {
        self.desktopLeftEnabled = desktopLeftEnabled
        self.desktopRightEnabled = desktopRightEnabled
        self.taskViewEnabled = taskViewEnabled
        self.showDesktopEnabled = showDesktopEnabled
    }
}

/// Persistent settings contain no pairing secret.  The corresponding 32-byte
/// secret lives in Keychain under `pairingAccount`.
public struct SideCursorConfiguration: Codable, Equatable {
    public static let defaultPort = 24_800
    public static let maximumClipboardBytes = 1_048_576

    public var transport: TransportKind
    public var listenPort: Int
    public var bluetoothPeerAddress: String
    /// Retained only so configurations written by the experimental Python
    /// build still decode. Native v2 ignores it and resolves RFCOMM channels
    /// from the advertised SideCursor SDP service.
    public var bluetoothChannel: Int
    public var sourceDisplayID: String?
    public var sourceEdge: HorizontalEdge
    public var returnInset: Double
    public var pointerScale: Double
    /// Fraction of each Mac scroll notch forwarded to Windows. The default 0.125
    /// is an eighth; 1.0 would forward the local rate unchanged.
    public var scrollScale: Double
    /// Caps the remote pointer send rate. 0 sends every sample immediately
    /// (lowest latency); 1...16 groups high-polling input into at most one frame
    /// per interval in milliseconds.
    public var motionCoalesceMilliseconds: Int
    public var clipboardEnabled: Bool
    public var clipboardMaximumBytes: Int
    public var pairingAccount: String
    public var remoteHotkeys: RemoteHotkeys

    public init(
        transport: TransportKind = .tailscaleTCP,
        listenPort: Int = SideCursorConfiguration.defaultPort,
        bluetoothPeerAddress: String = "",
        bluetoothChannel: Int = 11,
        sourceDisplayID: String? = nil,
        sourceEdge: HorizontalEdge = .right,
        returnInset: Double = 8,
        pointerScale: Double = 1.0,
        scrollScale: Double = 0.125,
        motionCoalesceMilliseconds: Int = 0,
        clipboardEnabled: Bool = true,
        clipboardMaximumBytes: Int = SideCursorConfiguration.maximumClipboardBytes,
        pairingAccount: String = UUID().uuidString,
        remoteHotkeys: RemoteHotkeys = RemoteHotkeys()
    ) {
        self.transport = transport
        self.listenPort = max(1, min(65_535, listenPort))
        self.bluetoothPeerAddress = bluetoothPeerAddress
        self.bluetoothChannel = max(1, min(30, bluetoothChannel))
        self.sourceDisplayID = sourceDisplayID
        self.sourceEdge = sourceEdge
        self.returnInset = max(4, min(160, returnInset))
        self.pointerScale = max(0.1, min(4.0, pointerScale))
        self.scrollScale = max(0.02, min(1.0, scrollScale))
        self.motionCoalesceMilliseconds = max(0, min(16, motionCoalesceMilliseconds))
        self.clipboardEnabled = clipboardEnabled
        self.clipboardMaximumBytes = max(1, min(SideCursorConfiguration.maximumClipboardBytes, clipboardMaximumBytes))
        self.pairingAccount = pairingAccount
        self.remoteHotkeys = remoteHotkeys
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case listenPort
        case bluetoothPeerAddress
        case bluetoothChannel
        case sourceDisplayID
        case sourceEdge
        case returnInset
        case pointerScale
        case scrollScale
        case motionCoalesceMilliseconds
        case clipboardEnabled
        case clipboardMaximumBytes
        case pairingAccount
        case remoteHotkeys
    }

    /// Decoding re-applies the same clamps as the memberwise initializer.  A
    /// synthesized decoder would bypass them, and a stored value outside the
    /// valid range reaches `UInt16(configuration.listenPort)` at transport
    /// start and traps the app.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SideCursorConfiguration()
        self.init(
            transport: try container.decodeIfPresent(TransportKind.self, forKey: .transport) ?? defaults.transport,
            listenPort: try container.decodeIfPresent(Int.self, forKey: .listenPort) ?? defaults.listenPort,
            bluetoothPeerAddress: try container.decodeIfPresent(String.self, forKey: .bluetoothPeerAddress) ?? defaults.bluetoothPeerAddress,
            bluetoothChannel: try container.decodeIfPresent(Int.self, forKey: .bluetoothChannel) ?? defaults.bluetoothChannel,
            sourceDisplayID: try container.decodeIfPresent(String.self, forKey: .sourceDisplayID),
            sourceEdge: try container.decodeIfPresent(HorizontalEdge.self, forKey: .sourceEdge) ?? defaults.sourceEdge,
            returnInset: try container.decodeIfPresent(Double.self, forKey: .returnInset) ?? defaults.returnInset,
            pointerScale: try container.decodeIfPresent(Double.self, forKey: .pointerScale) ?? defaults.pointerScale,
            scrollScale: try container.decodeIfPresent(Double.self, forKey: .scrollScale) ?? defaults.scrollScale,
            motionCoalesceMilliseconds: try container.decodeIfPresent(Int.self, forKey: .motionCoalesceMilliseconds) ?? defaults.motionCoalesceMilliseconds,
            clipboardEnabled: try container.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? defaults.clipboardEnabled,
            clipboardMaximumBytes: try container.decodeIfPresent(Int.self, forKey: .clipboardMaximumBytes) ?? defaults.clipboardMaximumBytes,
            pairingAccount: try container.decodeIfPresent(String.self, forKey: .pairingAccount) ?? defaults.pairingAccount,
            remoteHotkeys: try container.decodeIfPresent(RemoteHotkeys.self, forKey: .remoteHotkeys) ?? defaults.remoteHotkeys
        )
    }
}

public protocol ConfigurationStoring: AnyObject {
    func load() -> SideCursorConfiguration
    func save(_ configuration: SideCursorConfiguration)
}

public final class UserDefaultsConfigurationStore: ConfigurationStoring {
    private let defaults: UserDefaults
    private let key = "native-v2-configuration"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SideCursorConfiguration {
        guard let data = defaults.data(forKey: key),
              var configuration = try? JSONDecoder().decode(SideCursorConfiguration.self, from: data)
        else {
            return SideCursorConfiguration()
        }
        // One-time migration: the original 24 px return inset forced a long
        // push back toward the edge, which made back-and-forth crossings feel
        // slow.  8 px still keeps the pointer clear of the edge.
        let migrationKey = "native-v2-return-inset-migrated"
        if !defaults.bool(forKey: migrationKey) {
            defaults.set(true, forKey: migrationKey)
            if configuration.returnInset == 24 {
                configuration.returnInset = 8
                save(configuration)
            }
        }
        return configuration
    }

    public func save(_ configuration: SideCursorConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}

public struct DisplayBounds: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// `stableID` is derived from display hardware identifiers rather than a
/// transient CoreGraphics display number.  It survives normal reconnects and
/// display rearrangement for physical displays.
public struct DisplayDescriptor: Identifiable, Codable, Equatable {
    public let stableID: String
    public let runtimeID: UInt32
    public let name: String
    public let bounds: DisplayBounds
    public let isBuiltIn: Bool
    public let isMain: Bool

    public var id: String { stableID }

    public init(
        stableID: String,
        runtimeID: UInt32,
        name: String,
        bounds: DisplayBounds,
        isBuiltIn: Bool,
        isMain: Bool
    ) {
        self.stableID = stableID
        self.runtimeID = runtimeID
        self.name = name
        self.bounds = bounds
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
    }
}

public struct EdgeRoute: Equatable {
    public let display: DisplayDescriptor
    public let edge: HorizontalEdge

    public init(display: DisplayDescriptor, edge: HorizontalEdge = .right) {
        self.display = display
        self.edge = edge
    }

    /// A pointer can be reported several pixels beyond a display's Quartz
    /// bounds on the event that crosses into an adjacent (or empty)
    /// virtual-desktop region, and mouse-moved events effectively stop once the
    /// pointer is parked at the edge. Reconstructing the prior position from
    /// `deltaX` is unreliable there: the crossing sample can carry a zero delta
    /// or overshoot farther than the reported delta. Prefer the tracked
    /// previous location when it is available and allow a bounded overshoot so
    /// that the first edge sample always starts the handoff, while a pointer
    /// already far to the right on another display does not.
    public func crossesFromInside(
        _ point: CGPoint,
        deltaX: Int64,
        previous: CGPoint? = nil,
        threshold: Double = 2,
        overshoot: Double = 24
    ) -> Bool {
        guard point.y >= display.bounds.y,
              point.y < display.bounds.maxY
        else { return false }

        let maxX = display.bounds.maxX
        guard point.x >= maxX - max(0, threshold) else { return false }

        let priorX: CGFloat
        let movingRight: Bool
        if let previous {
            priorX = previous.x
            movingRight = point.x > previous.x
        } else {
            priorX = point.x - CGFloat(deltaX)
            movingRight = deltaX > 0
        }
        guard movingRight else { return false }

        return priorX < maxX + max(0, overshoot)
    }

    /// True while the pointer sits inside the display's vertical span and
    /// within `margin` pixels of the configured right edge. Used only for
    /// throttled handoff diagnostics.
    public func isNearRightEdge(_ point: CGPoint, margin: Double = 8) -> Bool {
        guard point.y >= display.bounds.y, point.y < display.bounds.maxY else { return false }
        return point.x >= display.bounds.maxX - margin
    }

    public func normalizedY(for point: CGPoint) -> Double {
        guard display.bounds.height > 0 else { return 0.5 }
        return min(1, max(0, (point.y - display.bounds.y) / display.bounds.height))
    }
}

public enum DisplayCatalog {
    public static func activeDisplays() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }

        return displayIDs.map { displayID in
            let number = NSNumber(value: displayID)
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == number
            }
            let vendor = CGDisplayVendorNumber(displayID)
            let model = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)
            let stableID: String
            if vendor == 0 && model == 0 && serial == 0 {
                stableID = "runtime-\(displayID)"
            } else {
                stableID = "display-\(vendor)-\(model)-\(serial)"
            }
            return DisplayDescriptor(
                stableID: stableID,
                runtimeID: displayID,
                name: screen?.localizedName ?? "Display \(displayID)",
                bounds: DisplayBounds(CGDisplayBounds(displayID)),
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                isMain: displayID == CGMainDisplayID()
            )
        }
    }

    /// Matches the requested default: the uppermost external display.  The
    /// choice is immediately persisted by SessionController, not recalculated
    /// for every pointer event.
    public static func defaultSourceDisplay(from displays: [DisplayDescriptor] = activeDisplays()) -> DisplayDescriptor? {
        let external = displays.filter { !$0.isBuiltIn }
        return (external.isEmpty ? displays : external).min {
            if $0.bounds.y == $1.bounds.y { return $0.bounds.x < $1.bounds.x }
            return $0.bounds.y < $1.bounds.y
        }
    }

    public static func route(
        configuration: SideCursorConfiguration,
        displays: [DisplayDescriptor] = activeDisplays()
    ) -> EdgeRoute? {
        // A saved route must remain tied to its chosen physical display.  If
        // that display disappears, recovery is safer than silently changing
        // the handoff edge to another monitor.  Only a first-run, nil setting
        // may choose the requested upper external default.
        let selected: DisplayDescriptor?
        if let sourceDisplayID = configuration.sourceDisplayID {
            selected = displays.first { $0.stableID == sourceDisplayID }
        } else {
            selected = defaultSourceDisplay(from: displays)
        }
        return selected.map { EdgeRoute(display: $0, edge: configuration.sourceEdge) }
    }
}
