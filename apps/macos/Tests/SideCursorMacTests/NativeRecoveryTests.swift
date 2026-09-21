import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import SideCursorCore

final class NativeRecoveryTests: XCTestCase {
    func testSessionRequiresCursorCaptureBeforeRemote() throws {
        var machine = SessionMachine()
        try machine.transition(.beginConnecting)
        try machine.transition(.peerReady)
        try machine.transition(.requestEntry)
        try machine.transition(.entryAcknowledged)
        XCTAssertEqual(machine.phase, .entering)
        try machine.transition(.cursorCaptured)
        XCTAssertEqual(machine.phase, .remote)
    }

    func testRecoveryAlwaysReturnsToReady() throws {
        var machine = SessionMachine(phase: .remote)
        try machine.transition(.recover)
        XCTAssertEqual(machine.phase, .recovering)
        try machine.transition(.localInputRestored)
        XCTAssertEqual(machine.phase, .ready)
    }

    func testSelectedDisplayEdgeOnlyCrossesOnRightwardMotion() {
        let display = DisplayDescriptor(
            stableID: "upper-4k",
            runtimeID: 2,
            name: "Upper display",
            bounds: DisplayBounds(x: -315, y: -1152, width: 2048, height: 1152),
            isBuiltIn: false,
            isMain: false
        )
        let route = EdgeRoute(display: display)
        XCTAssertTrue(route.crossesFromInside(CGPoint(x: 1732, y: -600), deltaX: 1))
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 1732, y: -600), deltaX: -1))
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 1200, y: -600), deltaX: 10))
    }

    func testSavedDisplayRouteDoesNotFallBackWhenThatDisplayIsMissing() {
        let chosen = makeDisplay()
        let other = DisplayDescriptor(
            stableID: "other",
            runtimeID: 9,
            name: "Other display",
            bounds: DisplayBounds(x: 2048, y: 0, width: 1920, height: 1080),
            isBuiltIn: false,
            isMain: true
        )
        var configuration = SideCursorConfiguration()
        configuration.sourceDisplayID = chosen.stableID

        XCTAssertNil(DisplayCatalog.route(configuration: configuration, displays: [other]))
        XCTAssertEqual(DisplayCatalog.route(configuration: configuration, displays: [chosen, other])?.display.stableID, chosen.stableID)
    }

    func testClipboardLoopGuardSuppressesOnlyReturnedRemoteText() {
        var guardState = ClipboardLoopGuard()
        guardState.markRemoteText("from windows")
        XCTAssertFalse(guardState.shouldForwardLocalText("from windows"))
        XCTAssertTrue(guardState.shouldForwardLocalText("new local text"))
        XCTAssertFalse(guardState.shouldForwardLocalText("new local text"))
    }

    func testPairingCodeRoundTripsExactlyThirtyTwoBytes() throws {
        let original = Data((0..<32).map(UInt8.init))
        let code = try PairingCode.encode(original)
        XCTAssertEqual(try PairingCode.decode(code), original)
    }

    func testEncryptedFrameRejectsReplay() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        var sender = EncryptedFrameCodec(sessionKey: key)
        let frame = try sender.seal(.ping(sentAtMs: 123))
        var receiver = EncryptedFrameCodec(sessionKey: key)
        XCTAssertEqual(try receiver.open(frame), .ping(sentAtMs: 123))
        XCTAssertThrowsError(try receiver.open(frame))
    }

    func testCursorCaptureBalancesOneHideAndOneShow() throws {
        let platform = FakeCursorPlatform()
        let controller = CursorController(platform: platform)
        let display = makeDisplay()

        try controller.capture(on: display)
        XCTAssertTrue(controller.isCaptured)
        XCTAssertEqual(platform.hideCount, 1)
        XCTAssertEqual(platform.unhideCount, 0)
        XCTAssertEqual(platform.disassociateCount, 1)

        try controller.release(returnY: 0.4, inset: 24)
        XCTAssertFalse(controller.isCaptured)
        XCTAssertEqual(platform.hideCount, 1)
        XCTAssertEqual(platform.unhideCount, 1)
        XCTAssertEqual(platform.associateCount, 1)
        XCTAssertEqual(platform.warpedPoints.count, 1)
    }

    func testCursorRecoveryRestoresInputEvenWhenWarpFails() throws {
        let platform = FakeCursorPlatform()
        platform.warpResult = .failure
        let controller = CursorController(platform: platform)
        try controller.capture(on: makeDisplay())

        controller.forceRestore()

        XCTAssertFalse(controller.isCaptured)
        XCTAssertEqual(platform.hideCount, 1)
        XCTAssertEqual(platform.unhideCount, 1)
        XCTAssertGreaterThanOrEqual(platform.associateCount, 1)
    }

    func testGestureProfileBacksUpAndRestoresAbsentAndPresentValues() throws {
        let present = PreferenceAddress(domain: "test.domain", key: "present")
        let missing = PreferenceAddress(domain: "test.domain", key: "missing")
        let preferences = [
            GesturePreference(domain: present.domain, key: present.key, disabledValue: .integer(0)),
            GesturePreference(domain: missing.domain, key: missing.key, disabledValue: .bool(false)),
        ]
        let store = InMemoryGesturePreferenceStore(values: [present: .integer(2)])
        let snapshots = InMemoryGestureSnapshotStore()
        let manager = GestureCompatibilityManager(
            preferences: preferences,
            preferenceStore: store,
            snapshotStore: snapshots
        )

        XCTAssertTrue(try manager.apply())
        XCTAssertEqual(try store.value(at: present), .integer(0))
        XCTAssertEqual(try store.value(at: missing), .bool(false))
        XCTAssertTrue(try manager.restore())
        XCTAssertEqual(try store.value(at: present), .integer(2))
        XCTAssertNil(try store.value(at: missing))
        XCTAssertNil(try snapshots.load())
    }

    func testConfigurationClampsReturnInsetWithoutChangingNaturalPointerDefault() {
        let configuration = SideCursorConfiguration(returnInset: -10)
        XCTAssertEqual(configuration.pointerScale, 1.0)
        XCTAssertEqual(configuration.returnInset, 4)
    }

    func testBluetoothServiceIdentifierStaysInSyncWithNativeTransport() {
        XCTAssertEqual(
            SideCursorBluetoothService.uuid.uuidString.uppercased(),
            "2A99401E-C4A4-4CD4-9AB1-8090C2444BB6"
        )
    }

    func testBluetoothDeviceAddressRejectsServiceUUIDAndNormalizesRadioAddress() {
        XCTAssertNil(BluetoothDeviceAddress.normalize(SideCursorBluetoothService.uuidString))
        XCTAssertEqual(
            BluetoothDeviceAddress.normalize("54-14-f3-78-6e-d6"),
            "54:14:F3:78:6E:D6"
        )
        XCTAssertNil(BluetoothDeviceAddress.normalize("54:14:F3:78:6E"))
    }

    func testBluetoothServiceDiscoveryWhenExplicitHardwareProbeIsEnabled() {
        guard ProcessInfo.processInfo.environment["SIDECURSOR_RUN_BLUETOOTH_HARDWARE_TEST"] == "1",
              let address = ProcessInfo.processInfo.environment["SIDECURSOR_BLUETOOTH_ADDRESS"],
              !address.isEmpty
        else {
            return
        }

        let encryptedRoundTrip = expectation(description: "Windows SideCursor completed an encrypted Bluetooth ping/pong")
        let stream = BluetoothRFCOMMByteStream(address: address)
        let connection = EncryptedPeerConnection(
            stream: stream,
            pairingSecret: Data((0..<32).map(UInt8.init))
        )
        connection.startAsServer(
            onReady: { result in
                switch result {
                case .success:
                    connection.send(.ping(sentAtMs: 424_242))
                case let .failure(error):
                    XCTFail("Bluetooth SDP/RFCOMM probe failed: \(error)")
                    encryptedRoundTrip.fulfill()
                }
            },
            onMessage: { message in
                guard case let .pong(sentAtMs) = message else {
                    XCTFail("Bluetooth probe received an unexpected encrypted message: \(message)")
                    return
                }
                XCTAssertEqual(sentAtMs, 424_242)
                encryptedRoundTrip.fulfill()
            },
            onClosed: { error in
                if let error {
                    XCTFail("Bluetooth encrypted probe closed unexpectedly: \(error)")
                }
            }
        )
        wait(for: [encryptedRoundTrip], timeout: 12)
        connection.close()
    }

    func testTailscaleEncryptedLatencyWhenExplicitHardwareProbeIsEnabled() throws {
        guard ProcessInfo.processInfo.environment["SIDECURSOR_RUN_TAILSCALE_HARDWARE_TEST"] == "1",
              let portText = ProcessInfo.processInfo.environment["SIDECURSOR_TAILSCALE_PORT"],
              let port = UInt16(portText)
        else {
            return
        }

        let listening = expectation(description: "Mac TCP listener is ready")
        let completed = expectation(description: "Windows returned all encrypted TCP probe pongs")
        let listener = TCPListener(port: port)
        var peer: EncryptedPeerConnection?
        var sentAt: [Int64: UInt64] = [:]
        var samples: [Double] = []
        let sampleCount: Int64 = 25

        func sendProbe(_ sequence: Int64) {
            sentAt[sequence] = DispatchTime.now().uptimeNanoseconds
            peer?.send(.ping(sentAtMs: sequence))
        }

        try listener.start(
            onListening: {
                print("SIDECURSOR_TAILSCALE_LISTENING")
                listening.fulfill()
            },
            onConnection: { stream in
                let connection = EncryptedPeerConnection(
                    stream: stream,
                    pairingSecret: Data((0..<32).map(UInt8.init))
                )
                peer = connection
                connection.startAsServer(
                    onReady: { result in
                        switch result {
                        case .success:
                            sendProbe(0)
                        case let .failure(error):
                            XCTFail("Tailscale encrypted probe failed before ready: \(error)")
                            completed.fulfill()
                        }
                    },
                    onMessage: { message in
                        guard case let .pong(sentAtMs) = message,
                              let started = sentAt.removeValue(forKey: sentAtMs)
                        else {
                            XCTFail("Tailscale probe received an unexpected encrypted message: \(message)")
                            return
                        }

                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                        samples.append(elapsed)
                        if sentAtMs + 1 < sampleCount {
                            sendProbe(sentAtMs + 1)
                            return
                        }

                        let p95Index = Int(ceil(Double(samples.count) * 0.95)) - 1
                        let p95 = samples.sorted()[p95Index]
                        print("SIDECURSOR_TAILSCALE_P95_MS \(String(format: "%.2f", p95))")
                        XCTAssertLessThan(p95, 50, "Encrypted Tailscale p95 must remain below 50 ms on this direct route.")
                        completed.fulfill()
                    },
                    onClosed: { error in
                        if let error {
                            XCTFail("Tailscale encrypted probe closed unexpectedly: \(error)")
                        }
                    }
                )
            },
            onFailure: { error in
                XCTFail("Tailscale probe listener failed: \(error)")
                listening.fulfill()
                completed.fulfill()
            }
        )
        wait(for: [listening, completed], timeout: 25)
        peer?.close()
        listener.stop()
    }

    private func makeDisplay() -> DisplayDescriptor {
        DisplayDescriptor(
            stableID: "source",
            runtimeID: 1,
            name: "Source",
            bounds: DisplayBounds(x: 0, y: 0, width: 2048, height: 1152),
            isBuiltIn: false,
            isMain: false
        )
    }
}

private final class FakeCursorPlatform: CursorPlatform {
    var hideCount = 0
    var unhideCount = 0
    var disassociateCount = 0
    var associateCount = 0
    var warpedPoints: [CGPoint] = []
    var warpResult: CGError = .success

    func rememberFrontmostApplication() {}
    func restoreRememberedApplication() {}
    func disassociateMouse() -> CGError {
        disassociateCount += 1
        return .success
    }
    func associateMouse() -> CGError {
        associateCount += 1
        return .success
    }
    func hideCursor() { hideCount += 1 }
    func unhideCursor() { unhideCount += 1 }
    func warpMouse(to point: CGPoint) -> CGError {
        warpedPoints.append(point)
        return warpResult
    }
}
