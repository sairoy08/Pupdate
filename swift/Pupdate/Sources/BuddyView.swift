import SwiftUI

/// The pet. Pet it by rubbing a finger across it (a tap does nothing); hold still for 2 s for a silent alert.
struct BuddyView: View {
    let form: String
    var species: String? = "dog"
    let mood: Mood
    var size: CGFloat = 240
    var pedestal = true
    var onPet: (() -> Void)?
    var onDuress: (() -> Void)?

    /// Idle bob and worried shake, driven by a clock instead of repeatForever animations. Restarting a
    /// repeatForever on a mood change got coalesced by SwiftUI (false then true in one update), so the bob
    /// stayed stuck at its first speed and the shake could not speed up. The clock keeps phase continuous,
    /// so a mood change eases into the new speed with no jump.
    @State private var motion = IdleMotion()
    // Stroke state
    @State private var hand: CGPoint?
    @State private var lean: Double = 0
    @State private var squash: CGFloat = 1
    @State private var strokeDist: CGFloat = 0
    @State private var lastPoint: CGPoint?
    @State private var hearts: [Heart] = []

    struct Heart: Identifiable { let id = UUID(); let x: CGFloat; var rise = false }

    private var glow: Color {
        switch mood {
        case .calm, .happy: return Palette.gold
        case .asking: return Palette.sky
        case .worried: return Palette.warn
        case .alarmed: return Palette.alert
        }
    }

    private var badge: Sprite? {
        switch mood {
        case .asking: return .question
        case .worried: return .sweat
        case .alarmed: return .exclaim
        case .happy: return isDog ? nil : .sparkles   // the dog shows its own hearts
        case .calm: return nil
        }
    }

    private var isDog: Bool { VECTOR_SPECIES.contains(species ?? "") }
    /// 0...1 while a rub is in progress (drives the dog's lean-in).
    private var rubbing: CGFloat { hand == nil ? 0 : max(0.35, min(1, strokeDist / strokeNeeded)) }
    private var look: CGPoint {
        guard let h = hand else { return .zero }
        return CGPoint(x: max(-1, min(1, h.x / size * 2 - 1)), y: max(-1, min(1, h.y / size * 2 - 1)))
    }

    private var bobSpeed: Double { mood == .alarmed ? 0.28 : mood == .worried ? 0.5 : 1.3 }
    /// Where the head is, as a fraction of sprite width from center (side-view pets face left).
    private var headX: CGFloat {
        switch species ?? "dog" { case "penguin", "sloth", "chick": return 0; case "seal", "turtle": return -0.3; default: return -0.24 }
    }
    private var strokeNeeded: CGFloat { size * 0.75 } // a real rub, not a flick

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: Motion.reduced)) { ctx in
            let m = motion.step(ctx.date, bobPeriod: bobSpeed * 2, bobAmp: mood == .alarmed ? 5 : 14,
                                shakePeriod: (mood == .alarmed ? 0.08 : 0.14) * 2,
                                shakeOn: mood == .alarmed || mood == .worried, still: Motion.reduced)
            stage(bobT: m.bob, bobAmp: m.bobAmp, shakeDeg: m.shake)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let badge {
                SpriteIcon(badge, size: size * 0.11)
                    .frame(width: size * 0.17, height: size * 0.17)
                    .background(Circle().fill(Palette.card2))
                    .rotationEffect(.degrees(12))
                    .offset(x: -size * 0.04, y: size * 0.02)
                    .id(badge)
                    .transition(Motion.reduced ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .animation(Motion.reduced ? nil : .spring(response: 0.4, dampingFraction: 0.5), value: badge)
        .contentShape(Rectangle())
        .gesture(stroke)
        .onTapGesture {
            // Accessibility option: some people can't rub the screen, so Settings can allow tap-to-pet.
            if UserDefaults.standard.string(forKey: "wb.petStyle") == "tap" { completePet() }
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 2).onEnded { _ in onDuress?() })
        .accessibilityElement()
        .accessibilityLabel("Your buddy")
        .accessibilityHint(UserDefaults.standard.string(forKey: "wb.petStyle") == "tap" ? "Tap to pet" : "Rub your finger across to pet")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { completePet() }
    }

    /// bobT 0...1 (0 = resting), shakeDeg in degrees.
    @ViewBuilder private func stage(bobT: CGFloat, bobAmp: CGFloat, shakeDeg: Double) -> some View {
        let sprite = size * 0.74
        ZStack(alignment: .bottom) {
            if pedestal {
                Ellipse().fill(Palette.bg).frame(width: size * 0.66, height: size * 0.15).offset(y: -size * 0.03)
                Ellipse()
                    .fill(Palette.card2)
                    .frame(width: size * 0.66, height: size * 0.14)
                    .overlay(Ellipse().stroke(.white.opacity(0.12), lineWidth: 1))
                    .offset(y: -size * 0.05)
            }
            Ellipse()
                .fill(.black.opacity(0.35))
                .frame(width: sprite * 0.5, height: sprite * 0.08)
                .scaleEffect(x: 1 - 0.2 * bobT)
                .offset(y: -size * 0.09)
            ZStack(alignment: .top) {
                if isDog {
                    // The dog reacts on its own: leans in and closes its eyes while you rub,
                    // wags hard and shows its tongue when happy, tucks its tail when worried.
                    DogView(form: form, mood: dogMood(mood), size: sprite * 1.08, animated: !Motion.reduced,
                            petting: rubbing, look: look)
                } else {
                    petSprite(species, form).image
                        .resizable().scaledToFit()
                        .frame(width: sprite, height: sprite)
                }
                if let gear = petGear(species, form) {
                    gear.image.resizable().scaledToFit()
                        .frame(width: sprite * (gear == .crown ? 0.42 : 0.3))
                        .offset(x: gear == .crown ? sprite * headX : sprite * 0.32, y: gear == .crown ? -sprite * 0.12 : sprite * 0.52)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
            }
            .scaleEffect(x: 2 - squash, y: squash, anchor: .bottom)
            .rotationEffect(.degrees(shakeDeg + lean), anchor: .bottom)
            .offset(y: -size * 0.1 - bobT * bobAmp)
            .id("\(species ?? "dog")-\(form)") // new look pops in on evolution or a species change
            .transition(.scale(scale: 0.3).combined(with: .opacity))

            // Hearts from a finished stroke.
            ForEach(hearts) { h in
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.1, weight: .bold))
                    .foregroundStyle(Color(hex: 0xff6f91))
                    .shadow(color: Color(hex: 0xff6f91).opacity(0.6), radius: 6)
                    .offset(x: h.x, y: h.rise ? -size * 0.95 : -size * 0.45)
                    .opacity(h.rise ? 0 : 1)
                    .scaleEffect(h.rise ? 1.3 : 0.6)
            }
            // The stroking hand follows the finger.
            if let hand {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: size * 0.16, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                    .rotationEffect(.degrees(-20 + lean * 2))
                    .position(hand)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
    }

    private var stroke: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { v in
                hand = v.location
                if let last = lastPoint { strokeDist += hypot(v.location.x - last.x, v.location.y - last.y) }
                lastPoint = v.location
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.6)) {
                    lean = Double(max(-12, min(12, v.translation.width / 8)))
                    squash = 0.93 + 0.07 * cos(Double(strokeDist) / 30)
                }
                if strokeDist >= strokeNeeded {
                    strokeDist = -10_000 // one pet per stroke
                    completePet()
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) { lean = 0; squash = 1 }
                withAnimation(.easeOut(duration: 0.2)) { hand = nil }
                strokeDist = 0
                lastPoint = nil
            }
    }

    private func completePet() {
        if Motion.reduced { onPet?(); return }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.4)) { squash = 0.86 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { squash = 1 }
        }
        for i in 0..<5 {
            let h = Heart(x: CGFloat(i - 2) * size * 0.12 + CGFloat.random(in: -8...8))
            hearts.append(h)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.06) {
                withAnimation(.easeOut(duration: 1.0)) {
                    if let k = hearts.firstIndex(where: { $0.id == h.id }) { hearts[k].rise = true }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { hearts.removeAll { $0.id == h.id } }
        }
        onPet?()
    }


}

/// Phase accumulator for the buddy's idle motion. A class held in @State so the TimelineView can advance it
/// each frame without triggering a re-render; phases carry over when the speed changes, so nothing jumps.
final class IdleMotion {
    private var last: Date?
    private var bobPhase: Double = 0
    private var shakePhase: Double = 0
    private var amp: CGFloat = 14
    private var shakeMix: Double = 0

    func step(_ now: Date, bobPeriod: Double, bobAmp: CGFloat, shakePeriod: Double, shakeOn: Bool, still: Bool)
        -> (bob: CGFloat, bobAmp: CGFloat, shake: Double) {
        if still { last = nil; return (0, bobAmp, 0) }
        let dt = min(0.1, max(0, now.timeIntervalSince(last ?? now)))  // a long pause (backgrounded) doesn't skip ahead
        last = now
        bobPhase = (bobPhase + dt / bobPeriod).truncatingRemainder(dividingBy: 1)
        shakePhase = (shakePhase + dt / shakePeriod).truncatingRemainder(dividingBy: 1)
        let k = min(1, dt * 6)  // ease amplitude and shake in/out over about a sixth of a second
        amp += (bobAmp - amp) * k
        shakeMix += ((shakeOn ? 1 : 0) - shakeMix) * k
        let ease = { (p: Double) in (1 - cos(p * 2 * .pi)) / 2 }  // 0 -> 1 -> 0, like easeInOut autoreverse
        return (CGFloat(ease(bobPhase)), amp, 7 * ease(shakePhase) * shakeMix)
    }
}
