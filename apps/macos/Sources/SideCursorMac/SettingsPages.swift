import AppKit
import SideCursorCore
import SwiftUI

// MARK: - Overview

struct OverviewPage: View {
    @ObservedObject var model: SideCursorAppModel
    let showDisplays: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Circle()
                        .fill(model.statusColor.gradient)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: model.statusSymbol)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.statusTitle).font(.title3.weight(.semibold))
                        Text(model.statusDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if model.isRemoteOwned {
                        Button("Return to Mac") { model.returnControlToMac() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Button(model.session.phase == .disconnected ? "Connect" : "Reconnect") {
                            model.restartTransport()
                        }
                        .controlSize(.large)
                    }
                }
                .padding(.vertical, 6)
            }

            if let error = model.session.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Windows PC") {
                LabeledContent("Status", value: model.isPeerConnected ? "Connected" : "Not connected")
                LabeledContent("Latency", value: model.latencyText)
                LabeledContent("Connection", value: model.session.configuration.transport.displayName)
            }

            if let layout = model.session.layout {
                Section {
                    DisplayArrangementCanvas(layout: layout, selection: .constant(nil), interactive: false)
                        .frame(height: 170)
                    HStack {
                        Text(crossingSummary(layout))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit Arrangement…", action: showDisplays)
                    }
                } header: {
                    Text("Displays")
                }
            }

            Section("Permissions") {
                PermissionRow(title: AccessibilityPermission.settingsName, granted: model.session.accessibilityGranted)
                PermissionRow(title: "Input Monitoring", granted: model.session.inputMonitoringGranted)
                if !model.session.accessibilityGranted || !model.session.inputMonitoringGranted {
                    HStack {
                        Spacer()
                        Button("Allow Access…") { model.session.requestAccessibilityAccess() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func crossingSummary(_ layout: ResolvedDisplayLayout) -> String {
        switch layout.links.count {
        case 0: return "No shared edge yet."
        case 1: return "The pointer crosses at one shared edge."
        default: return "The pointer crosses at \(layout.links.count) shared edges."
        }
    }
}

// MARK: - Pointer & Scrolling

struct PointerPage: View {
    @ObservedObject var model: SideCursorAppModel

    var body: some View {
        let configuration = model.session.configuration
        Form {
            Section {
                LabeledContent("Pointer speed") {
                    HStack(spacing: 8) {
                        Slider(value: model.binding(\.pointerScale), in: 0.1...4.0) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "hare.fill").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        Text(String(format: "%.2f×", configuration.pointerScale))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Motion smoothing", selection: model.binding(\.motionCoalesceMilliseconds)) {
                    ForEach(options([0, 4, 8, 16], including: configuration.motionCoalesceMilliseconds), id: \.self) { value in
                        Text(value == 0 ? "Off" : "\(value) ms").tag(value)
                    }
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("At 1.00× the pointer moves the same physical distance on the Mac and on Windows. Smoothing steadies very fast mice at the cost of a little latency.")
            }

            Section {
                LabeledContent("Scroll speed") {
                    HStack(spacing: 8) {
                        Slider(value: model.binding(\.scrollScale), in: 0.05...0.5) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "hare.fill").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        Text("\(Int((configuration.scrollScale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Scrolling")
            } footer: {
                Text("How much of each Mac scroll is sent to Windows.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures & Shortcuts

struct GesturesPage: View {
    @ObservedObject var model: SideCursorAppModel
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section {
                IconRow(
                    symbol: "rectangle.split.3x1.fill",
                    color: .blue,
                    title: "Switch desktops",
                    subtitle: "⌃⌥← or ⌃⌥→  ·  Three-finger swipe left or right"
                ) {
                    Toggle("Switch desktops", isOn: desktopBinding).labelsHidden().toggleStyle(.switch)
                }
                IconRow(
                    symbol: "square.grid.2x2.fill",
                    color: .purple,
                    title: "Task View",
                    subtitle: "⌃⌥↑  ·  Three-finger swipe up"
                ) {
                    Toggle("Task View", isOn: model.binding(\.remoteHotkeys.taskViewEnabled)).labelsHidden().toggleStyle(.switch)
                }
                IconRow(
                    symbol: "macwindow.on.rectangle",
                    color: .teal,
                    title: "Show desktop",
                    subtitle: "⌃⌥↓  ·  Three-finger swipe down"
                ) {
                    Toggle("Show desktop", isOn: model.binding(\.remoteHotkeys.showDesktopEnabled)).labelsHidden().toggleStyle(.switch)
                }
            } header: {
                Text("Windows actions")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Three-finger swipes need macOS's own three-finger swipes turned off.")
                    Button("Trackpad Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            Section("Always on") {
                IconRow(symbol: "arrow.up.and.down", color: .gray, title: "Scroll", subtitle: "Two-finger scroll")
                IconRow(symbol: "plus.magnifyingglass", color: .orange, title: "Zoom", subtitle: "Pinch with two fingers")
                IconRow(symbol: "arrow.uturn.backward", color: .red, title: "Return to Mac", subtitle: "⌃⌥F8 — works even while Windows is in control")
            }

            Section {
                DisclosureGroup("Gesture compatibility profile", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(gestureProfileText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Apply") { model.session.applyGestureCompatibilityProfile() }
                            Button("Verify") { model.session.refreshGestureProfileStatus() }
                            Button("Restore", role: .destructive) { model.session.restoreGestureCompatibilityProfile() }
                        }
                        Text("Turns off macOS gestures that can interrupt remote control, after saving your current settings. Sign out or restart after applying or restoring.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
    }

    private var desktopBinding: Binding<Bool> {
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

    private var gestureProfileText: String {
        switch model.session.gestureProfileStatus {
        case .notApplied:
            return "Not applied. Only needed if macOS gestures still interfere while controlling Windows."
        case let .applied(verified):
            return verified
                ? "Applied and verified."
                : "Applied, but some settings could not be verified."
        }
    }
}

// MARK: - Connection

struct ConnectionPage: View {
    @ObservedObject var model: SideCursorAppModel
    @State private var revealsCode = false
    @State private var confirmsNewCode = false
    @State private var entersCode = false

    var body: some View {
        let configuration = model.session.configuration
        Form {
            Section {
                Picker("Connect using", selection: model.binding(\.transport)) {
                    ForEach(SideCursorCore.TransportKind.allCases) { transport in
                        Text(transport.displayName).tag(transport)
                    }
                }
                if configuration.transport == .tailscaleTCP {
                    LabeledContent("Listening port") {
                        TextField("Port", value: portBinding, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                } else {
                    LabeledContent("Windows Bluetooth address") {
                        TextField("54:14:F3:78:6E:D6", text: model.binding(\.bluetoothPeerAddress))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 190)
                    }
                }
                LabeledContent("Status") {
                    StatusPill(title: model.statusTitle, color: model.statusColor)
                }
                HStack {
                    Spacer()
                    Button("Disconnect") { model.stopTransport() }
                        .disabled(model.session.phase == .disconnected)
                    Button("Reconnect") { model.restartTransport() }
                        .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(configuration.transport == .tailscaleTCP
                    ? "Windows connects to this Mac over Tailscale."
                    : "Pair both computers in Bluetooth settings first. Bluetooth is never chosen automatically.")
            }

            Section {
                LabeledContent("Pairing code") {
                    HStack(spacing: 8) {
                        if model.pairingCode.isEmpty {
                            Text("None yet").foregroundStyle(.secondary)
                        } else {
                            Text(revealsCode ? model.pairingCode : String(repeating: "•", count: 16))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                revealsCode.toggle()
                            } label: {
                                Image(systemName: revealsCode ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(revealsCode ? "Hide code" : "Show code")
                            Button {
                                model.copyPairingCode()
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy code")
                        }
                    }
                }
                HStack {
                    Button("Use Existing Code…") { entersCode = true }
                    Spacer()
                    Button(model.pairingCode.isEmpty ? "Create Code" : "Create New Code…") {
                        if model.pairingCode.isEmpty {
                            model.generatePairingCode()
                        } else {
                            confirmsNewCode = true
                        }
                    }
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("Enter the same code in SideCursor on Windows. It's kept in your Keychain.")
            }

            Section {
                Toggle("Share copied text and images with Windows", isOn: model.binding(\.clipboardEnabled))
                    .toggleStyle(.switch)
                Picker("Largest item", selection: model.binding(\.clipboardMaximumBytes)) {
                    ForEach(
                        options([64 * 1024, 256 * 1024, 1_048_576, 5 * 1_048_576, 10 * 1_048_576], including: configuration.clipboardMaximumBytes),
                        id: \.self
                    ) { bytes in
                        Text(bytes >= 1_048_576 ? "\(bytes / 1_048_576) MB" : "\(bytes / 1024) KB").tag(bytes)
                    }
                }
                .disabled(!configuration.clipboardEnabled)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Images travel as PNG. Copied files stay on the computer they were copied on.")
            }
        }
        .formStyle(.grouped)
        .alert("Create a new pairing code?", isPresented: $confirmsNewCode) {
            Button("Create", role: .destructive) { model.generatePairingCode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Windows will need the new code before it can connect again.")
        }
        .sheet(isPresented: $entersCode) {
            PairingCodeSheet { code in model.savePairingCode(code) }
        }
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { model.session.configuration.listenPort },
            set: { value in model.mutateConfiguration { $0.listenPort = max(1, min(65_535, value)) } }
        )
    }
}

private struct PairingCodeSheet: View {
    let onSave: (String) -> Void
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use an existing pairing code").font(.headline)
            Text("Paste the code shown in SideCursor on Windows or from another Mac.")
                .foregroundStyle(.secondary)
            SecureField("Pairing code", text: $code)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(code.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Diagnostics

struct DiagnosticsPage: View {
    @ObservedObject var model: SideCursorAppModel

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Form {
            Section("Live state") {
                value("Session", model.session.phase.rawValue)
                value("Connection", model.session.configuration.transport.displayName)
                value("Latency", model.latencyText)
                value("Handoff", model.session.handoffDebug ?? "—")
                value("Input sent", model.session.inputMetricsText)
                if let error = model.session.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                PermissionRow(title: AccessibilityPermission.settingsName, granted: model.session.accessibilityGranted)
                PermissionRow(title: "Input Monitoring", granted: model.session.inputMonitoringGranted)
                value("Event tap", eventTapStatus)
                HStack {
                    Spacer()
                    Button("Refresh") { model.session.refreshAccessibilityAndCapture() }
                    Button("Allow Access…") { model.session.requestAccessibilityAccess() }
                }
            } header: {
                Text("Input capture")
            }

            Section("Recent events") {
                if model.diagnostics.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.diagnostics.reversed()) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(Self.timeFormat.string(from: entry.date))
                                        .foregroundStyle(.secondary)
                                    Text(entry.message)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                }
            }

            Section {
                HStack {
                    Button("Return Control to Mac") { model.returnControlToMac() }
                        .disabled(!model.isRemoteOwned)
                    Spacer()
                    Button("Restart Connection") { model.restartTransport() }
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("Losing Windows, a display change, or an input failure always gives control back to the Mac automatically.")
            }
        }
        .formStyle(.grouped)
    }

    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var eventTapStatus: String {
        guard model.session.isInputTapRunning else { return "Stopped" }
        return model.session.isInputTapFiltering ? "Running" : "Listen-only"
    }
}

/// Picker options that always include the current value, so a saved value
/// outside the presets still shows.
func options<Value: Comparable>(_ presets: [Value], including current: Value) -> [Value] {
    presets.contains(current) ? presets : (presets + [current]).sorted()
}
