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
        returnInset: Double = 24,
        pointerScale: Double = 1.0,
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
        self.clipboardEnabled = clipboardEnabled
        self.clipboardMaximumBytes = max(1, min(SideCursorConfiguration.maximumClipboardBytes, clipboardMaximumBytes))
        self.pairingAccount = pairingAccount
        self.remoteHotkeys = remoteHotkeys
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
              let configuration = try? JSONDecoder().decode(SideCursorConfiguration.self, from: data)
        else {
            return SideCursorConfiguration()
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

    public func contains(_ point: CGPoint) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }
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

    public func crossesFromInside(_ point: CGPoint, deltaX: Int64, threshold: Double = 2) -> Bool {
        guard display.bounds.contains(point), deltaX > 0 else { return false }
        switch edge {
        case .right:
            return point.x >= display.bounds.maxX - threshold
        }
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
