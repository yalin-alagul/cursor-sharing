import AppKit
import Combine
import Foundation
import SideCursorCore
import SwiftUI

@main
struct SideCursorMacApp: App {
    @StateObject private var model = SideCursorAppModel()

    var body: some Scene {
        MenuBarExtra("SideCursor", systemImage: model.menuIcon) {
            StatusMenuView(model: model)
                .onAppear {
                    model.start()
                    model.session.refreshAccessibilityAndCapture()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 700, minHeight: 560)
        }
    }
}

@MainActor
final class SideCursorAppModel: ObservableObject {
    let session = SideCursorCore.SessionController()

    @Published private(set) var displays: [SideCursorCore.DisplayDescriptor] = []
    @Published private(set) var pairingCode = ""
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var started = false

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var bootstrapped = false

    init() {
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        session.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.appendDiagnostic(message) }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.refreshDisplays()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.shutdown()
            }
        })
        refreshDisplays()
        refreshPairingCode()
        // A MenuBarExtra's content can be lazily created on first click. Start
        // the safe bootstrap at app launch instead, so an already-paired Mac
        // listener is available without first opening the menu. If no pairing
        // code exists, start() only reports that setup is required.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.start()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var menuIcon: String {
        switch session.phase {
        case .ready: return "cursorarrow.rays"
        case .remote: return "cursorarrow.motionlines"
        case .disconnected: return "cursorarrow.slash"
        case .connecting, .entering, .returning, .recovering: return "cursorarrow"
        }
    }

    var statusColor: Color {
        switch session.phase {
        case .ready: return .green
        case .remote: return .blue
        case .disconnected: return .red
        case .connecting, .entering, .returning, .recovering: return .orange
        }
    }

    func start() {
        guard !started else { return }
        session.bootstrap()
        refreshDisplays()
        session.startTransport()
        started = true
    }

    func restartTransport() {
        guard started else {
            start()
            return
        }
        session.stopTransport()
        session.startTransport()
    }

    func stopTransport() {
        session.stopTransport()
    }

    func shutdown() {
        session.shutdown()
        started = false
    }

    func returnControlToMac() {
        switch session.phase {
        case .entering, .remote, .returning, .recovering:
            session.returnToLocalControl()
        case .disconnected, .connecting, .ready:
            break
        }
    }

    func refreshDisplays() {
        displays = session.displays
        if session.configuration.sourceDisplayID == nil,
           let display = SideCursorCore.DisplayCatalog.defaultSourceDisplay(from: displays) {
            mutateConfiguration { $0.sourceDisplayID = display.stableID }
        }
    }

    func refreshPairingCode() {
        pairingCode = session.currentPairingCode() ?? ""
    }

    func generatePairingCode() {
        pairingCode = session.generatePairingCode() ?? ""
        appendDiagnostic(session.statusMessage)
    }

    func savePairingCode(_ code: String) {
        session.replacePairingCode(code)
        refreshPairingCode()
    }

    func copyPairingCode() {
        guard !pairingCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
    }

    func mutateConfiguration(_ mutation: (inout SideCursorCore.SideCursorConfiguration) -> Void) {
        var configuration = session.configuration
        mutation(&configuration)
        session.configuration = configuration
    }

    func displayLabel(_ display: SideCursorCore.DisplayDescriptor) -> String {
        "\(display.name) — \(Int(display.bounds.width)) × \(Int(display.bounds.height))"
    }

    private func appendDiagnostic(_ message: String) {
        guard !message.isEmpty, diagnostics.last != message else { return }
        diagnostics.append(message)
        if diagnostics.count > 12 {
            diagnostics.removeFirst(diagnostics.count - 12)
        }
    }
}

private struct StatusMenuView: View {
    @ObservedObject var model: SideCursorAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.statusColor).frame(width: 9, height: 9)
                Text(model.session.phase.rawValue).fontWeight(.semibold)
            }
            Text(model.session.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let rtt = model.session.roundTripMilliseconds {
                Text("Round trip: \(rtt, specifier: "%.0f") ms").font(.caption)
            }
            Divider()
            if #available(macOS 14.0, *) {
                SettingsLink {
                    Text("Open SideCursor Settings…")
                }
            } else {
                Button("Open SideCursor Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            Button("Start or reconnect") { model.restartTransport() }
            Button("Return control to Mac") { model.returnControlToMac() }
                .disabled(model.session.phase != .remote && model.session.phase != .entering && model.session.phase != .returning && model.session.phase != .recovering)
            Divider()
            Button("Quit SideCursor") {
                model.shutdown()
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 310)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SideCursorAppModel
    @State private var pairingDraft = ""

    var body: some View {
        TabView {
            connectionTab.tabItem { Label("Connection", systemImage: "link") }
            routeTab.tabItem { Label("Display Route", systemImage: "rectangle.on.rectangle") }
            inputTab.tabItem { Label("Input & Gestures", systemImage: "hand.draw") }
            diagnosticsTab.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(20)
        .onAppear {
            model.refreshDisplays()
            model.session.refreshAccessibilityAndCapture()
            model.session.requestMissingPermissions()
            model.session.refreshGestureProfileStatus()
        }
    }

    private var connectionTab: some View {
        Form {
            Section("Transport") {
                Picker("Connection", selection: transportBinding) {
                    ForEach(SideCursorCore.TransportKind.allCases) { transport in
                        Text(transport.displayName).tag(transport)
                    }
                }
                Text("Tailscale TCP is the default direct encrypted route. Bluetooth is a manual RFCOMM fallback and is never selected automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.session.configuration.transport == .tailscaleTCP {
                    TextField("Mac listener port", value: listenPortBinding, formatter: NumberFormatter())
                    Text("Windows connects to this Mac port over its direct Tailscale address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Windows Bluetooth address", text: bluetoothAddressBinding)
                    Text("Enter the paired Windows radio address, for example 54:14:F3:78:6E:D6 — not the SideCursor service UUID. The Mac discovers the advertised RFCOMM service and channel automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save & reconnect") { model.restartTransport() }
                    Button("Stop transport") { model.stopTransport() }
                }
            }

            Section("Pairing") {
                Text("Mac pairing code").font(.caption).foregroundStyle(.secondary)
                if model.pairingCode.isEmpty {
                    Text("No code created yet. Generate one, then paste the same code into Windows.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.pairingCode)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("Copy code") { model.copyPairingCode() }
                        .disabled(model.pairingCode.isEmpty)
                    Button("Generate new code", role: .destructive) { model.generatePairingCode() }
                }
                SecureField("Paste an existing pairing code", text: $pairingDraft)
                Button("Save pasted code") {
                    model.savePairingCode(pairingDraft)
                    pairingDraft = ""
                }
                Text("The 32-byte code is kept in macOS Keychain and never placed in process arguments or diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Synchronize plain-text clipboard", isOn: clipboardEnabledBinding)
                Stepper(
                    "Maximum clipboard: \(model.session.configuration.clipboardMaximumBytes / 1024) KiB",
                    value: clipboardLimitBinding,
                    in: 64 * 1024...SideCursorCore.SideCursorConfiguration.maximumClipboardBytes,
                    step: 64 * 1024
                )
            }
        }
    }

    private var routeTab: some View {
        Form {
            Section("Mac source display") {
                Text("Right edge → the Windows display selected in the Windows companion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.displays) { display in
                            Button {
                                model.mutateConfiguration { $0.sourceDisplayID = display.stableID }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(display.name).fontWeight(.semibold)
                                    Text("\(Int(display.bounds.width)) × \(Int(display.bounds.height))")
                                        .font(.caption)
                                    Text(display.isBuiltIn ? "Built-in" : "External")
                                        .font(.caption2)
                                }
                                .frame(width: 165, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isSelected(display) ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(model.displayLabel(display))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Picker("Source display", selection: sourceDisplayBinding) {
                    ForEach(model.displays) { display in
                        Text(model.displayLabel(display)).tag(display.stableID)
                    }
                }
                Text("The route persists by display vendor/model/serial identity, not by temporary screen coordinates. Other Mac displays always stay local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Return behavior") {
                Stepper(
                    "Mac return inset: \(Int(model.session.configuration.returnInset)) px",
                    value: returnInsetBinding,
                    in: 4...160,
                    step: 2
                )
                Text("When Windows reaches its configured left edge, the Mac pointer returns once inside this source display, so it cannot immediately re-enter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refreshDisplays() }
    }

    private var inputTab: some View {
        Form {
            Section("Input capture") {
                LabeledContent(AccessibilityPermission.settingsName, value: model.session.accessibilityGranted ? "Granted" : "Required")
                LabeledContent("Input Monitoring", value: model.session.inputMonitoringGranted ? "Granted" : "Required")
                LabeledContent("Event tap", value: eventTapStatus)
                Button("Request permission") { model.session.requestAccessibilityAccess() }
                Button("Refresh permission state") { model.session.refreshAccessibility() }
                Text("On macOS 27, Apple renamed Accessibility to Device Control and Data Access. Enable SideCursor there; if SideCursor is listed under Input Monitoring too, enable it there as well.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Control + Option + F8 is always local: it cancels entry or returns control to the Mac. It is never sent to Windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pointer, scroll, and remote hotkeys") {
                Slider(value: pointerScaleBinding, in: 0.1...4.0, step: 0.05) { Text("Windows pointer scale") }
                Text("Scale: \(model.session.configuration.pointerScale, specifier: "%.2f") — default 1.00.")
                    .font(.caption)
                Toggle("Control + Option + Left/Right: Windows virtual desktops", isOn: desktopHotkeyBinding)
                Toggle("Control + Option + Up: Task View", isOn: taskViewHotkeyBinding)
                Toggle("Control + Option + Down: Show Desktop", isOn: showDesktopHotkeyBinding)
                Text("Two-finger scrolling is forwarded. A horizontal three/four-finger swipe becomes a Windows desktop switch; other three/four-finger gestures stay local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gesture Compatibility Profile") {
                Text(gestureProfileText)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Apply") { model.session.applyGestureCompatibilityProfile() }
                    Button("Verify") { model.session.refreshGestureProfileStatus() }
                    Button("Restore", role: .destructive) { model.session.restoreGestureCompatibilityProfile() }
                }
                Text("Apply saves every original setting, including missing keys, before disabling conflicting Space, Mission Control, Desktop, Launchpad, pinch, rotate, and three/four-finger trackpad actions. Sign out or restart after Apply or Restore; normal pointer, click, two-finger scroll, and local keyboard behavior remain available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var diagnosticsTab: some View {
        Form {
            Section("Live state") {
                LabeledContent("Session", value: model.session.phase.rawValue)
                LabeledContent("Transport", value: model.session.configuration.transport.displayName)
                LabeledContent(
                    "RTT",
                    value: model.session.roundTripMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
                )
                LabeledContent("Source display", value: model.session.configuration.sourceDisplayID ?? "Not selected")
                LabeledContent("Handoff", value: model.session.handoffDebug ?? "—")
                Text(model.session.statusMessage).fixedSize(horizontal: false, vertical: true)
                if let error = model.session.lastError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Safe recovery") {
                Button("Return control to Mac now") { model.returnControlToMac() }
                Button("Restart connection") { model.restartTransport() }
                Text("Lost peer, event-tap failure, display changes, and entry timeouts immediately restore Mac input and send Windows ReleaseAll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recent diagnostics") {
                if model.diagnostics.isEmpty {
                    Text("No diagnostics yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption)
                    }
                }
            }
        }
    }

    private var transportBinding: Binding<SideCursorCore.TransportKind> {
        Binding(
            get: { model.session.configuration.transport },
            set: { value in model.mutateConfiguration { $0.transport = value } }
        )
    }

    private var listenPortBinding: Binding<Int> {
        Binding(
            get: { model.session.configuration.listenPort },
            set: { value in model.mutateConfiguration { $0.listenPort = max(1, min(65_535, value)) } }
        )
    }

    private var bluetoothAddressBinding: Binding<String> {
        Binding(
            get: { model.session.configuration.bluetoothPeerAddress },
            set: { value in model.mutateConfiguration { $0.bluetoothPeerAddress = value } }
        )
    }

    private var clipboardEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.session.configuration.clipboardEnabled },
            set: { value in model.mutateConfiguration { $0.clipboardEnabled = value } }
        )
    }

    private var clipboardLimitBinding: Binding<Int> {
        Binding(
            get: { model.session.configuration.clipboardMaximumBytes },
            set: { value in model.mutateConfiguration { $0.clipboardMaximumBytes = value } }
        )
    }

    private var sourceDisplayBinding: Binding<String> {
        Binding(
            get: { model.session.configuration.sourceDisplayID ?? "" },
            set: { value in model.mutateConfiguration { $0.sourceDisplayID = value } }
        )
    }

    private var returnInsetBinding: Binding<Double> {
        Binding(
            get: { model.session.configuration.returnInset },
            set: { value in model.mutateConfiguration { $0.returnInset = value } }
        )
    }

    private var pointerScaleBinding: Binding<Double> {
        Binding(
            get: { model.session.configuration.pointerScale },
            set: { value in model.mutateConfiguration { $0.pointerScale = value } }
        )
    }

    private var desktopHotkeyBinding: Binding<Bool> {
        Binding(
            get: {
                model.session.configuration.remoteHotkeys.desktopLeftEnabled &&
                    model.session.configuration.remoteHotkeys.desktopRightEnabled
            },
            set: { value in
                model.mutateConfiguration {
                    $0.remoteHotkeys.desktopLeftEnabled = value
                    $0.remoteHotkeys.desktopRightEnabled = value
                }
            }
        )
    }

    private var taskViewHotkeyBinding: Binding<Bool> {
        Binding(
            get: { model.session.configuration.remoteHotkeys.taskViewEnabled },
            set: { value in model.mutateConfiguration { $0.remoteHotkeys.taskViewEnabled = value } }
        )
    }

    private var showDesktopHotkeyBinding: Binding<Bool> {
        Binding(
            get: { model.session.configuration.remoteHotkeys.showDesktopEnabled },
            set: { value in model.mutateConfiguration { $0.remoteHotkeys.showDesktopEnabled = value } }
        )
    }

    private var gestureProfileText: String {
        switch model.session.gestureProfileStatus {
        case .notApplied:
            return "Not applied. Use Apply only if macOS gestures conflict with remote control."
        case let .applied(verified):
            return verified
                ? "Applied and verified. Sign out or restart before testing system-level gesture behavior."
                : "Applied, but some settings could not be verified. Use Restore if you do not want to keep the profile."
        }
    }

    private func isSelected(_ display: SideCursorCore.DisplayDescriptor) -> Bool {
        model.session.configuration.sourceDisplayID == display.stableID
    }

    private var eventTapStatus: String {
        guard model.session.isInputTapRunning else { return "Stopped" }
        return model.session.isInputTapFiltering ? "Running (filtering)" : "Running (listen-only)"
    }
}
