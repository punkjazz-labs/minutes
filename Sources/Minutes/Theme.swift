import MinutesCore
import SwiftUI

/// The approved palette and scale, in one place. Every value here comes from
/// the design, so a colour is changed once rather than in nine views.
enum Ink {
    static let bg = Color(hex: 0x13_15_19)
    static let surface = Color(hex: 0x18_1A_1F)
    static let surface2 = Color(hex: 0x22_24_2B)
    static let panel = Color(hex: 0x16_18_1D)
    static let hover = Color(hex: 0x1D_1F_25)
    static let line = Color(hex: 0x2C_2F_37)
    static let lineStrong = Color(hex: 0x40_44_4F)
    static let ink = Color(hex: 0xF0_F1_F4)
    static let muted = Color(hex: 0xA9_AF_BA)
    static let faint = Color(hex: 0x85_8D_9A)
    static let accent = Color(hex: 0xDD_3C_10)
    static let accentInk = Color(hex: 0xFF_F4_E8)
    static let accentDeep = Color(hex: 0xF2_70_3C)
    static let warn = Color(hex: 0xD9_A1_2F)
    static let fail = Color(hex: 0xE0_64_4E)
    static let them = Color(hex: 0x8F_A8_C7)
    static let hot = Color(hex: 0x3A_24_19)
}

enum Size {
    static let body: CGFloat = 13.5
    static let row: CGFloat = 12.5
    static let small: CGFloat = 11.5
    static let tiny: CGFloat = 11
    static let label: CGFloat = 10.5
}

extension Font {
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

/// The small uppercase label above a pane and above a column.
struct PaneLabel: View {
    let text: String
    var color: Color = Ink.faint

    var body: some View {
        Text(text.uppercased())
            .font(.ui(Size.label, weight: .medium))
            .tracking(0.9)
            .foregroundStyle(color)
    }
}

/// A borderless word that behaves like a button, as every action in the design
/// does. AppKit's own button chrome is not in the design.
struct WordButton: View {
    let title: String
    var tint: Color = Ink.faint
    var hoverTint: Color = Ink.ink
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(Size.small))
                .foregroundStyle(hovering ? hoverTint : tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The outlined button in the design: the header action and nothing else.
struct OutlineButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(12, weight: .semibold))
                .foregroundStyle(enabled ? Ink.ink : Ink.faint)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering && enabled ? Ink.hover : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.lineStrong)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// The timestamp chip that links a note line to the transcript.
struct AnchorChip: View {
    let label: String
    let hot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.mono(Size.label))
                .foregroundStyle(hot ? Ink.accentDeep : Ink.faint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Ink.bg)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(hot ? Ink.accentDeep : Ink.line)))
        }
        .buttonStyle(.plain)
    }
}

struct HLine: View {
    var body: some View {
        Rectangle().fill(Ink.line).frame(height: 1)
    }
}

extension Font {
    /// Meeting titles. A serif, so a title reads as the name of a document and
    /// not as the label of a control.
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}

/// A small rounded fact about a meeting: when, how long, who was recorded.
struct Chip: View {
    let text: String
    var systemImage: String?
    var color: Color = Ink.muted

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
            }
            Text(text).font(.ui(Size.small, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color == Ink.muted ? Ink.surface2 : color.opacity(0.14)))
        .overlay(Capsule().stroke(color == Ink.muted ? Ink.line : color.opacity(0.35), lineWidth: 1))
        .fixedSize()
    }
}

extension NotesState {
    /// The state as a chip: colour for the two a person must act on.
    var chipColor: Color {
        switch self {
        case .written: return Ink.muted
        case .pending: return Ink.warn
        case .transcriptOnly: return Ink.muted
        case .transcriptionFailed: return Ink.fail
        }
    }

    var symbol: String {
        switch self {
        case .written: return "checkmark"
        case .pending: return "clock"
        case .transcriptOnly: return "text.alignleft"
        case .transcriptionFailed: return "exclamationmark.triangle.fill"
        }
    }

    /// The words on the chip. Pending is said as what it is to the reader.
    var chipText: String { self == .pending ? "Notes pending" : label }
}

/// An icon that behaves like a button, with its name on hover, because an
/// icon alone is a guess.
struct IconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = Ink.muted
    var hoverTint: Color = Ink.ink
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? hoverTint : tint)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Ink.surface2 : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// The field that finds words in a transcript: a magnifier, the words, a
/// count, and a way to clear them.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var count: String?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.faint)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Ink.faint))
                .textFieldStyle(.plain)
                .font(.ui(Size.row))
                .foregroundStyle(Ink.ink)
                .onSubmit(onSubmit)
            if let count {
                Text(count).font(.ui(Size.tiny)).foregroundStyle(Ink.faint).fixedSize()
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Ink.bg)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.line)))
    }
}

/// Who spoke, as a letter in a circle: your side in the accent, the other side
/// in its own blue, the way the transcript has always told them apart.
struct SpeakerBadge: View {
    let speaker: String
    let isOwner: Bool
    var size: CGFloat = 20

    var body: some View {
        Text(String(speaker.prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Ink.bg)
            .frame(width: size, height: size)
            .background(Circle().fill(isOwner ? Ink.accentDeep : Ink.them))
            .accessibilityHidden(true)
    }
}

/// A few bars that move with a track's level, small enough to sit beside its
/// name in a control bar.
struct LevelBars: View {
    let level: Float
    var color: Color
    var active = true

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                let lit = active && min(1, level * 1.8) > threshold
                Capsule()
                    .fill(lit ? color : Ink.lineStrong)
                    .frame(width: 3, height: [6, 10, 13, 10, 6][index])
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}

/// A message in the menu with an icon, tinted by how much it matters, and
/// room for the actions that answer it.
struct Callout<Actions: View>: View {
    enum Tone {
        case info
        case warning
        case problem
    }

    let systemImage: String
    let text: String
    var title: String?
    var tone: Tone = .info
    @ViewBuilder var actions: () -> Actions

    private var color: Color {
        switch tone {
        case .info: return Ink.muted
        case .warning: return Ink.warn
        case .problem: return Ink.fail
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title).font(.ui(Size.row, weight: .semibold)).foregroundStyle(Ink.ink)
                }
                Text(text)
                    .font(.ui(Size.small))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tone == .info ? Ink.panel : color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tone == .info ? Ink.line : color.opacity(0.35))))
    }
}

extension Callout where Actions == EmptyView {
    init(systemImage: String, text: String, title: String? = nil, tone: Tone = .info) {
        self.init(systemImage: systemImage, text: text, title: title, tone: tone, actions: { EmptyView() })
    }
}

/// A word that acts, in the accent or quiet, the way every action in the
/// design is a word rather than chrome.
struct TextAction: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(Size.small, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Ink.accentDeep : Ink.muted)
        }
        .buttonStyle(.plain)
    }
}
