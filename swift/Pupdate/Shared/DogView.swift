import SwiftUI

// The dog buddy. Shared by the app and the Live Activity widget.
// Artwork: DogArt.swift (generated from tools/dog_art.py). Poses and face here mirror
// tools/dog_preview.py, so the preview images match what the phone draws.
//
// In the app the dog is alive: tail wags (fast when happy, tucked when scared), it breathes,
// blinks, its eyes follow your finger, and it leans into a downward pet with its eyes closed.
// In the Live Activity iOS doesn't run custom animations, so the dog shows one pose per update
// and each update swaps its expression.

enum DogMood: String, Codable, Hashable {
    case calm, asking, worried, alarmed, happy, petting

    /// Map a walk-engine state (calm, checkin, nudge, final, countdown, alert) to a mood.
    static func from(walkState s: String) -> DogMood {
        switch s {
        case "checkin": return .asking
        case "nudge", "final": return .worried
        case "countdown", "alert": return .alarmed
        case "happy": return .happy
        default: return .calm
        }
    }
}

enum DogFill {
    case none
    case flat(UInt32)
    case grad(UInt32, UInt32)
}

enum DogShape {
    case ellipse(Double, Double, Double, Double, rot: Double)
    case path(String)
}

struct DogPart {
    let layer: String
    let shape: DogShape
    let fill: DogFill
    let opacity: Double
    let forms: [String]
    var stroke: UInt32? = nil
    var strokeWidth: Double = 0

    var path: Path {
        switch shape {
        case let .ellipse(cx, cy, w, h, rot):
            var p = Path(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            if rot != 0 { p = p.applying(dogRotation(rot, around: CGPoint(x: cx, y: cy))) }
            return p
        case let .path(d):
            return DogPathCache.shared.path(d)
        }
    }
}

func dogColor(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255, opacity: alpha)
}

func dogRotation(_ deg: Double, around c: CGPoint) -> CGAffineTransform {
    CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180).translatedBy(x: -c.x, y: -c.y)
}

/// Pose numbers per mood. Same table as pose() in tools/dog_preview.py.
struct DogPose {
    var tilt: Double = 0, earL: Double = 0, earR: Double = 0, tail: Double = 0, headDY: Double = 0

    init(_ mood: DogMood, petting: Double) {
        switch mood {
        case .calm: break
        case .asking: tilt = -9; earL = 24; earR = -2; tail = -8; headDY = -1
        case .worried: tilt = 4; earL = -10; earR = 10; tail = 30; headDY = 1
        case .alarmed: earL = 16; earR = -16; tail = 55
        case .happy: tilt = 6; earL = 12; earR = -12; tail = -14; headDY = -2
        case .petting: earL = -12; earR = 12; tail = -6; headDY = 3
        }
        if petting > 0 { earL -= 12 * petting; earR += 12 * petting; headDY += 3 * petting }
    }
}

struct DogView: View {
    var form: String = "sprout"
    var mood: DogMood = .calm
    var size: CGFloat = 200
    var animated = true
    var petting: CGFloat = 0     // 0...1 while a finger strokes down the dog
    var look: CGPoint = .zero    // -1...1, where the eyes look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    DogCanvas(form: form, mood: effectiveMood, t: ctx.date.timeIntervalSinceReferenceDate, live: true,
                              petting: Double(petting), look: look, u: size / 100)
                }
            } else {
                DogCanvas(form: form, mood: effectiveMood, t: 0, live: false, petting: Double(petting), look: look, u: size / 100)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Your dog, \(effectiveMood.rawValue)")
    }

    private var effectiveMood: DogMood { petting > 0.3 && mood != .happy ? .petting : mood }
}

private struct DogCanvas: View {
    let form: String
    let mood: DogMood
    let t: Double
    let live: Bool
    let petting: Double
    let look: CGPoint
    let u: CGFloat

    var body: some View {
        let pose = DogPose(mood, petting: petting)
        let wag = live ? tailWag : 0
        let breath = live ? CGFloat(sin(t * 1.7)) * 0.012 : 0
        let hop = live && mood == .happy ? -abs(CGFloat(sin(t * 7))) * 2.5 : 0
        let shake = live && mood == .alarmed ? CGFloat(sin(t * 50)) * 0.9 : 0
        let blink = live && (mood == .calm || mood == .asking || mood == .worried) && t.truncatingRemainder(dividingBy: 4.1) < 0.12
        ZStack {
            Ellipse().fill(Color.black.opacity(0.25)).frame(width: 60 * u, height: 6 * u).position(x: 50 * u, y: 98 * u)
            ZStack {
                layer("tail").rotationEffect(.degrees(pose.tail + wag), anchor: UnitPoint(x: 0.70, y: 0.82))
                layer("body")
            }
            .scaleEffect(x: 1 + breath, y: 1 - breath, anchor: .bottom)
            ZStack {
                layer("earL").rotationEffect(.degrees(pose.earL + (live ? earFlop : 0)), anchor: UnitPoint(x: 0.32, y: 0.32))
                layer("earR").rotationEffect(.degrees(pose.earR - (live ? earFlop : 0)), anchor: UnitPoint(x: 0.68, y: 0.32))
                layer("head")
                DogFace(mood: mood, petting: petting, blink: blink, look: look, u: u)
                layer("gear")
            }
            .scaleEffect(x: 1 + petting * 0.03, y: 1 - petting * 0.04, anchor: UnitPoint(x: 0.5, y: 0.7))
            .rotationEffect(.degrees(pose.tilt + (live && mood == .asking ? sin(t * 2.2) * 2 : 0)), anchor: UnitPoint(x: 0.5, y: 0.7))
            .offset(y: pose.headDY * u)
            if mood == .happy { hearts }
        }
        .frame(width: 100 * u, height: 100 * u)
        .offset(x: shake * u, y: hop * u)
    }

    private var tailWag: Double {
        switch mood {
        case .happy: return sin(t * 16) * 26
        case .petting: return sin(t * 12) * 18
        case .calm: return sin(t * 4) * 10
        case .asking: return sin(t * 3) * 6
        case .worried: return 0
        case .alarmed: return sin(t * 40) * 2
        }
    }

    private var earFlop: Double { mood == .happy ? sin(t * 14) * 5 : (mood == .calm ? sin(t * 1.7) * 1.5 : 0) }

    @ViewBuilder private func layer(_ name: String) -> some View {
        let parts = DogArt.parts.filter { $0.layer == name && ($0.forms.isEmpty || $0.forms.contains(form)) }
        ZStack {
            ForEach(parts.indices, id: \.self) { i in
                DogPartView(part: parts[i], u: u)
            }
        }
        .frame(width: 100 * u, height: 100 * u)
    }

    private var hearts: some View {
        let f = live ? t.truncatingRemainder(dividingBy: 1.6) / 1.6 : 0.3
        return ZStack {
            Image(systemName: "heart.fill").font(.system(size: 12 * u)).foregroundStyle(dogColor(0xFF5C86))
                .position(x: 82 * u, y: (18 - 10 * f) * u).opacity(1 - f * 0.7)
            Image(systemName: "heart.fill").font(.system(size: 7 * u)).foregroundStyle(dogColor(0xFF8FB0))
                .position(x: 16 * u, y: (28 - 8 * f) * u).opacity(1 - f * 0.6)
        }
    }
}

private struct DogPartView: View {
    let part: DogPart
    let u: CGFloat

    var body: some View {
        let shape = DogGridShape(path: part.path)
        ZStack {
            switch part.fill {
            case .none:
                EmptyView()
            case let .flat(c):
                shape.fill(dogColor(c))
            case let .grad(a, b):
                // Shade relative to the part's own bounds (light at its top-left), like SVG objectBoundingBox.
                let bb = part.path.boundingRect
                shape.fill(RadialGradient(colors: [dogColor(a), dogColor(b)],
                                          center: UnitPoint(x: (bb.minX + bb.width * 0.35) / 100, y: (bb.minY + bb.height * 0.28) / 100),
                                          startRadius: 0, endRadius: max(bb.width, bb.height) * 0.8 * u))
            }
            if let s = part.stroke {
                shape.stroke(dogColor(s), style: StrokeStyle(lineWidth: part.strokeWidth * u, lineCap: .round))
            }
        }
        .frame(width: 100 * u, height: 100 * u)
        .opacity(part.opacity)
    }
}

/// Face drawn per mood. Mirrors face() in tools/dog_preview.py.
private struct DogFace: View {
    let mood: DogMood
    let petting: Double
    let blink: Bool
    let look: CGPoint
    let u: CGFloat

    private var line: Color { dogColor(DogArt.line) }

    var body: some View {
        let ey = DogArt.eyeY, dx = DogArt.eyeDX, my = DogArt.mouthY
        let content = mood == .petting || petting > 0.3
        let happy = mood == .happy || content
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { s in
                stroke(Path(ellipseIn: CGRect(x: 50 + s * DogArt.cheekDX - 4.6, y: DogArt.cheekY - 2.6, width: 9.2, height: 5.2)),
                       fill: dogColor(0xFF8FA3, happy ? 0.85 : 0.5))
            }
            ForEach([-1.0, 1.0], id: \.self) { s in
                eye(x: 50 + s * dx, y: ey, content: content)
            }
            if mood == .asking || mood == .worried || mood == .alarmed {
                let ang: Double = mood == .asking ? 14 : (mood == .worried ? -20 : -14)
                ForEach([-1.0, 1.0], id: \.self) { s in
                    let x = 50 + s * dx
                    let by = ey - 9 - (mood == .asking && s == -1 ? 1.5 : 0)
                    stroke(seg(x - 3.5, by, x + 3.5, by).applying(dogRotation(ang * -s, around: CGPoint(x: x, y: by))),
                           color: dogColor(0x8C4E22), width: 2)
                }
            }
            mouth(my)
        }
        .frame(width: 100 * u, height: 100 * u)
    }

    @ViewBuilder private func eye(x: Double, y: Double, content: Bool) -> some View {
        if content || blink {
            stroke(curve(x - 4.5, y, x, y + 4.2, x + 4.5, y), color: line, width: 2.2)
        } else if mood == .happy {
            stroke(curve(x - 4.5, y + 1.5, x, y - 4.5, x + 4.5, y + 1.5), color: line, width: 2.2)
        } else if mood == .alarmed {
            stroke(Path(ellipseIn: CGRect(x: x - 6, y: y - 6.4, width: 12, height: 12.8)), fill: .white, color: line, width: 1)
            stroke(circle(x + look.x, y + look.y, 2.6), fill: dogColor(DogArt.iris))
            stroke(circle(x + look.x + 0.9, y + look.y - 1, 0.9), fill: .white)
        } else {
            let lx = Double(look.x) * 1.2, ly = Double(look.y)
            stroke(Path(ellipseIn: CGRect(x: x - DogArt.eyeW / 2, y: y - DogArt.eyeW / 2 * 1.1, width: DogArt.eyeW, height: DogArt.eyeW * 1.1)),
                   fill: dogColor(DogArt.iris))
            stroke(Path(ellipseIn: CGRect(x: x + lx + 1.8 - 2.2, y: y + ly - 2.2 - 2.4, width: 4.4, height: 4.8)), fill: .white)
            stroke(circle(x + lx - 1.8, y + ly + 2.2, 1), fill: dogColor(0xFFFFFF, 0.85))
        }
    }

    @ViewBuilder private func mouth(_ my: Double) -> some View {
        switch mood {
        case .alarmed:
            stroke(Path(ellipseIn: CGRect(x: 47.2, y: my + 1.5 - 3.4, width: 5.6, height: 6.8)), fill: dogColor(0x5A2230))
        case .happy:
            stroke(Path { p in
                p.move(to: CGPoint(x: 43.5, y: my - 1.5))
                p.addQuadCurve(to: CGPoint(x: 56.5, y: my - 1.5), control: CGPoint(x: 50, y: my + 9))
                p.addQuadCurve(to: CGPoint(x: 43.5, y: my - 1.5), control: CGPoint(x: 50, y: my + 0.5))
                p.closeSubpath()
            }, fill: dogColor(0x5A2230))
            stroke(Path { p in
                p.move(to: CGPoint(x: 47, y: my + 2.5))
                p.addQuadCurve(to: CGPoint(x: 50, y: my + 9.5), control: CGPoint(x: 47, y: my + 9.5))
                p.addQuadCurve(to: CGPoint(x: 53, y: my + 2.5), control: CGPoint(x: 53, y: my + 9.5))
                p.addQuadCurve(to: CGPoint(x: 47, y: my + 2.5), control: CGPoint(x: 50, y: my + 4))
                p.closeSubpath()
            }, fill: dogColor(0xFF7E99))
            stroke(seg(50, my + 4, 50, my + 8), color: dogColor(0xE25A79), width: 0.8)
        case .worried:
            stroke(Path { p in
                p.move(to: CGPoint(x: 50, y: my - 3.5)); p.addLine(to: CGPoint(x: 50, y: my - 1.5))
                p.move(to: CGPoint(x: 45.5, y: my + 0.8))
                p.addQuadCurve(to: CGPoint(x: 50, y: my + 0.5), control: CGPoint(x: 47.7, y: my - 1.2))
                p.addQuadCurve(to: CGPoint(x: 54.5, y: my + 0.2), control: CGPoint(x: 52.3, y: my + 2))
            }, color: line, width: 1.5)
        default:
            stroke(Path { p in
                p.move(to: CGPoint(x: 50, y: my - 3.5)); p.addLine(to: CGPoint(x: 50, y: my - 1))
                p.move(to: CGPoint(x: 45.5, y: my - 1.5))
                p.addQuadCurve(to: CGPoint(x: 50, y: my - 1), control: CGPoint(x: 47.75, y: my + 1.6))
                p.addQuadCurve(to: CGPoint(x: 54.5, y: my - 1.5), control: CGPoint(x: 52.25, y: my + 1.6))
            }, color: line, width: 1.5)
        }
    }

    private func seg(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Path {
        Path { p in p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)) }
    }

    private func curve(_ x1: Double, _ y1: Double, _ cx: Double, _ cy: Double, _ x2: Double, _ y2: Double) -> Path {
        Path { p in p.move(to: CGPoint(x: x1, y: y1)); p.addQuadCurve(to: CGPoint(x: x2, y: y2), control: CGPoint(x: cx, y: cy)) }
    }

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    @ViewBuilder private func stroke(_ path: Path, fill: Color? = nil, color: Color? = nil, width: Double = 1) -> some View {
        let shape = DogGridShape(path: path)
        ZStack {
            if let fill { shape.fill(fill) }
            if let color { shape.stroke(color, style: StrokeStyle(lineWidth: width * u, lineCap: .round, lineJoin: .round)) }
        }
        .frame(width: 100 * u, height: 100 * u)
    }
}

/// A path in the 100 x 100 grid, scaled to its frame.
struct DogGridShape: Shape {
    var path: Path
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100))
    }
}

/// Parses each SVG path string once (M L H V Q C Z, absolute and relative).
final class DogPathCache {
    static let shared = DogPathCache()
    private var cache: [String: Path] = [:]
    private let lock = NSLock()

    func path(_ d: String) -> Path {
        lock.lock(); defer { lock.unlock() }
        if let p = cache[d] { return p }
        let p = Self.parse(d)
        cache[d] = p
        return p
    }

    static func parse(_ d: String) -> Path {
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if ch.isLetter {
                flush(); tokens.append(String(ch))
            } else if ch == "-" {
                flush(); num.append(ch)
            } else if ch.isNumber || ch == "." {
                if ch == ".", num.contains(".") { flush() }
                num.append(ch)
            } else {
                flush()
            }
        }
        flush()
        var path = Path()
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        func n() -> CGFloat? {
            guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter {
                cmd = c; i += 1
                if c == "Z" || c == "z" { path.closeSubpath(); cur = start; continue }
            }
            let rel = cmd.isLowercase
            let ox = rel ? cur.x : 0, oy = rel ? cur.y : 0
            switch cmd {
            case "M", "m":
                guard let x = n(), let y = n() else { i += 1; continue }
                cur = CGPoint(x: ox + x, y: oy + y); start = cur; path.move(to: cur)
                cmd = rel ? "l" : "L"
            case "L", "l":
                guard let x = n(), let y = n() else { i += 1; continue }
                cur = CGPoint(x: ox + x, y: oy + y); path.addLine(to: cur)
            case "H", "h":
                guard let x = n() else { i += 1; continue }
                cur = CGPoint(x: ox + x, y: cur.y); path.addLine(to: cur)
            case "V", "v":
                guard let y = n() else { i += 1; continue }
                cur = CGPoint(x: cur.x, y: oy + y); path.addLine(to: cur)
            case "Q", "q":
                guard let x1 = n(), let y1 = n(), let x = n(), let y = n() else { i += 1; continue }
                let c1 = CGPoint(x: ox + x1, y: oy + y1)
                cur = CGPoint(x: ox + x, y: oy + y); path.addQuadCurve(to: cur, control: c1)
            case "C", "c":
                guard let x1 = n(), let y1 = n(), let x2 = n(), let y2 = n(), let x = n(), let y = n() else { i += 1; continue }
                let c1 = CGPoint(x: ox + x1, y: oy + y1), c2 = CGPoint(x: ox + x2, y: oy + y2)
                cur = CGPoint(x: ox + x, y: oy + y); path.addCurve(to: cur, control1: c1, control2: c2)
            default:
                i += 1
            }
        }
        return path
    }
}

#Preview("Dog moods") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
            ForEach(["sprout", "strider", "guardian"], id: \.self) { f in
                ForEach([DogMood.calm, .asking, .worried, .alarmed, .happy, .petting], id: \.self) { m in
                    VStack { DogView(form: f, mood: m, size: 100); Text("\(f) \(m.rawValue)").font(.caption2) }
                }
            }
        }
    }
    .background(Color.black)
}
