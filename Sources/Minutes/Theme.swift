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
    static let ink = Color(hex: 0xEF_E8_D2)
    static let muted = Color(hex: 0xA9_AB_93)
    static let faint = Color(hex: 0x75_79_5F)
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
