import CoreFoundation
import Foundation

/// The compatibility profile only writes persistent macOS settings when the
/// user presses Apply.  It is never invoked during edge handoff or remote mode.
public enum PreferenceValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)

    private enum CodingKeys: String, CodingKey { case type, bool, integer, double, string }
    private enum Kind: String, Codable { case bool, integer, double, string }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer: self = .integer(try container.decode(Int.self, forKey: .integer))
        case .double: self = .double(try container.decode(Double.self, forKey: .double))
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bool(value):
            try container.encode(Kind.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .integer)
        case let .double(value):
            try container.encode(Kind.double, forKey: .type)
            try container.encode(value, forKey: .double)
        case let .string(value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .string)
        }
    }
}

public struct PreferenceAddress: Codable, Hashable, Equatable, Sendable {
    public let domain: String
    public let currentHost: Bool
    public let key: String

    public init(domain: String, currentHost: Bool = false, key: String) {
        self.domain = domain
        self.currentHost = currentHost
        self.key = key
    }
}

public struct GesturePreference: Codable, Equatable, Sendable {
    public let address: PreferenceAddress
    public let disabledValue: PreferenceValue

    public init(domain: String, currentHost: Bool = false, key: String, disabledValue: PreferenceValue) {
        address = PreferenceAddress(domain: domain, currentHost: currentHost, key: key)
        self.disabledValue = disabledValue
    }
}

public struct GestureSnapshotEntry: Codable, Equatable, Sendable {
    public let address: PreferenceAddress
    public let originalValue: PreferenceValue?

    public init(address: PreferenceAddress, originalValue: PreferenceValue?) {
        self.address = address
        self.originalValue = originalValue
    }
}

public struct GestureSnapshot: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let entries: [GestureSnapshotEntry]

    public init(createdAt: Date = Date(), entries: [GestureSnapshotEntry]) {
        self.createdAt = createdAt
        self.entries = entries
    }
}

public protocol GesturePreferenceStoring: AnyObject {
    func value(at address: PreferenceAddress) throws -> PreferenceValue?
    func set(_ value: PreferenceValue, at address: PreferenceAddress) throws
    func removeValue(at address: PreferenceAddress) throws
}

public protocol GestureSnapshotStoring: AnyObject {
    func load() throws -> GestureSnapshot?
    func save(_ snapshot: GestureSnapshot) throws
    func remove() throws
}

public enum GestureProfileError: Error, LocalizedError {
    case unsupportedPreferenceValue
    case defaultsFailed(String)
    case snapshotEncoding

    public var errorDescription: String? {
        switch self {
        case .unsupportedPreferenceValue: return "A saved gesture preference has an unsupported value type."
        case let .defaultsFailed(message): return "macOS could not update a gesture preference: \(message)"
        case .snapshotEncoding: return "SideCursor could not save the gesture restore snapshot."
        }
    }
}

/// Uses the public `defaults` tool for the same persistent user-preference
/// domains exposed by System Settings.  It does not restart Dock/cfprefsd or
/// attempt to force gesture activation; the UI tells the user to sign out or
/// restart after Apply/Restore.
public final class DefaultsGesturePreferenceStore: GesturePreferenceStoring {
    public init() {}

    public func value(at address: PreferenceAddress) throws -> PreferenceValue? {
        var arguments: [String] = []
        if address.currentHost { arguments.append("-currentHost") }
        arguments += ["export", address.domain, "-"]
        let data = try runDefaults(arguments, permitFailure: true)
        guard !data.isEmpty else { return nil }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let raw = plist[address.key]
        else { return nil }
        return try convert(raw)
    }

    public func set(_ value: PreferenceValue, at address: PreferenceAddress) throws {
        var arguments: [String] = []
        if address.currentHost { arguments.append("-currentHost") }
        arguments += ["write", address.domain, address.key]
        switch value {
        case let .bool(value):
            arguments += ["-bool", value ? "true" : "false"]
        case let .integer(value):
            arguments += ["-int", String(value)]
        case let .double(value):
            arguments += ["-float", String(value)]
        case let .string(value):
            arguments += ["-string", value]
        }
        _ = try runDefaults(arguments)
    }

    public func removeValue(at address: PreferenceAddress) throws {
        var arguments: [String] = []
        if address.currentHost { arguments.append("-currentHost") }
        arguments += ["delete", address.domain, address.key]
        _ = try runDefaults(arguments, permitFailure: true)
    }

    private func convert(_ value: Any) throws -> PreferenceValue {
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            let double = value.doubleValue
            if double.rounded() == double { return .integer(value.intValue) }
            return .double(double)
        }
        if let value = value as? String { return .string(value) }
        throw GestureProfileError.unsupportedPreferenceValue
    }

    private func runDefaults(_ arguments: [String], permitFailure: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 || permitFailure else {
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown failure"
            throw GestureProfileError.defaultsFailed(detail)
        }
        return output
    }
}

public final class FileGestureSnapshotStore: GestureSnapshotStoring {
    private let url: URL

    public init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("SideCursor", isDirectory: true)
            .appendingPathComponent("gesture-compatibility-v2.json")
    }

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> GestureSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(GestureSnapshot.self, from: Data(contentsOf: url))
    }

    public func save(_ snapshot: GestureSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            throw GestureProfileError.snapshotEncoding
        }
        try data.write(to: url, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

public enum GestureProfileStatus: Equatable {
    case notApplied
    case applied(verified: Bool)
}

public final class GestureCompatibilityManager {
    public static let preferences: [GesturePreference] = [
        GesturePreference(domain: "com.apple.dock", key: "showAppExposeGestureEnabled", disabledValue: .bool(false)),
        GesturePreference(domain: "com.apple.dock", key: "showMissionControlGestureEnabled", disabledValue: .bool(false)),
        GesturePreference(domain: "com.apple.dock", key: "showDesktopGestureEnabled", disabledValue: .bool(false)),
        GesturePreference(domain: "com.apple.dock", key: "showLaunchpadGestureEnabled", disabledValue: .bool(false)),
        GesturePreference(domain: "NSGlobalDomain", key: "AppleEnableSwipeNavigateWithScrolls", disabledValue: .bool(false)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.threeFingerHorizSwipeGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.fourFingerHorizSwipeGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.threeFingerVertSwipeGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.fourFingerVertSwipeGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.threeFingerDragGesture", disabledValue: .bool(false)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.threeFingerTapGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.fourFingerPinchSwipeGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.fiveFingerPinchSwipeGesture", disabledValue: .integer(0)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.pinchGesture", disabledValue: .bool(false)),
        GesturePreference(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.trackpad.rotateGesture", disabledValue: .bool(false)),
    ] + trackpadDevicePreferences(domain: "com.apple.AppleMultitouchTrackpad")
        + trackpadDevicePreferences(domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad")

    private static func trackpadDevicePreferences(domain: String) -> [GesturePreference] {
        [
            GesturePreference(domain: domain, key: "TrackpadThreeFingerDrag", disabledValue: .bool(false)),
            GesturePreference(domain: domain, key: "TrackpadThreeFingerVertSwipeGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadFourFingerVertSwipeGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadThreeFingerHorizSwipeGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadFourFingerHorizSwipeGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadFourFingerPinchGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadFiveFingerPinchGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadPinch", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadThreeFingerTapGesture", disabledValue: .integer(0)),
            GesturePreference(domain: domain, key: "TrackpadRotate", disabledValue: .integer(0)),
        ]
    }

    private let preferences: [GesturePreference]
    private let preferenceStore: GesturePreferenceStoring
    private let snapshotStore: GestureSnapshotStoring

    public init(
        preferences: [GesturePreference] = GestureCompatibilityManager.preferences,
        preferenceStore: GesturePreferenceStoring = DefaultsGesturePreferenceStore(),
        snapshotStore: GestureSnapshotStoring = FileGestureSnapshotStore()
    ) {
        self.preferences = preferences
        self.preferenceStore = preferenceStore
        self.snapshotStore = snapshotStore
    }

    public func status() throws -> GestureProfileStatus {
        guard try snapshotStore.load() != nil else { return .notApplied }
        return .applied(verified: try verify())
    }

    /// Saves original values before the first write, so a process crash can
    /// never erase the user's restore information.
    @discardableResult
    public func apply() throws -> Bool {
        if try snapshotStore.load() == nil {
            let entries = try preferences.map {
                GestureSnapshotEntry(address: $0.address, originalValue: try preferenceStore.value(at: $0.address))
            }
            try snapshotStore.save(GestureSnapshot(entries: entries))
        }
        for preference in preferences {
            try preferenceStore.set(preference.disabledValue, at: preference.address)
        }
        reloadGestureServices()
        return try verify()
    }

    /// Restores values exactly, including keys which did not exist before
    /// SideCursor was applied.
    @discardableResult
    public func restore() throws -> Bool {
        guard let snapshot = try snapshotStore.load() else { return false }
        for entry in snapshot.entries {
            if let value = entry.originalValue {
                try preferenceStore.set(value, at: entry.address)
            } else {
                try preferenceStore.removeValue(at: entry.address)
            }
        }
        try snapshotStore.remove()
        reloadGestureServices()
        return true
    }

    /// `cfprefsd` caches the per-host trackpad preferences and Dock owns the
    /// Mission Control, Space, App Expose, Show Desktop, and Launchpad
    /// gestures.  Restarting both applies the profile without requiring the
    /// user to sign out or reboot, which is why writing the keys alone left
    /// the old gestures running.
    private func reloadGestureServices() {
        runKillall("cfprefsd")
        Thread.sleep(forTimeInterval: 0.15)
        runKillall("Dock")
    }

    private func runKillall(_ processName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [processName]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    public func verify() throws -> Bool {
        for preference in preferences {
            guard try preferenceStore.value(at: preference.address) == preference.disabledValue else { return false }
        }
        return true
    }
}

public final class InMemoryGesturePreferenceStore: GesturePreferenceStoring {
    public var values: [PreferenceAddress: PreferenceValue] = [:]

    public init(values: [PreferenceAddress: PreferenceValue] = [:]) {
        self.values = values
    }

    public func value(at address: PreferenceAddress) throws -> PreferenceValue? { values[address] }
    public func set(_ value: PreferenceValue, at address: PreferenceAddress) throws { values[address] = value }
    public func removeValue(at address: PreferenceAddress) throws { values.removeValue(forKey: address) }
}

public final class InMemoryGestureSnapshotStore: GestureSnapshotStoring {
    public var snapshot: GestureSnapshot?

    public init(snapshot: GestureSnapshot? = nil) { self.snapshot = snapshot }
    public func load() throws -> GestureSnapshot? { snapshot }
    public func save(_ snapshot: GestureSnapshot) throws { self.snapshot = snapshot }
    public func remove() throws { snapshot = nil }
}
