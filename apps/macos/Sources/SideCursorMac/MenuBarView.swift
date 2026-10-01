import AppKit
import SwiftUI

/// The menu-bar popup: state at a glance, one main action, and menu rows.
struct MenuBarView: View {
    @ObservedObject var model: SideCursorAppModel
    @State private var settingsHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SideCursor").font(.headline)
                Spacer()
                if model.isPeerConnected {
                    Text(model.latencyText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Round-trip latency to Windows")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(symbol: model.statusSymbol, color: model.statusColor, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.statusTitle).fontWeight(.semibold)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            if model.isRemoteOwned {
                Button {
                    model.returnControlToMac()
                } label: {
                    Text("Return to Mac").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    model.restartTransport()
                } label: {
                    Text(model.session.phase == .disconnected ? "Connect" : "Reconnect").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Divider()

            VStack(spacing: 2) {
                settingsRow
                MenuRow(title: "Quit SideCursor", symbol: "power") {
                    model.shutdown()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private var settingsRow: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                MenuRowLabel(title: "Settings…", symbol: "gearshape", hovering: settingsHover)
            }
            .buttonStyle(.plain)
            .onHover { settingsHover = $0 }
        } else {
            MenuRow(title: "Settings…", symbol: "gearshape") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
