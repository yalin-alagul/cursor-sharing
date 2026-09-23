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
        let route = makeUpper4KRoute()
        // maxX is 1733, so the last reachable pixel is 1732.
        XCTAssertTrue(route.crossesFromInside(CGPoint(x: 1732, y: -600), deltaX: 1))
        XCTAssertTrue(route.crossesFromInside(CGPoint(x: 1733, y: -600), deltaX: 1))
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 1732, y: -600), deltaX: -1))
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 1200, y: -600), deltaX: 10))
    }

    func testEdgeCrossingToleratesOvershootBeyondTheRightEdge() {
        let route = makeUpper4KRoute()
        // macOS can report the crossing sample a few pixels past the bounds.
        XCTAssertTrue(route.crossesFromInside(CGPoint(x: 1735, y: -600), deltaX: 1))
        XCTAssertTrue(route.crossesFromInside(CGPoint(x: 1750, y: -600), deltaX: 4))
        // A pointer already far to the right on another display must not hand off.
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 2200, y: -600), deltaX: 1))
    }

    func testEdgeCrossingUsesTrackedPreviousLocationWhenDeltaIsZero() {
        let route = makeUpper4KRoute()
        // The parked-at-the-edge sample often carries deltaX == 0.
        XCTAssertTrue(route.crossesFromInside(
            CGPoint(x: 1733, y: -600),
            deltaX: 0,
            previous: CGPoint(x: 1730, y: -600)
        ))
        XCTAssertTrue(route.crossesFromInside(
            CGPoint(x: 1735, y: -600),
            deltaX: 0,
            previous: CGPoint(x: 1732, y: -600)
        ))
        // Moving right but already far onto another display stays local.
        XCTAssertFalse(route.crossesFromInside(
            CGPoint(x: 2201, y: -600),
            deltaX: 0,
            previous: CGPoint(x: 2200, y: -600)
        ))
    }

    func testEdgeCrossingRejectsLeftwardAndOutOfRangeMotion() {
        let route = makeUpper4KRoute()
        XCTAssertFalse(route.crossesFromInside(
            CGPoint(x: 1732, y: -600),
            deltaX: 0,
            previous: CGPoint(x: 1735, y: -600)
        ))
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 1732, y: 10), deltaX: 5))
        XCTAssertFalse(route.crossesFromInside(CGPoint(x: 1732, y: -1200), deltaX: 5))
    }

    func testNearRightEdgeProbeBand() {
        let route = makeUpper4KRoute()
        XCTAssertTrue(route.isNearRightEdge(CGPoint(x: 1728, y: -600)))
        XCTAssertFalse(route.isNearRightEdge(CGPoint(x: 1600, y: -600)))
        XCTAssertFalse(route.isNearRightEdge(CGPoint(x: 1728, y: 10)))
    }

    private func makeUpper4KRoute() -> EdgeRoute {
        let display = DisplayDescriptor(
            stableID: "upper-4k",
            runtimeID: 2,
            name: "Upper display",
            bounds: DisplayBounds(x: -315, y: -1152, width: 2048, height: 1152),
            isBuiltIn: false,
            isMain: false
        )
        return EdgeRoute(display: display)
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

    func testThreeFingerSwipeMapsToWindowsCommands() {
        let hotkeys = RemoteHotkeys()
        func command(_ dx: Double, _ dy: Double) -> String? {
            MacVirtualKeyMapper.remoteGestureCommand(fingerDx: dx, fingerDy: dy, minimum: 6, hotkeys: hotkeys)
        }
        XCTAssertEqual(command(1, -28), "task_view")
        XCTAssertEqual(command(0, 40), "show_desktop")
        // Horizontal stays inverted: swiping left shows the desktop on the right.
        XCTAssertEqual(command(-28, 3), "desktop_right")
        XCTAssertEqual(command(65, 4), "desktop_left")
        XCTAssertNil(command(2, -4), "a small movement is not a swipe")
    }

    func testThreeFingerSwipeRespectsDisabledCommands() {
        let hotkeys = RemoteHotkeys(taskViewEnabled: false, showDesktopEnabled: false)
        XCTAssertNil(MacVirtualKeyMapper.remoteGestureCommand(fingerDx: 0, fingerDy: -30, minimum: 6, hotkeys: hotkeys))
        XCTAssertNil(MacVirtualKeyMapper.remoteGestureCommand(fingerDx: 0, fingerDy: 30, minimum: 6, hotkeys: hotkeys))
    }

    func testLargeClipboardSplitsIntoValidPartsAndReassembles() throws {
        // Multi-byte characters straddle the part boundary.
        let text = String(repeating: "Yalın 🙂 ", count: 20_000)
        let parts = ClipboardParts.split(text, maximumBytes: ProtocolV2.clipboardPartBytes)

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= ProtocolV2.clipboardPartBytes })
        XCTAssertEqual(parts.joined(), text)

        var assembler = ClipboardAssembler()
        let id = UUID()
        var result: String?
        for (index, part) in parts.enumerated() {
            result = assembler.add(
                ClipboardPart(origin: "mac", id: id, index: index, count: parts.count, text: part),
                maximumBytes: ProtocolV2.maximumClipboardBytes
            )
        }
        XCTAssertEqual(result, text)
    }

    func testClipboardAssemblerDropsSupersededOrOversizedTransfers() {
        var assembler = ClipboardAssembler()
        let first = UUID()
        let second = UUID()
        XCTAssertNil(assembler.add(ClipboardPart(origin: "w", id: first, index: 0, count: 2, text: "old "), maximumBytes: 100))
        // A new copy starts before the old one finished: only the new one lands.
        XCTAssertNil(assembler.add(ClipboardPart(origin: "w", id: second, index: 0, count: 2, text: "new "), maximumBytes: 100))
        XCTAssertNil(assembler.add(ClipboardPart(origin: "w", id: first, index: 1, count: 2, text: "tail"), maximumBytes: 100))
        XCTAssertNil(assembler.add(ClipboardPart(origin: "w", id: second, index: 1, count: 2, text: "text"), maximumBytes: 100))

        let third = UUID()
        XCTAssertNil(assembler.add(ClipboardPart(origin: "w", id: third, index: 0, count: 2, text: "12345"), maximumBytes: 8))
        XCTAssertNil(assembler.add(ClipboardPart(origin: "w", id: third, index: 1, count: 2, text: "67890"), maximumBytes: 8))
    }

    func testClipboardPartMatchesSharedProtocolShape() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(ProtocolMessage.clipboardPart(ClipboardPart(origin: "mac", id: id, index: 2, count: 5, text: "abc")))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "clipboard_part")
        XCTAssertEqual(object["index"] as? Int, 2)
        XCTAssertEqual(object["count"] as? Int, 5)
        XCTAssertEqual(try JSONDecoder().decode(ProtocolMessage.self, from: data), .clipboardPart(ClipboardPart(origin: "mac", id: id, index: 2, count: 5, text: "abc")))
    }

    func testZoomInputEventMatchesSharedProtocolShape() throws {
        let encoded = try JSONEncoder().encode(NativeInputEvent.zoom(steps: -2))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "zoom")
        XCTAssertEqual(object["steps"] as? Int, -2)

        let decoded = try JSONDecoder().decode(NativeInputEvent.self, from: Data(#"{"kind":"zoom","steps":3}"#.utf8))
        XCTAssertEqual(decoded, .zoom(steps: 3))
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

    /// Validates the shared fixture that both native suites must agree on,
    /// mirroring the Windows `MacInteropFixtureDerivesAndReadsTheExactV2Frame`
    /// test so the macOS side can no longer drift from `shared/protocol.md`.
    func testSharedInteropVectorsValidateNativeProtocol() throws {
        let root = try interopVectors()
        let pairingSecret = try vectorData(root, "pairingSecret")
        let serverPrivateBytes = try vectorData(root, "serverPrivate")
        let serverPublic = try vectorData(root, "serverPublic")
        let clientPublicBytes = try vectorData(root, "clientPublic")
        let serverNonce = try vectorData(root, "serverNonce")
        let clientNonce = try vectorData(root, "clientNonce")
        let expectedSessionKey = try vectorData(root, "sessionKey")
        let pairProof = try vectorData(root, "pairProof")
        let acceptProof = try vectorData(root, "acceptProof")

        let serverPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serverPrivateBytes)
        XCTAssertEqual(serverPrivate.publicKey.rawRepresentation, serverPublic)

        let expectedPairProof = ProtocolCrypto.hmac(
            key: SymmetricKey(data: pairingSecret),
            data: serverPublic + clientPublicBytes + serverNonce + clientNonce
        )
        XCTAssertEqual(expectedPairProof, pairProof)

        let clientPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicBytes)
        let sharedSecret = try serverPrivate.sharedSecretFromKeyAgreement(with: clientPublic)
        let sessionKey = ProtocolCrypto.deriveSessionKey(
            sharedSecret: sharedSecret,
            pairingSecret: pairingSecret,
            serverNonce: serverNonce,
            clientNonce: clientNonce
        )
        XCTAssertEqual(sessionKey.withUnsafeBytes { Data($0) }, expectedSessionKey)

        let expectedAcceptProof = ProtocolCrypto.hmac(key: sessionKey, data: Data("accept".utf8))
        XCTAssertEqual(expectedAcceptProof, acceptProof)

        // `frame.combined` is the AEAD body (nonce || ciphertext || tag); the
        // wire frame prepends the uint64-be sequence, exactly as
        // `EncryptedFrameCodec.open` expects.
        let frame = try XCTUnwrap(root["frame"] as? [String: Any])
        let sequence = try XCTUnwrap(frame["sequence"] as? NSNumber).uint64Value
        let combined = try vectorData(frame, "combined")
        var body = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            body.append(UInt8((sequence >> UInt64(shift)) & 0xff))
        }
        body.append(combined)

        var receiver = EncryptedFrameCodec(sessionKey: sessionKey)
        XCTAssertEqual(try receiver.open(body), .ping(sentAtMs: 123))
    }

    func testClientAndServerHandshakeAgreeOnSessionKey() throws {
        let pairingSecret = Data((0..<32).map(UInt8.init))
        let server = try ServerHandshake(pairingSecret: pairingSecret)
        let client = try ClientHandshake(hello: server.hello, pairingSecret: pairingSecret)
        let pair = client.makePairMessage()
        let (accept, serverKey) = try server.accept(pair)
        let clientKey = try client.complete(accept)

        XCTAssertEqual(
            serverKey.withUnsafeBytes { Data($0) },
            clientKey.withUnsafeBytes { Data($0) }
        )
    }

    private func interopVectors() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("shared/interop-vectors.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func vectorData(_ container: [String: Any], _ key: String) throws -> Data {
        let encoded = try XCTUnwrap(container[key] as? String)
        var padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return try XCTUnwrap(Data(base64Encoded: padded))
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
    func hideCursor(on display: DisplayDescriptor) { hideCount += 1 }
    func unhideCursor() { unhideCount += 1 }
    func warpMouse(to point: CGPoint) -> CGError {
        warpedPoints.append(point)
        return warpResult
    }
    var postedMoves: [CGPoint] = []
    func postPointerMove(to point: CGPoint) { postedMoves.append(point) }
}
