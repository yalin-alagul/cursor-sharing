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
    @Published public private(set) var inputMonitoringGranted = false
    @Published public private(set) var gestureProfileStatus: GestureProfileStatus = .notApplied
    @Published public private(set) var handoffDebug: String?
    @Published public var configuration: SideCursorConfiguration {
        didSet {
            configurationStore.save(configuration)
            clipboard.maximumBytes = configuration.clipboardMaximumBytes
            refreshRoute()
        }
    }

    public var displays: [DisplayDescriptor] { DisplayCatalog.activeDisplays() }
    public var isInputTapRunning: Bool { inputTap.isRunning }
    public var isInputTapFiltering: Bool { inputTap.isFiltering }

    /// Short guard after a return so the release warp cannot immediately
    /// re-trigger a handoff, without making back-and-forth crossings feel
    /// laggy.
    private static let handoffReentryDelay: TimeInterval = 0.2

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
    private var lastPongAt: Date?
    private var displayObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var permissionPollTimer: Timer?
    private var didAttemptFilteringUpgrade = false

    private static let diagnosticsLogURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SideCursor/diagnostics.log")
    }()

    private func logDiagnostic(_ message: String) {
        let url = Self.diagnosticsLogURL
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

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
        // An applied Gesture Compatibility Profile is intentionally persistent,
        // matching the Settings copy ("Sign out or restart after applying or
        // restoring").  It is undone only when the user chooses Restore.
        // A rebuilt ad-hoc-signed app loses its Accessibility grant.  Ask once
        // at launch so SideCursor is listed for the user to enable, then start
        // the event tap as soon as the grant appears.
        if !accessibilityGranted {
            AccessibilityPermission.requestPrompt()
        } else if !inputMonitoringGranted {
            AccessibilityPermission.requestInputMonitoring()
        }
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
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [self] in
                    // Only react to grants the user has already made; do not
                    // re-prompt on every activation. The launch-time prompt and
                    // the Settings "Request permission" button cover prompting.
                    self.refreshAccessibilityAndCapture()
                }
            }
        }
        startPermissionPolling()
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

    /// Re-reads the Accessibility state and starts the event tap when it has
    /// just become available.  Safe to call repeatedly.
    public func refreshAccessibilityAndCapture() {
        let wasGranted = accessibilityGranted
        let wasMonitoring = inputMonitoringGranted
        refreshAccessibility()
        let permissionChanged = accessibilityGranted != wasGranted || inputMonitoringGranted != wasMonitoring
        if permissionChanged {
            // A fresh grant must re-attempt the filtering upgrade even if an
            // earlier attempt ran before Input Monitoring was available.
            didAttemptFilteringUpgrade = false
        }
        if accessibilityGranted, !inputTap.isRunning {
            startInputCapture()
        } else if accessibilityGranted, inputMonitoringGranted,
                  !inputTap.isFiltering, !didAttemptFilteringUpgrade {
            // Recreate the tap in place (without disturbing the session) if the
            // system ever hands us a non-filtering one.
            didAttemptFilteringUpgrade = true
            upgradeTapToFiltering()
        }
        if permissionChanged {
            // Losing the ability to suppress local input while Windows owns it
            // is a mandatory recovery condition: macOS would otherwise stop
            // honoring our event suppression while the session still believed
            // input was remote.  `stopInputCapture()` releases Windows input
            // and returns control to the Mac.
            let lostRequiredPermission = (wasGranted && !accessibilityGranted)
                || (wasMonitoring && !inputMonitoringGranted)
            if lostRequiredPermission, phase == .entering || phase == .remote || phase == .returning {
                stopInputCapture()
                return
            }
            synchronizeGate()
        }
    }

    private func upgradeTapToFiltering() {
        do {
            try inputTap.start()
            if inputTap.isFiltering {
                statusMessage = phase == .remote ? "Remote input active" : "Input capture is ready"
            } else {
                statusMessage = "Input capture is listen-only; restart SideCursor so macOS can install a filtering tap."
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = lastError ?? "Input capture failed"
        }
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                // Never request from the background; only react to grants the
                // user has already made.
                self.refreshAccessibilityAndCapture()
            }
        }
    }

    public func refreshAccessibility() {
        accessibilityGranted = AccessibilityPermission.isGranted
        inputMonitoringGranted = AccessibilityPermission.inputMonitoringGranted
    }

    public func requestAccessibilityAccess() {
        requestMissingPermissions()
        statusMessage = "Allow SideCursor under Privacy & Security (Device Control and Data Access and Input Monitoring), then return here."
    }

    /// Requests any permission SideCursor is still missing.  Call only while
    /// the app's own UI is frontmost so the prompt is attributable to it.
    public func requestMissingPermissions() {
        refreshAccessibility()
        NSApp.activate(ignoringOtherApps: true)
        if !accessibilityGranted {
            AccessibilityPermission.requestPrompt()
        } else if !inputMonitoringGranted {
            AccessibilityPermission.requestInputMonitoring()
        }
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
        cursorController.forceRestore(inset: configuration.returnInset)
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    /// Returns control to the Mac. It is deliberately not a toggle: it can only
    /// leave a remote-owned state, never enter one. The panic hotkey and the
    /// "Return control to Mac" button share this path so neither can surprise
    /// the user by starting a remote session.
    public func returnToLocalControl() {
        switch phase {
        case .entering, .remote, .returning, .recovering:
            recover(reason: "Remote mode toggled off locally")
        case .ready, .connecting, .disconnected:
            break
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
                ? "Gesture Compatibility Profile applied; conflicting system gestures are disabled."
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
                ? "Original gesture settings were restored."
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
                            self.updateHandoffRouteDebug()
                            self.lastPongAt = Date()
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
        // Never suppress input non-exclusively: if macOS handed us a
        // listen-only tap (Input Monitoring not granted), entering Remote would
        // forward to Windows while the Mac keyboard also stays live. Refuse the
        // handoff and keep local control instead.
        guard inputTap.isFiltering else {
            let message = "Input capture is listen-only. Grant Input Monitoring so macOS can install a filtering tap, then try again."
            lastError = message
            statusMessage = message
            return
        }
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
                let t0 = Date()
                try machine.transition(.requestReturn)
                phase = machine.phase
                synchronizeGate()
                try cursorController.release(returnY: y, inset: configuration.returnInset)
                let t1 = Date()
                // The return inset already parks the pointer a few pixels
                // inside the source display, and the release warp moves left,
                // so it cannot re-trigger a handoff. Do not add a re-entry
                // delay here: the connection stays up in Ready and remote mode
                // must be re-enterable the instant the pointer reaches the far
                // right edge again.
                peer?.send(.returnAck(id: id))
                try machine.transition(.returnAcknowledged)
                phase = machine.phase
                pendingEnterID = nil
                synchronizeGate()
                let t2 = Date()
                logDiagnostic(String(
                    format: "return release=%.1fms ack+ready=%.1fms total=%.1fms",
                    t1.timeIntervalSince(t0) * 1_000,
                    t2.timeIntervalSince(t1) * 1_000,
                    t2.timeIntervalSince(t0) * 1_000
                ))
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
            // A Windows-initiated release is a normal end to remote mode, not a
            // failure, so it must not light up the Diagnostics error text.
            recover(reason: "Windows released the remote session", isError: false)
        case let .clipboard(origin, text):
            guard configuration.clipboardEnabled,
                  origin != configuration.pairingAccount,
                  text.lengthOfBytes(using: .utf8) <= configuration.clipboardMaximumBytes
            else { return }
            clipboard.applyRemoteText(text)
        case let .ping(sentAtMs):
            peer?.send(.pong(sentAtMs: sentAtMs))
        case let .pong(sentAtMs):
            // `sentAtMs` is peer-supplied.  Subtract with overflow reporting so
            // a hostile or buggy value (for example Int64.min) cannot trap.
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let (elapsed, overflow) = now.subtractingReportingOverflow(sentAtMs)
            if !overflow, elapsed >= 0 {
                roundTripMilliseconds = Double(elapsed)
            }
            lastPongAt = Date()
        case let .enterRequest(request):
            // Echo the request id so the peer can correlate the rejection, per
            // shared/protocol.md.
            peer?.send(.enterReject(id: request.id, reason: "Mac is source-only"))
        }
    }

    private func handleInputAction(_ action: InputTapAction) {
        switch action {
        case let .edgeCrossed(y):
            handoffDebug = String(format: "edge crossed at y=%.2f", y)
            requestEntry(y: y)
        case let .input(event):
            guard phase == .remote else { return }
            peer?.send(.input(scale(event)))
        case let .command(name):
            guard phase == .remote else { return }
            peer?.send(.command(name: name))
        case .panicHotkey:
            returnToLocalControl()
        case let .tapFailure(reason):
            recover(reason: reason)
        case let .handoffProbe(x, y, deltaX, previousX, minX, maxX):
            guard phase == .ready else { return }
            let prior = previousX.map { String(format: "%.0f", $0) } ?? "nil"
            handoffDebug = String(
                format: "ready x=%.0f y=%.0f dx=%lld prior=%@ range=[%.0f, %.0f]",
                x, y, deltaX, prior, minX, maxX
            )
        }
    }

    /// Records the resolved handoff route so the Diagnostics tab can show what
    /// the pointer is actually compared against.
    private func updateHandoffRouteDebug() {
        guard let route = currentRoute else {
            handoffDebug = "no active handoff route"
            return
        }
        let bounds = route.display.bounds
        handoffDebug = String(
            format: "route %@ x=[%.0f, %.0f] y=[%.0f, %.0f]",
            route.display.name, bounds.x, bounds.maxX, bounds.y, bounds.maxY
        )
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

    private func recover(reason: String, isError: Bool = true) {
        entryTimeout?.invalidate()
        entryTimeout = nil
        pendingEnterID = nil
        if phase != .recovering && phase != .disconnected {
            try? machine.transition(.recover)
            phase = machine.phase
            synchronizeGate()
        }
        peer?.send(.releaseAll(reason: reason))
        cursorController.forceRestore(inset: configuration.returnInset)
        inputGate.blockNewHandoffs(for: Self.handoffReentryDelay)
        if phase == .recovering {
            try? machine.transition(.localInputRestored)
            phase = machine.phase
        }
        if peer == nil, isListening {
            try? machine.transition(.beginConnecting)
            phase = machine.phase
        }
        synchronizeGate()
        lastError = isError ? reason : nil
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
        cursorController.forceRestore(inset: configuration.returnInset)
        inputGate.blockNewHandoffs(for: Self.handoffReentryDelay)
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
                // If Windows stops answering while it owns input, the Mac would
                // otherwise keep suppressing the cursor and keyboard forever
                // with no way back except replugging the peer.  Force local
                // control back instead.
                if let lastPongAt = self.lastPongAt,
                   self.phase == .remote || self.phase == .entering || self.phase == .returning,
                   Date().timeIntervalSince(lastPongAt) > 6 {
                    self.recover(reason: "Windows stopped responding to keepalive")
                    return
                }
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                self.peer?.send(.ping(sentAtMs: now))
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        roundTripMilliseconds = nil
        lastPongAt = nil
    }

    deinit {
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
