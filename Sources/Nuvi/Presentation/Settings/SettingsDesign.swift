import SwiftUI

/// Small design system that gives the Settings UI a SuperWhisper-like feel:
/// dark cards, colored sidebar icon tiles, section headers, keycap chips.
/// Centralizing it keeps the panels declarative and consistent.
enum NuviTheme {
    static let background = Color(white: 0.11)
    static let card = Color(white: 0.16)
    static let cardStroke = Color.white.opacity(0.06)
    static let separator = Color.white.opacity(0.07)
    static let keycap = Color(white: 0.26)
}

/// Colored rounded-square icon, like the sidebar tiles in SuperWhisper.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Uppercase muted section header above a card.
struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

/// Rounded dark container that stacks rows with inset separators.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(NuviTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NuviTheme.cardStroke, lineWidth: 1)
        )
    }
}

/// One row inside a Card: title + optional subtitle on the left, control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Inset divider used between rows in a Card.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(NuviTheme.separator)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

/// Small keycap chip, e.g. ⌥ or Space.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(NuviTheme.keycap, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Renders a shortcut like "⌥ Space" as a row of keycaps.
struct Shortcut: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { Keycap(text: $0) }
        }
    }
}
