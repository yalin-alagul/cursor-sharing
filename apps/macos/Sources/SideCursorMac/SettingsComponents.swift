import AppKit
import SwiftUI

/// The coloured rounded-square symbol tile System Settings uses in its
/// sidebar and rows.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                // Scaled to fit so wide symbols (two displays, a stethoscope)
                // stay inside the tile like narrow ones.
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(size * 0.2)
            )
            .accessibilityHidden(true)
    }
}

/// A coloured dot and short state, used in the popup header.
struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }
}

/// An icon, a title with an optional secondary line, and trailing content.
struct IconRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

extension IconRow where Trailing == EmptyView {
    init(symbol: String, color: Color, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A granted / required permission line.
struct PermissionRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        LabeledContent(title) {
            Label(granted ? "Allowed" : "Not allowed", systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// A menu-style row with the system hover highlight, for the popup.
struct MenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, symbol: symbol, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuRowLabel: View {
    let title: String
    let symbol: String
    let hovering: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(title)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
