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
            MenuBarView(model: model)
                .onAppear {
                    model.start()
                    model.session.refreshAccessibilityAndCapture()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

struct DiagnosticEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let message: String
}

@MainActor
final class SideCursorAppModel: ObservableObject {
    let session: SideCursorCore.SessionController
    /// False for previews and snapshot rendering: nothing starts, prompts,
    /// or listens.
    let isLive: Bool

    @Published private(set) var displays: [SideCursorCore.DisplayDescriptor] = []
    @Published private(set) var pairingCode = ""
    @Published private(set) var diagnostics: [DiagnosticEntry] = []
    @Published private(set) var started = false

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(session: SideCursorCore.SessionController? = nil, isLive: Bool = true) {
        self.session = session ?? SideCursorCore.SessionController()
        self.isLive = isLive
        self.session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.session.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.appendDiagnostic(message) }
            .store(in: &cancellables)
        refreshDisplays()
        refreshPairingCode()
        guard isLive else { return }
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

    // MARK: Status presentation

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

    var statusSymbol: String {
        switch session.phase {
        case .disconnected: return "bolt.horizontal.fill"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .ready: return "checkmark"
        case .entering, .returning: return "arrow.left.arrow.right"
        case .remote: return "display"
        case .recovering: return "arrow.clockwise"
        }
    }

    var statusTitle: String {
        switch session.phase {
        case .disconnected: return "Not connected"
        case .connecting: return "Waiting for Windows"
        case .ready: return "Ready"
        case .entering: return "Switching to Windows…"
        case .remote: return "Controlling Windows"
        case .returning: return "Returning to Mac…"
        case .recovering: return "Recovering…"
        }
    }

    var statusDetail: String {
        switch session.phase {
        case .disconnected:
            return "Connect to start sharing the pointer with Windows."
        case .connecting:
            return session.isListening
                ? "Open SideCursor on your Windows PC to connect."
                : "Connecting…"
        case .ready:
            if let layout = session.layout, layout.links.isEmpty {
                return "Place the Windows displays next to a Mac display to choose where the pointer crosses."
            }
            return "Move the pointer across a shared edge to control Windows."
        case .remote:
            return "Press ⌃⌥F8 at any time to return to the Mac."
        case .entering, .returning, .recovering:
            return session.statusMessage
        }
    }

    var isPeerConnected: Bool {
        switch session.phase {
        case .disconnected, .connecting: return false
        case .ready, .entering, .remote, .returning, .recovering: return true
        }
    }

    /// Windows currently owns (or is taking or giving back) the input.
    var isRemoteOwned: Bool {
        switch session.phase {
        case .entering, .remote, .returning, .recovering: return true
        case .disconnected, .connecting, .ready: return false
        }
    }

    var latencyText: String {
        session.roundTripMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    // MARK: Actions

    func start() {
        guard isLive, !started else { return }
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
        guard isRemoteOwned else { return }
        session.returnToLocalControl()
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

    /// A two-way binding to one saved setting.
    func binding<Value>(_ keyPath: WritableKeyPath<SideCursorCore.SideCursorConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { self.session.configuration[keyPath: keyPath] },
            set: { value in self.mutateConfiguration { $0[keyPath: keyPath] = value } }
        )
    }

    func displayLabel(_ display: SideCursorCore.DisplayDescriptor) -> String {
        "\(display.name) — \(Int(display.bounds.width)) × \(Int(display.bounds.height))"
    }

    private func appendDiagnostic(_ message: String) {
        guard !message.isEmpty, diagnostics.last?.message != message else { return }
        diagnostics.append(DiagnosticEntry(date: Date(), message: message))
        if diagnostics.count > 40 {
            diagnostics.removeFirst(diagnostics.count - 40)
        }
    }
}
