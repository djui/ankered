import SwiftUI

/// Port identity colors shared by the popover, Settings, and the history chart.
/// Slots 1–3 of a colorblind-validated categorical palette, with separate light and dark steps.
enum PortPalette {
    static func color(_ index: Int) -> Color {
        switch index {
        case 1: return Color("PortC1")
        case 2: return Color("PortC2")
        case 3: return Color("PortC3")
        default: return .secondary
        }
    }
}

extension ConnectionStatus.Tone {
    var color: Color {
        switch self {
        case .live: return .green
        case .pending, .neutral: return .gray
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Round status glyph in the popover header, filled with the connection tone.
struct ConnectionBadge: View {
    let status: ConnectionStatus

    var body: some View {
        Circle()
            .fill(status.tone.color.gradient)
            .frame(width: 30, height: 30)
            .overlay {
                glyph
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if status.symbol.contains("radiowaves") {
            Image(systemName: status.symbol)
                .symbolEffect(.variableColor.iterative, isActive: status.isWorking)
        } else {
            Image(systemName: status.symbol)
                .symbolEffect(.pulse, isActive: status.isWorking)
        }
    }
}

/// Subtle rounded background that groups related rows, like a Control Center module.
struct Platter: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Color.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

extension View {
    func platter(cornerRadius: CGFloat = 10) -> some View {
        modifier(Platter(cornerRadius: cornerRadius))
    }
}

/// Small round icon button. `.tinted` marks a control whose state is on (a running timer);
/// `.prominent` fills it with the accent color for the one action that matters right now.
struct IconButtonStyle: ButtonStyle {
    enum Emphasis {
        case plain
        case tinted
        case prominent
    }

    var emphasis: Emphasis = .plain

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, emphasis: emphasis)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let emphasis: IconButtonStyle.Emphasis

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 24, height: 24)
            .background(Circle().fill(background))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var foreground: AnyShapeStyle {
        switch emphasis {
        case .plain: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        case .tinted: return AnyShapeStyle(Color.accentColor)
        case .prominent: return AnyShapeStyle(Color.white)
        }
    }

    private var background: Color {
        let active = isHovering && isEnabled
        switch emphasis {
        case .plain:
            if configuration.isPressed { return Color.primary.opacity(0.16) }
            return active ? Color.primary.opacity(0.09) : .clear
        case .tinted:
            if configuration.isPressed { return Color.accentColor.opacity(0.32) }
            return Color.accentColor.opacity(active ? 0.24 : 0.15)
        case .prominent:
            return Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)
        }
    }
}

/// Horizontal stacked bar: each port's share of the charger's combined output limit,
/// separated by 2 pt gaps, on a neutral track.
struct PowerShareBar: View {
    struct Segment: Identifiable, Equatable {
        let index: Int
        let watts: Double
        var id: Int { index }
    }

    let segments: [Segment]
    var capacity: Double = ChargerTelemetry.capacityWatts
    var height: CGFloat = 8

    private static let gap: CGFloat = 2
    private static let minimumSegmentWidth: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.watts >= 0.5 }
            let total = visible.reduce(0) { $0 + $1.watts }
            let hasRemainder = total < capacity
            let gapCount = CGFloat(max(0, visible.count - 1 + (hasRemainder && !visible.isEmpty ? 1 : 0)))
            let usable = max(0, proxy.size.width - gapCount * Self.gap)

            HStack(spacing: Self.gap) {
                ForEach(visible) { segment in
                    Rectangle()
                        .fill(PortPalette.color(segment.index))
                        .frame(width: max(Self.minimumSegmentWidth, usable * min(1, segment.watts / capacity)))
                        .help("C\(segment.index) · \(AppModel.compactWatts(segment.watts)) W")
                }
                if hasRemainder {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.4), value: segments)
    }
}

/// Text row for app-level actions at the bottom of the popover, with a native-style inset
/// hover highlight and an optional keyboard shortcut hint.
struct MenuActionRow: View {
    let title: String
    var systemImage: String
    var shortcut: KeyboardShortcut? = nil
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut.displayText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalKeyboardShortcut(shortcut: shortcut))
        .onHover { isHovering = $0 }
        .modifier(OptionalHelp(text: help))
        .padding(.horizontal, 6)
    }
}

extension KeyboardShortcut {
    /// Menu-style rendering such as "⌘," or "⌘Q".
    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key.character).uppercased()
    }
}

private struct OptionalKeyboardShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

struct OptionalHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// Grouped section in the style of System Settings: a caption title over a rounded card.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .platter()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One labeled row inside a `SettingsSection`.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    var showsDivider = true
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            if showsDivider {
                Divider().padding(.leading, 12)
            }
        }
    }
}
