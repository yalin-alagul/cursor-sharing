import AppKit
import SideCursorCore
import SwiftUI

// MARK: - Page

/// Arranges the Windows displays around the Mac displays at real physical
/// size, like macOS's own display arrangement.
struct DisplaysPage: View {
    @ObservedObject var model: SideCursorAppModel
    /// `DisplayLayoutConfiguration.sizeKey` of the selected display.
    @State private var selection: String?

    var body: some View {
        if let layout = model.session.layout {
            editor(layout)
        } else {
            waitingForWindows
        }
    }

    private func editor(_ layout: ResolvedDisplayLayout) -> some View {
        Form {
            Section {
                DisplayArrangementCanvas(layout: layout, selection: $selection, interactive: true) { proposed in
                    place(near: proposed, in: layout)
                }
                .frame(height: 330)
                HStack(spacing: 16) {
                    LegendSwatch(fill: ScreenTile.macFill, title: "Mac")
                    LegendSwatch(fill: ScreenTile.windowsFill, title: "Windows")
                    HStack(spacing: 6) {
                        Capsule().fill(Color.green).frame(width: 16, height: 4)
                        Text("Pointer crosses here")
                    }
                    Spacer()
                    Text("Drag Windows · arrow keys nudge")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            } header: {
                Text("Arrangement")
            }

            Section("Selected display") {
                if let screen = selectedScreen(in: layout) {
                    selectedDisplayRows(screen.screen, windows: screen.windows)
                } else {
                    Text("Select a display above to see or correct its size.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Where the pointer crosses") {
                if layout.overlaps {
                    Label("A Windows display overlaps a Mac display. Drag it to the side.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if layout.links.isEmpty {
                    Label("No Mac display touches a Windows display yet.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    ForEach(Array(layout.links.enumerated()), id: \.offset) { _, link in
                        LabeledContent {
                            Text(String(format: "%.0f mm · %.1f″", link.lengthMm, link.lengthMm / 25.4))
                                .monospacedDigit()
                        } label: {
                            Label {
                                Text("\(link.mac.name) \(link.macEdge.rawValue) edge → \(link.windows.name)")
                            } icon: {
                                Image(systemName: arrowSymbol(for: link.macEdge)).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }

            Section {
                Stepper(value: model.binding(\.returnInset), in: 4...160, step: 2) {
                    LabeledContent("Return distance", value: "\(Int(model.session.configuration.returnInset)) pt")
                }
                HStack {
                    Spacer()
                    Button("Reset Arrangement") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            model.mutateConfiguration { $0.layout.windowsOffsetMm = nil }
                        }
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("How far inside the Mac edge the pointer reappears when it comes back from Windows.")
            }
        }
        .formStyle(.grouped)
    }

    private var waitingForWindows: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "display.2")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Connect Windows to arrange your displays")
                        .font(.headline)
                    Text("Once SideCursor on Windows connects, its displays appear here at their real size.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }

            Section {
                Picker("Hand off from", selection: sourceDisplayBinding) {
                    ForEach(model.displays) { display in
                        Text(model.displayLabel(display)).tag(display.stableID)
                    }
                }
            } header: {
                Text("Until then")
            } footer: {
                Text("The pointer goes to Windows across this display's right edge.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func selectedDisplayRows(_ screen: LayoutScreen, windows: Bool) -> some View {
        let key = DisplayLayoutConfiguration.sizeKey(windows: windows, id: screen.id)
        let overridden = model.session.configuration.layout.sizeOverridesMm[key] != nil
        let detected = windows
            ? model.session.configuration.layout.knownWindowsDisplays.first { $0.id == screen.id }.flatMap(DisplayLayoutBuilder.detectedSize(of:))
            : model.displays.first { $0.stableID == screen.id }?.sizeMm
        LabeledContent("Display", value: "\(screen.name) · \(windows ? "Windows" : "Mac")")
        LabeledContent("Resolution", value: "\(Int(screen.bounds.width)) × \(Int(screen.bounds.height))")
        LabeledContent("Physical size") {
            Text(String(format: "%.0f × %.0f mm", screen.sizeMm.width, screen.sizeMm.height))
                + Text(overridden ? "  ·  corrected" : detected == nil ? "  ·  estimated" : "  ·  from monitor")
                .foregroundColor(.secondary)
        }
        LabeledContent("Diagonal") {
            HStack(spacing: 6) {
                TextField(
                    "Diagonal",
                    value: Binding(
                        get: { (screen.sizeMm.diagonalInches * 10).rounded() / 10 },
                        set: { inches in
                            guard let size = MillimeterSize.fromDiagonal(inches: inches, pixels: screen.bounds.size),
                                  size.isUsable
                            else { return }
                            model.mutateConfiguration { $0.layout.sizeOverridesMm[key] = size }
                        }
                    ),
                    format: .number.precision(.fractionLength(1))
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                Text("in").foregroundStyle(.secondary)
                if overridden {
                    Button("Reset") {
                        model.mutateConfiguration { $0.layout.sizeOverridesMm[key] = nil }
                    }
                }
            }
        }
    }

    private func selectedScreen(in layout: ResolvedDisplayLayout) -> (screen: LayoutScreen, windows: Bool)? {
        guard let selection else { return nil }
        if let screen = layout.macScreens.first(where: { DisplayLayoutConfiguration.sizeKey(windows: false, id: $0.id) == selection }) {
            return (screen, false)
        }
        if let screen = layout.windowsScreens.first(where: { DisplayLayoutConfiguration.sizeKey(windows: true, id: $0.id) == selection }) {
            return (screen, true)
        }
        return nil
    }

    private func place(near proposed: CGPoint, in layout: ResolvedDisplayLayout) {
        let snapped = ResolvedDisplayLayout.snappedOffset(
            proposed,
            macScreens: layout.macScreens,
            windowsScreens: layout.windowsScreens
        ) ?? layout.windowsOffsetMm
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            model.mutateConfiguration { $0.layout.windowsOffsetMm = MillimeterPoint(snapped) }
        }
    }

    private var sourceDisplayBinding: Binding<String> {
        Binding(
            get: { model.session.configuration.sourceDisplayID ?? "" },
            set: { value in model.mutateConfiguration { $0.sourceDisplayID = value } }
        )
    }

    private func arrowSymbol(for edge: ScreenEdge) -> String {
        switch edge {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .top: return "arrow.up"
        case .bottom: return "arrow.down"
        }
    }
}

private struct LegendSwatch: View {
    let fill: LinearGradient
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill).frame(width: 16, height: 11)
            Text(title)
        }
    }
}

// MARK: - Canvas

/// The arrangement drawing. Interactive: click to select a display, drag
/// the Windows displays (they move together, as Windows arranges them among
/// themselves), and use the arrow keys to nudge them.
struct DisplayArrangementCanvas: View {
    let layout: ResolvedDisplayLayout
    @Binding var selection: String?
    var interactive = true
    var onMove: (CGPoint) -> Void = { _ in }

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { proxy in
            let mapping = CanvasMapping(layout: layout, size: proxy.size, roomToDrag: interactive)
            let dragMm = CGSize(width: dragTranslation.width / mapping.scale, height: dragTranslation.height / mapping.scale)
            let preview = isDragging ? snapPreview(dragMm) : nil
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = nil }

                ForEach(layout.macScreens) { screen in
                    if let rect = layout.macRectsMm[screen.id] {
                        tile(screen, windows: false, rect: rect, mapping: mapping)
                    }
                }

                if let preview {
                    ForEach(layout.windowsScreens) { screen in
                        if let rect = layout.windowsRectsMm[screen.id]?.offsetBy(
                            dx: preview.x - layout.windowsOffsetMm.x,
                            dy: preview.y - layout.windowsOffsetMm.y
                        ) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .frame(width: mapping.size(rect).width, height: mapping.size(rect).height)
                                .position(mapping.center(rect))
                                .allowsHitTesting(false)
                        }
                    }
                }

                ForEach(layout.windowsScreens) { screen in
                    if let rect = layout.windowsRectsMm[screen.id] {
                        tile(screen, windows: true, rect: rect, mapping: mapping)
                            .offset(dragTranslation)
                            .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 8, y: 3)
                            .gesture(interactive ? windowsDrag(mapping) : nil)
                            .onHover { inside in
                                guard interactive, !isDragging else { return }
                                (inside ? NSCursor.openHand : NSCursor.arrow).set()
                            }
                    }
                }

                // Shared edges sit on top of both displays they join.
                if !isDragging {
                    ForEach(Array(layout.links.enumerated()), id: \.offset) { _, link in
                        mapping.path(for: link)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .shadow(color: Color.green.opacity(0.7), radius: 4)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .focusable(interactive)
        .focused($focused)
        .onMoveCommand { direction in
            guard interactive else { return }
            let step = 5.0
            let offset = layout.windowsOffsetMm
            switch direction {
            case .left: onMove(CGPoint(x: offset.x - step, y: offset.y))
            case .right: onMove(CGPoint(x: offset.x + step, y: offset.y))
            case .up: onMove(CGPoint(x: offset.x, y: offset.y - step))
            case .down: onMove(CGPoint(x: offset.x, y: offset.y + step))
            @unknown default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display arrangement")
    }

    private func tile(_ screen: LayoutScreen, windows: Bool, rect: CGRect, mapping: CanvasMapping) -> some View {
        let key = DisplayLayoutConfiguration.sizeKey(windows: windows, id: screen.id)
        let size = mapping.size(rect)
        return ScreenTile(screen: screen, windows: windows, selected: selection == key, size: size)
            .frame(width: size.width, height: size.height)
            .position(mapping.center(rect))
            .onTapGesture {
                guard interactive else { return }
                selection = key
                focused = true
            }
    }

    private func windowsDrag(_ mapping: CanvasMapping) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    NSCursor.closedHand.set()
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                let proposed = CGPoint(
                    x: layout.windowsOffsetMm.x + value.translation.width / mapping.scale,
                    y: layout.windowsOffsetMm.y + value.translation.height / mapping.scale
                )
                isDragging = false
                dragTranslation = .zero
                NSCursor.openHand.set()
                onMove(proposed)
            }
    }

    private func snapPreview(_ dragMm: CGSize) -> CGPoint? {
        ResolvedDisplayLayout.snappedOffset(
            CGPoint(x: layout.windowsOffsetMm.x + dragMm.width, y: layout.windowsOffsetMm.y + dragMm.height),
            macScreens: layout.macScreens,
            windowsScreens: layout.windowsScreens
        )
    }
}

/// One display drawn with a wallpaper-like gradient, a menu bar (Mac main
/// display) or taskbar (Windows primary), and its name.
struct ScreenTile: View {
    static let macFill = LinearGradient(
        colors: [Color(red: 0.27, green: 0.49, blue: 0.97), Color(red: 0.49, green: 0.30, blue: 0.86)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let windowsFill = LinearGradient(
        colors: [Color(red: 0.02, green: 0.62, blue: 0.80), Color(red: 0.05, green: 0.36, blue: 0.78)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    let screen: LayoutScreen
    let windows: Bool
    let selected: Bool
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(7, size.width * 0.06), style: .continuous)
        ZStack {
            shape.fill(windows ? Self.windowsFill : Self.macFill)
            if screen.isPrimary {
                VStack(spacing: 0) {
                    if !windows {
                        Rectangle().fill(Color.white.opacity(0.8)).frame(height: max(3, size.height * 0.055))
                    }
                    Spacer(minLength: 0)
                    if windows {
                        Rectangle().fill(Color.black.opacity(0.32)).frame(height: max(4, size.height * 0.075))
                    }
                }
                .clipShape(shape)
            }
            if size.width > 64, size.height > 34 {
                VStack(spacing: 2) {
                    Text(screen.name)
                        .font(.system(size: labelSize, weight: .semibold))
                    Text(String(format: "%@ · %.1f″", windows ? "Windows" : "Mac", screen.sizeMm.diagonalInches))
                        .font(.system(size: labelSize - 2, weight: .medium))
                        .opacity(0.85)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .padding(.horizontal, 6)
            }
            shape.strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.55), lineWidth: selected ? 3 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(windows ? "Windows" : "Mac") display \(screen.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var labelSize: CGFloat { min(13, max(9, size.width / 13)) }
}

/// Maps layout millimetres to canvas points. The fit depends only on the
/// saved layout, so it stays still while dragging, with room to drag.
struct CanvasMapping {
    let scale: CGFloat
    let origin: CGPoint
    let inset: CGPoint

    init(layout: ResolvedDisplayLayout, size: CGSize, roomToDrag: Bool) {
        let rects = Array(layout.macRectsMm.values) + Array(layout.windowsRectsMm.values)
        let box = rects.dropFirst().reduce(rects.first ?? CGRect(x: 0, y: 0, width: 100, height: 100)) { $0.union($1) }
        let margin = roomToDrag ? 0.14 : 0.06
        let padded = box.insetBy(dx: -box.width * margin - 12, dy: -box.height * margin - 12)
        scale = max(0.01, min(size.width / padded.width, size.height / padded.height))
        origin = padded.origin
        inset = CGPoint(
            x: (size.width - padded.width * scale) / 2,
            y: (size.height - padded.height * scale) / 2
        )
    }

    func point(_ mm: CGPoint) -> CGPoint {
        CGPoint(x: (mm.x - origin.x) * scale + inset.x, y: (mm.y - origin.y) * scale + inset.y)
    }

    func size(_ rect: CGRect) -> CGSize {
        CGSize(width: max(1, rect.width * scale - 2), height: max(1, rect.height * scale - 2))
    }

    func center(_ rect: CGRect) -> CGPoint { point(CGPoint(x: rect.midX, y: rect.midY)) }

    func path(for link: HandoffLink) -> Path {
        let m = link.macRectMm
        let start: CGPoint
        let end: CGPoint
        switch link.macEdge {
        case .right: start = CGPoint(x: m.maxX, y: link.startMm); end = CGPoint(x: m.maxX, y: link.endMm)
        case .left: start = CGPoint(x: m.minX, y: link.startMm); end = CGPoint(x: m.minX, y: link.endMm)
        case .bottom: start = CGPoint(x: link.startMm, y: m.maxY); end = CGPoint(x: link.endMm, y: m.maxY)
        case .top: start = CGPoint(x: link.startMm, y: m.minY); end = CGPoint(x: link.endMm, y: m.minY)
        }
        var path = Path()
        path.move(to: point(start))
        path.addLine(to: point(end))
        return path
    }
}
