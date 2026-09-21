import AppKit
import Combine
import Foundation

/// Main-actor owner for user-visible state and the safety-critical ordering of
/// Windows acknowledgements, input suppression, cursor capture, and recovery.
@MainActor
public final class SessionController: ObservableObject {
    @Published public private(set) var phase: SessionPhase = .disconnected
    @Published public private(set) var statusMessage = "Not started"
    @Published public private(set) var lastError: String?
    @Published public private(set) var roundTripMilliseconds: Double?
    @Published public private(set) var isListening = false
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var gestureProfileStatus: GestureProfileStatus = .notApplied
    @Published public var configuration: SideCursorConfiguration {
        didSet {
            configurationStore.save(configuration)
            clipboard.maximumBytes = configuration.clipboardMaximumBytes
            refreshRoute()
        }
    }

    public var displays: [DisplayDescriptor] { DisplayCatalog.activeDisplays() }
    public var selectedRoute: EdgeRoute? { currentRoute }
    public var isInputTapRunning: Bool { inputTap.isRunning }
    public var hasPairingCode: Bool { (try? pairingSecretStore.load(account: configuration.pairingAccount)) != nil }

    private let configurationStore: ConfigurationStoring
    private let pairingSecretStore: PairingSecretStoring
    private let cursorController: CursorController
    private let clipboard: ClipboardMonitor
    private let gestureCompatibility: GestureCompatibilityManager
    private let inputGate = InputGate()
    private lazy var inputTap = InputEventTap(gate: inputGate) { [weak self] action in
        self?.handleInputAction(action)
    }
    private var machine = SessionMachine()
    private var currentRoute: EdgeRoute?
    private var listener: TCPListener?
    private var peer: EncryptedPeerConnection?
    private var activePeerID: UUID?
    private var pendingEnterID: UUID?
    private var entryTimeout: Timer?
    private var pingTimer: Timer?
    private var displayObserver: NSObjectProtocol?

    public init(
        configurationStore: ConfigurationStoring = UserDefaultsConfigurationStore(),
        pairingSecretStore: PairingSecretStoring = KeychainPairingSecretStore(),
        cursorController: CursorController = CursorController(),
        clipboard: ClipboardMonitor = ClipboardMonitor(),
        gestureCompatibility: GestureCompatibilityManager = GestureCompatibilityManager()
    ) {
        self.configurationStore = configurationStore
        self.pairingSecretStore = pairingSecretStore
        self.cursorController = cursorController
        self.clipboard = clipboard
        self.gestureCompatibility = gestureCompatibility
        configuration = configurationStore.load()
        clipboard.maximumBytes = configuration.clipboardMaximumBytes
        refreshRoute()
    }

    public func bootstrap() {
        refreshAccessibility()
        refreshRoute()
        refreshGestureProfileStatus()
        if displayObserver == nil {
            displayObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [self] in
                    self.handleDisplayConfigurationChanged()
                }
            }
        }
        clipboard.start { [weak self] text in
            guard let self else { return }
            Task { @MainActor [self] in
                self.sendLocalClipboard(text)
            }
        }
        statusMessage = accessibilityGranted
            ? "Ready to start a paired listener"
            : "Grant Accessibility access to enable input sharing"
    }

    public func refreshAccessibility() {
        accessibilityGranted = AccessibilityPermission.isGranted
    }

    public func requestAccessibilityAccess() {
        AccessibilityPermission.requestPrompt()
        statusMessage = "Allow SideCursor in Privacy & Security → Accessibility, then return here."
    }

    public func startInputCapture() {
        refreshAccessibility()
        guard accessibilityGranted else {
            lastError = InputTapError.accessibilityPermissionMissing.localizedDescription
            statusMessage = lastError ?? "Accessibility permission is required"
            return
        }
        do {
            try inputTap.start()
            statusMessage = phase == .remote ? "Remote input active" : "Input capture is ready"
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Input capture failed"
        }
    }

    public func stopInputCapture() {
        inputTap.stop()
        if phase == .remote || phase == .entering || phase == .returning {
            recover(reason: "Input capture was stopped")
        }
    }

    /// Starts the default encrypted Tailscale TCP listener, or opens the
    /// explicitly selected RFCOMM fallback.  No transport silently replaces
    /// another transport.
    public func startTransport() {
        guard let secret = loadPairingSecret() else { return }
        refreshRoute()
        guard currentRoute != nil else {
            lastError = "No active source display is available."
            statusMessage = lastError ?? "Display routing is unavailable"
            return
        }
        startInputCapture()

        stopTransport(transitionToDisconnected: false)
        do {
            try machine.transition(.beginConnecting)
            synchronizeGate()
        } catch {
            transitionToDisconnected()
            do { try machine.transition(.beginConnecting) } catch { return }
            synchronizeGate()
        }
        lastError = nil

        switch configuration.transport {
        case .tailscaleTCP:
            startTCP(secret: secret)
        case .bluetoothRFCOMM:
            startBluetooth(secret: secret)
        }
    }

    public func stopTransport() {
        stopTransport(transitionToDisconnected: true)
    }

    public func shutdown() {
        stopTransport(transitionToDisconnected: true)
        inputTap.stop()
        clipboard.stop()
        cursorController.forceRestore()
    }

    public func toggleRemoteMode() {
        switch phase {
        case .ready:
            requestEntry(y: 0.5)
        case .entering, .remote, .returning, .recovering:
            recover(reason: "Remote mode toggled off locally")
        case .connecting, .disconnected:
            statusMessage = "Connect a paired Windows companion before entering remote mode."
        }
    }

    public func generatePairingCode() -> String? {
        do {
            let secret = try PairingCode.generate()
            try pairingSecretStore.save(secret, account: configuration.pairingAccount)
            lastError = nil
            statusMessage = "New pairing code saved in Keychain. Share it only through a trusted channel."
            return try PairingCode.encode(secret)
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Could not create pairing code"
            return nil
        }
    }

    public func currentPairingCode() -> String? {
        do {
            guard let secret = try pairingSecretStore.load(account: configuration.pairingAccount) else { return nil }
            return try PairingCode.encode(secret)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func replacePairingCode(_ code: String) {
        do {
            let secret = try PairingCode.decode(code)
            try pairingSecretStore.save(secret, account: configuration.pairingAccount)
            lastError = nil
            statusMessage = "Pairing code saved in Keychain. Restart the transport to use it."
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Could not save pairing code"
        }
    }

    public func applyGestureCompatibilityProfile() {
        do {
            let verified = try gestureCompatibility.apply()
            gestureProfileStatus = .applied(verified: verified)
            statusMessage = verified
                ? "Gesture Compatibility Profile applied. Sign out or restart before testing system gestures."
                : "Gesture profile was saved, but macOS did not verify every setting."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Could not apply the gesture profile"
        }
    }

    public func restoreGestureCompatibilityProfile() {
        do {
            let restored = try gestureCompatibility.restore()
            gestureProfileStatus = .notApplied
            statusMessage = restored
                ? "Original gesture settings were restored. Sign out or restart before testing them."
                : "No SideCursor gesture snapshot was found."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Could not restore gesture settings"
        }
    }

    public func refreshGestureProfileStatus() {
        do {
            gestureProfileStatus = try gestureCompatibility.status()
        } catch {
            lastError = error.localizedDescription
            gestureProfileStatus = .notApplied
        }
    }

    public func selectSourceDisplay(_ stableID: String) {
        configuration.sourceDisplayID = stableID
    }

    /// Display identity or geometry changes while the cursor is captured are a
    /// mandatory recovery condition, never an opportunity to guess a new edge.
    public func handleDisplayConfigurationChanged() {
        let previousDisplayID = currentRoute?.display.stableID
        refreshRoute()
        if phase == .entering || phase == .remote || phase == .returning,
           currentRoute?.display.stableID != previousDisplayID {
            recover(reason: "The configured Mac display changed")
        }
    }

    private func startTCP(secret: Data) {
        let listener = TCPListener(port: UInt16(configuration.listenPort))
        self.listener = listener
        do {
            try listener.start(
                onListening: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isListening = true
                        self.statusMessage = "Listening for a paired Windows companion on TCP \(self.configuration.listenPort)."
                    }
                },
                onConnection: { [weak self] stream in
                    DispatchQueue.main.async { self?.accept(stream: stream, pairingSecret: secret) }
                },
                onFailure: { [weak self] error in
                    DispatchQueue.main.async { self?.transportFailed(error) }
                }
            )
        } catch {
            transportFailed(error)
        }
    }

    private func startBluetooth(secret: Data) {
        let rawAddress = configuration.bluetoothPeerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddress.isEmpty else {
            transportFailed(TransportError.bluetoothUnavailable("enter the paired Windows Bluetooth address first"))
            return
        }
        guard let address = BluetoothDeviceAddress.normalize(rawAddress) else {
            let detail = rawAddress.caseInsensitiveCompare(SideCursorBluetoothService.uuidString) == .orderedSame
                ? "the SideCursor service UUID is not a device address; enter the paired Windows address such as 54:14:F3:78:6E:D6"
                : "enter the paired Windows Bluetooth address in the form 54:14:F3:78:6E:D6"
            transportFailed(TransportError.bluetoothUnavailable(detail))
            return
        }
        isListening = false
        statusMessage = "Discovering the advertised SideCursor Bluetooth service on Windows…"
        let stream = BluetoothRFCOMMByteStream(address: address)
        accept(stream: stream, pairingSecret: secret)
    }

    private func accept(stream: RawByteStream, pairingSecret: Data) {
        peer?.close()
        let identifier = UUID()
        activePeerID = identifier
        let peer = EncryptedPeerConnection(stream: stream, pairingSecret: pairingSecret)
        self.peer = peer
        statusMessage = "Authenticating paired Windows companion…"
        peer.startAsServer(
            onReady: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.activePeerID == identifier else { return }
                    switch result {
                    case .success:
                        do {
                            try self.machine.transition(.peerReady)
                            self.phase = self.machine.phase
                            self.synchronizeGate()
                            self.statusMessage = self.inputTap.isRunning
                                ? "Paired Windows companion is ready."
                                : "Paired Windows companion is ready; grant Accessibility to enable input sharing."
                            self.startPingTimer()
                        } catch {
                            self.recover(reason: error.localizedDescription)
                        }
                    case let .failure(error):
                        self.transportFailed(error)
                    }
                }
            },
            onMessage: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.activePeerID == identifier else { return }
                    self.handleMessage(message)
                }
            },
            onClosed: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.activePeerID == identifier else { return }
                    self.peer = nil
                    self.activePeerID = nil
                    self.stopPingTimer()
                    if self.phase != .disconnected {
                        self.recover(reason: error?.localizedDescription ?? "Peer disconnected")
                    }
                }
            }
        )
    }

    private func requestEntry(y: Double) {
        guard phase == .ready, let peer, let route = currentRoute else { return }
        do {
            try machine.transition(.requestEntry)
            phase = machine.phase
            synchronizeGate()
            let identifier = UUID()
            pendingEnterID = identifier
            let source = InputSource(
                display: route.display.stableID,
                width: max(1, Int(route.display.bounds.width.rounded())),
                height: max(1, Int(route.display.bounds.height.rounded()))
            )
            peer.send(.enterRequest(EnterRequest(id: identifier, y: y, source: source)))
            entryTimeout?.invalidate()
            entryTimeout = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [self] in
                    guard self.phase == .entering, self.pendingEnterID == identifier else { return }
                    self.recover(reason: "Windows did not acknowledge entry; Mac control stayed local.")
                }
            }
            statusMessage = "Waiting for Windows to acknowledge remote entry…"
        } catch {
            recover(reason: error.localizedDescription)
        }
    }

    private func handleMessage(_ message: ProtocolMessage) {
        switch message {
        case let .enterAck(id):
            guard phase == .entering, id == pendingEnterID, let route = currentRoute else { return }
            entryTimeout?.invalidate()
            entryTimeout = nil
            do {
                try cursorController.capture(on: route.display)
                try machine.transition(.cursorCaptured)
                phase = machine.phase
                pendingEnterID = nil
                synchronizeGate()
                statusMessage = "Remote mode: Windows receives cursor, keyboard, and two-finger scroll."
            } catch {
                peer?.send(.releaseAll(reason: "macOS cursor capture failed"))
                recover(reason: error.localizedDescription)
            }
        case let .enterReject(id, reason):
            guard id == pendingEnterID else { return }
            entryTimeout?.invalidate()
            entryTimeout = nil
            pendingEnterID = nil
            recover(reason: "Windows rejected remote entry: \(reason)")
        case let .returnRequest(id, y):
            guard phase == .remote else { return }
            do {
                try machine.transition(.requestReturn)
                phase = machine.phase
                synchronizeGate()
                try cursorController.release(returnY: y, inset: configuration.returnInset)
                inputGate.blockNewHandoffs(for: 0.75)
                peer?.send(.returnAck(id: id))
                try machine.transition(.returnAcknowledged)
                phase = machine.phase
                pendingEnterID = nil
                synchronizeGate()
                statusMessage = "Returned to Mac control."
            } catch {
                recover(reason: error.localizedDescription)
            }
        case .returnAck:
            // A Windows-initiated return is the normal direction.  This is
            // reserved for a future manual Windows confirmation flow.
            break
        case let .input(event):
            // Mac is intentionally source-only for input in this companion.
            lastError = "Ignored unexpected input from Windows: \(event)"
        case let .command(name):
            lastError = "Ignored unexpected command from Windows: \(name)"
        case .releaseAll:
            recover(reason: "Windows released the remote session")
        case let .clipboard(origin, text):
            guard configuration.clipboardEnabled,
                  origin != configuration.pairingAccount,
                  text.lengthOfBytes(using: .utf8) <= configuration.clipboardMaximumBytes
            else { return }
            clipboard.applyRemoteText(text)
        case let .ping(sentAtMs):
            peer?.send(.pong(sentAtMs: sentAtMs))
        case let .pong(sentAtMs):
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            roundTripMilliseconds = max(0, Double(now - sentAtMs))
        case .enterRequest:
            peer?.send(.enterReject(id: UUID(), reason: "Mac is source-only"))
        }
    }

    private func handleInputAction(_ action: InputTapAction) {
        switch action {
        case let .edgeCrossed(y):
            requestEntry(y: y)
        case let .input(event):
            guard phase == .remote else { return }
            peer?.send(.input(scale(event)))
        case let .command(name):
            guard phase == .remote else { return }
            peer?.send(.command(name: name))
        case .panicHotkey:
            toggleRemoteMode()
        case let .tapFailure(reason):
            recover(reason: reason)
        }
    }

    private func scale(_ event: NativeInputEvent) -> NativeInputEvent {
        guard case let .pointer(dx, dy) = event else { return event }
        let scale = configuration.pointerScale
        return .pointer(
            dx: Int((Double(dx) * scale).rounded()),
            dy: Int((Double(dy) * scale).rounded())
        )
    }

    private func sendLocalClipboard(_ text: String) {
        guard configuration.clipboardEnabled,
              text.lengthOfBytes(using: .utf8) <= configuration.clipboardMaximumBytes,
              peer != nil
        else { return }
        peer?.send(.clipboard(origin: configuration.pairingAccount, text: text))
    }

    private func recover(reason: String) {
        entryTimeout?.invalidate()
        entryTimeout = nil
        pendingEnterID = nil
        if phase != .recovering && phase != .disconnected {
            try? machine.transition(.recover)
            phase = machine.phase
            synchronizeGate()
        }
        peer?.send(.releaseAll(reason: reason))
        cursorController.forceRestore()
        inputGate.blockNewHandoffs(for: 0.75)
        if phase == .recovering {
            try? machine.transition(.localInputRestored)
            phase = machine.phase
        }
        if peer == nil, isListening {
            try? machine.transition(.beginConnecting)
            phase = machine.phase
        }
        synchronizeGate()
        lastError = reason
        statusMessage = peer == nil && isListening
            ? "Waiting for Windows after recovery: \(reason)"
            : "Local Mac control restored: \(reason)"
    }

    private func transportFailed(_ error: Error) {
        peer?.close()
        peer = nil
        activePeerID = nil
        stopPingTimer()
        recover(reason: error.localizedDescription)
    }

    private func stopTransport(transitionToDisconnected shouldTransitionToDisconnected: Bool) {
        entryTimeout?.invalidate()
        entryTimeout = nil
        stopPingTimer()
        listener?.stop()
        listener = nil
        isListening = false
        let oldPeer = peer
        peer = nil
        activePeerID = nil
        if phase == .remote || phase == .entering || phase == .returning {
            oldPeer?.send(.releaseAll(reason: "Mac transport stopped"))
        }
        oldPeer?.close()
        cursorController.forceRestore()
        inputGate.blockNewHandoffs(for: 0.75)
        if shouldTransitionToDisconnected {
            transitionToDisconnected()
            statusMessage = "Transport stopped; local Mac control is active."
        }
    }

    private func transitionToDisconnected() {
        try? machine.transition(.disconnect)
        phase = machine.phase
        synchronizeGate()
    }

    private func synchronizeGate() {
        inputGate.update(phase: phase, route: currentRoute, hotkeys: configuration.remoteHotkeys)
    }

    private func refreshRoute() {
        let currentDisplays = DisplayCatalog.activeDisplays()
        if configuration.sourceDisplayID == nil,
           let defaultDisplay = DisplayCatalog.defaultSourceDisplay(from: currentDisplays) {
            configuration.sourceDisplayID = defaultDisplay.stableID
            return
        }
        currentRoute = DisplayCatalog.route(configuration: configuration, displays: currentDisplays)
        synchronizeGate()
    }

    private func loadPairingSecret() -> Data? {
        do {
            guard let secret = try pairingSecretStore.load(account: configuration.pairingAccount) else {
                lastError = "Create or enter a pairing code in Settings before starting a transport."
                statusMessage = lastError ?? "Pairing code is required"
                return nil
            }
            guard secret.count == 32 else { throw PairingStoreError.invalidCode }
            return secret
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Could not load pairing code"
            return nil
        }
    }

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                guard self.peer != nil else { return }
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                self.peer?.send(.ping(sentAtMs: now))
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        roundTripMilliseconds = nil
    }

    deinit {
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
        }
    }
}
