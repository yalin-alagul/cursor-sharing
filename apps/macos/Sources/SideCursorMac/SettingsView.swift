import SideCursorCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case overview
    case displays
    case pointer
    case gestures
    case connection
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .displays: return "Displays"
        case .pointer: return "Pointer & Scrolling"
        case .gestures: return "Gestures & Shortcuts"
        case .connection: return "Connection"
        case .diagnostics: return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "cursorarrow.rays"
        case .displays: return "display.2"
        case .pointer: return "cursorarrow.motionlines"
        case .gestures: return "hand.draw.fill"
        case .connection: return "network"
        case .diagnostics: return "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .overview: return .blue
        case .displays: return .indigo
        case .pointer: return .teal
        case .gestures: return .pink
        case .connection: return .green
        case .diagnostics: return .gray
        }
    }
}

/// System Settings-style window: a sidebar of pages, each a grouped form.
struct SettingsView: View {
    @ObservedObject var model: SideCursorAppModel
    @State private var selection: SettingsPage?

    init(model: SideCursorAppModel, initialPage: SettingsPage = .overview) {
        self.model = model
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPage.allCases) { page in
                    Label {
                        Text(page.title)
                    } icon: {
                        SettingsIcon(symbol: page.symbol, color: page.color)
                    }
                    .tag(page)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            let page = selection ?? .overview
            detail(for: page)
                .navigationTitle(page.title)
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 580, idealHeight: 660)
        .onAppear {
            model.refreshDisplays()
            guard model.isLive else { return }
            model.session.refreshAccessibilityAndCapture()
            model.session.requestMissingPermissions()
            model.session.refreshGestureProfileStatus()
        }
    }

    @ViewBuilder
    private func detail(for page: SettingsPage) -> some View {
        switch page {
        case .overview:
            OverviewPage(model: model) { selection = .displays }
        case .displays:
            DisplaysPage(model: model)
        case .pointer:
            PointerPage(model: model)
        case .gestures:
            GesturesPage(model: model)
        case .connection:
            ConnectionPage(model: model)
        case .diagnostics:
            DiagnosticsPage(model: model)
        }
    }
}
