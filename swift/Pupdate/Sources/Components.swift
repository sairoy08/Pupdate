import SwiftUI

/// Screen background: one flat neutral.
struct Sky: View {
    var body: some View { Palette.bg.ignoresSafeArea() }
}

/// Chunky game button: a darker lip underneath that the face presses down into.
struct GameButtonStyle: ButtonStyle {
    enum Kind { case gold, ok, danger, ghost }
    var kind: Kind = .gold
    @Environment(\.isEnabled) private var enabled

    private var colors: (face: Color, lip: Color, fg: Color) {
        switch kind {
        case .gold: return (Palette.gold, Palette.goldDeep, Palette.ink)
        case .ok: return (Palette.ok, Palette.okDeep, Color(hex: 0x032417))
        case .danger: return (Palette.alert, Palette.alertDeep, .white)
        case .ghost: return (Palette.card2, Palette.card2, Palette.text)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let c = colors
        return configuration.label
            .font(Typeface.bold(17))
            .foregroundStyle(c.fg)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.face))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

struct GameButton: View {
    let title: String
    var kind: GameButtonStyle.Kind = .gold
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if busy { ProgressView().tint(kind == .ghost ? Palette.text : Palette.ink) } else { Text(title) }
        }
        .buttonStyle(GameButtonStyle(kind: kind))
        .disabled(busy)
    }
}

/// HUD chip: a 3D icon and a number, like a game's currency counter.
struct StatChip: View {
    let sprite: Sprite
    let value: String
    var tint: Color = Palette.text
    var body: some View {
        HStack(spacing: 6) {
            SpriteIcon(sprite, size: 20)
            Text(value).font(Typeface.display(17)).foregroundStyle(tint).monospacedDigit()
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 4)
        .background(Capsule().fill(Palette.card2))
        .fixedSize()
    }
}

struct GameCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
    }
}

struct Pill: View {
    let text: String
    var tint: Color = Palette.gold
    var body: some View {
        Text(text)
            .font(Typeface.bold(13))
            .foregroundStyle(tint)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct Banner: View {
    let text: String
    var alert = false
    var body: some View {
        Text(text)
            .font(Typeface.semi(15))
            .foregroundStyle(alert ? Color(hex: 0xffb4b0) : Color(hex: 0xffdf9a))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(alert ? Color(hex: 0x3a1715) : Color(hex: 0x33290f)))
    }
}

struct SectionTitle: View {
    let text: String
    var sub: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(Typeface.displayBold(19)).foregroundStyle(Palette.text)
            if let sub { Text(sub).font(Typeface.body(14)).foregroundStyle(Palette.muted) }
        }
    }
}

/// Thick, glossy XP bar with level badge.
struct XPBar: View {
    let buddy: BuddyInfo
    let next: Int?
    var body: some View {
        let prev = buddy.form == "sprout" ? 0 : buddy.form == "strider" ? 100 : 250
        let pct = next.map { max(0, min(1, Double(buddy.xp - prev) / Double($0 - prev))) } ?? 1
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(buddy.name).font(Typeface.display(22)).foregroundStyle(Palette.text)
                Text(formName(buddy.form, species: buddy.species)).font(Typeface.semi(15)).foregroundStyle(Palette.muted)
                Spacer()
                Text(next.map { "\(buddy.xp) / \($0) XP" } ?? "\(buddy.xp) XP")
                    .font(Typeface.bold(14)).foregroundStyle(Palette.muted).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.card2)
                    Capsule().fill(Palette.gold)
                        .frame(width: max(10, geo.size.width * pct))
                        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: pct)
                }
            }
            .frame(height: 8)
        }
    }
}
