import SwiftUI

func turnSymbol(_ m: String) -> String {
    switch m {
    case "left": return "arrow.turn.up.left"
    case "right": return "arrow.turn.up.right"
    case "slight_left": return "arrow.up.left"
    case "slight_right": return "arrow.up.right"
    case "uturn": return "arrow.uturn.down"
    case "arrive": return "flag.checkered"
    default: return "arrow.up"
    }
}

func formatMeters(_ m: Int) -> String { m >= 1000 ? String(format: "%.1f km", Double(m) / 1000) : "\(m) m" }

/// "In 80 m, turn left onto E University Dr", with the buddy cheering at the turn itself.
struct NextTurnCard: View {
    let turn: NextTurn
    var buddyName = "Melvin"
    var species: String? = "dog"
    var form = "sprout"

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: turnSymbol(turn.maneuver))
                .font(.system(size: 30, weight: .heavy)).foregroundStyle(Palette.ink)
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(turn.near ? Palette.gold : Palette.sky))
                .scaleEffect(turn.near && !Motion.reduced ? 1.06 : 1)
                .animation(Motion.reduced ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: turn.near)
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.near ? (turn.maneuver == "arrive" ? "Almost there!" : "Turn here") : "In \(formatMeters(turn.inM))")
                    .font(Typeface.display(24)).foregroundStyle(turn.near ? Palette.gold : Palette.text)
                    .contentTransition(.numericText())
                Text(turn.text).font(Typeface.semi(15)).foregroundStyle(Palette.text).lineLimit(2)
                if turn.near {
                    HStack(spacing: 5) {
                        PetImage(species: species, form: form, size: 18)
                        Text(buddyLine).font(Typeface.body(13)).foregroundStyle(Palette.muted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(turn.near ? Palette.gold : Palette.lineTop, lineWidth: turn.near ? 2 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(turn.near ? "Turn here: \(turn.text)" : "In \(formatMeters(turn.inM)), \(turn.text)")
        .accessibilityIdentifier("next-turn")
    }

    private var buddyLine: String {
        switch turn.maneuver {
        case "left", "slight_left": return "\(buddyName): this way, turn left!"
        case "right", "slight_right": return "\(buddyName): over here, turn right!"
        case "arrive": return "\(buddyName): we made it!"
        default: return "\(buddyName): keep going straight!"
        }
    }
}

func paceModeText(_ m: String?) -> (String, String, Color) {
    switch m {
    case "vehicle": return ("In a vehicle", "car.fill", Palette.alert)
    case "running": return ("Running", "figure.run", Palette.warn)
    case "still": return ("Standing still", "figure.stand", Palette.muted)
    case "walking": return ("Walking", "figure.walk", Palette.ok)
    default: return ("Measuring pace", "figure.walk", Palette.muted)
    }
}

/// Live pace: mode, speed, a small speed trace, and Gemini's read when it judged something.
struct PaceCard: View {
    let pace: PaceInfo
    var body: some View {
        let (label, icon, tint) = paceModeText(pace.mode)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 36, height: 36).background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Typeface.displayBold(17)).foregroundStyle(Palette.text)
                    Text(pace.kmh.map { String(format: "%.1f km/h", $0) } ?? "Waiting for movement")
                        .font(Typeface.body(13)).foregroundStyle(Palette.muted).monospacedDigit()
                }
                Spacer()
                if pace.judging {
                    HStack(spacing: 5) { ProgressView().tint(Palette.gold).scaleEffect(0.7); Text("Gemini is checking").font(Typeface.bold(11)) }
                        .foregroundStyle(Palette.gold)
                } else if pace.pattern != "steady" {
                    Pill(text: patternText(pace.pattern), tint: Palette.warn)
                } else {
                    Pill(text: "Steady", tint: Palette.ok)
                }
            }
            Sparkline(values: pace.samples, tint: tint).frame(height: 34)
                .accessibilityHidden(true)
            if let note = pace.note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: pace.source == "gemini" ? "sparkles" : "ruler").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(pace.source == "gemini" ? Palette.gold : Palette.muted)
                    Text(note).font(Typeface.body(13)).foregroundStyle(Palette.text)
                }
            }
            Text("Your pace is watched for running, stop-and-go, turning back and car speed. Gemini decides when it's worth a check-in.")
                .font(Typeface.body(11.5)).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pace-card")
    }

    private func patternText(_ p: String) -> String {
        switch p {
        case "running": return "Running"
        case "stop_and_go": return "Stop and go"
        case "backtracking": return "Turned back"
        case "sudden_stop": return "Sudden stop"
        case "vehicle": return "Car speed"
        default: return p
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.gold
    var body: some View {
        GeometryReader { geo in
            let maxV = max(4.0, values.max() ?? 1)
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(min(v, maxV) / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Heads-up for a flag the walker is near or inside.
struct FlagAheadBanner: View {
    let flag: FlagBrief
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: flag.status == "avoid" ? "nosign" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Circle().fill(flagTint(flag.status)))
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.inside == true ? "You're in a flagged spot" : "Flagged spot \(formatMeters(flag.inM ?? 0)) ahead")
                    .font(Typeface.displayBold(16)).foregroundStyle(Palette.text)
                Text("\(flag.byName): \(flag.reason)\(flag.note.map { $0.isEmpty ? "" : ". \($0)" } ?? "")")
                    .font(Typeface.body(13)).foregroundStyle(Palette.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(flagTint(flag.status).opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

/// Warnings that were also sent to friends: long check-in gaps, check-ins off, slow alerts, car speed.
struct NoticeList: View {
    let notices: [Notice]
    var friendView = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, n in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(n.kind)).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.warn)
                        .frame(width: 28, height: 28).background(Circle().fill(Palette.warn.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.text).font(Typeface.body(13.5)).foregroundStyle(Palette.text)
                        if !friendView { Text("Your circle was told.").font(Typeface.body(11.5)).foregroundStyle(Palette.muted) }
                    }
                }
            }
        }
        .accessibilityIdentifier("notices")
    }
    private func icon(_ k: String) -> String {
        switch k {
        case "checkins_off": return "bell.slash.fill"
        case "long_checkins": return "clock.badge.exclamationmark"
        case "slow_alerts": return "hourglass"
        case "in_vehicle": return "car.fill"
        default: return "exclamationmark.circle.fill"
        }
    }
}

/// One-phone testing: trigger every safety feature from the walker's own phone during a demo walk.
struct TestToolsCard: View {
    let walk: Walk
    let flagHere: () -> Void
    @State private var busy: String?
    @State private var msg: String?
    @State private var scrub: Double?   // the slider's value while a finger is on it

    /// Drive the demo walker: pause, direction, speed, where on the route, and arrive.
    @ViewBuilder private func walkerControls(_ sim: SimInfo) -> some View {
        Text("Demo walker").font(Typeface.semi(13)).foregroundStyle(Palette.muted)
        HStack(spacing: 8) {
            tool(sim.paused ? "Resume" : "Pause", sim.paused ? "play.fill" : "pause.fill", "pause") {
                try await API.shared.demo("control", ["action": sim.paused ? "resume" : "pause"])
            }
            tool(sim.dir < 0 ? "Walk forward" : "Walk back", sim.dir < 0 ? "arrow.right" : "arrow.left", "dir") {
                try await API.shared.demo("control", ["action": sim.dir < 0 ? "forward" : "backward"])
            }
        }
        HStack(spacing: 8) {
            ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { x in
                let on = sim.speedOverride == x || (sim.speedOverride == nil && x == 2 && walk.speed == 2)
                Button {
                    Task {
                        // tapping the active speed goes back to automatic (2x walking, 4x while escalating)
                        do { try await API.shared.demo("speed", ["x": on && sim.speedOverride != nil ? NSNull() : x]); msg = nil }
                        catch { msg = error.localizedDescription }
                        Haptics.tap()
                    }
                } label: {
                    Text("\(Int(x))x").font(Typeface.bold(13)).foregroundStyle(on ? Palette.ink : Palette.text)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.gold : Palette.card2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed \(Int(x)) times")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: Binding(get: { scrub ?? sim.progress }, set: { scrub = $0 }), in: 0...1) { editing in
                guard !editing, let v = scrub else { return }
                Task {
                    do { try await API.shared.demo("control", ["action": "jump", "value": v]) } catch { msg = error.localizedDescription }
                    scrub = nil
                }
            }
            .tint(Palette.gold)
            .accessibilityLabel("Position along the route")
            .accessibilityValue("\(Int((scrub ?? sim.progress) * 100)) percent")
            Text("\(formatMeters(Int((scrub ?? sim.progress) * sim.lengthM))) of \(formatMeters(Int(sim.lengthM)))\(sim.paused ? " · paused" : "")\(sim.arriving ? " · heading home" : "")")
                .font(Typeface.body(12)).foregroundStyle(Palette.muted).monospacedDigit()
        }
        tool(sim.arriving ? "Walking home..." : "Arrive", "house.fill", "arrive") {
            try await API.shared.demo("control", ["action": "arrive"])
        }
        .disabled(sim.arriving)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Test tools", sub: "Try every feature from this phone. The demo walker moves at 2x; you still do all the petting.")
            if let sim = walk.sim { walkerControls(sim) }
            Text("Pace (Gemini decides)").font(Typeface.semi(13)).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                tool("Run", "figure.run", "pace-run") { try await API.shared.demo("pace", ["mode": "run"]) }
                tool("Stop & go", "pause.fill", "pace-stopgo") { try await API.shared.demo("pace", ["mode": "stop_go"]) }
            }
            HStack(spacing: 8) {
                tool("Turn back", "arrow.uturn.backward", "pace-back") { try await API.shared.demo("pace", ["mode": "backtrack"]) }
                tool("Car speed", "car.fill", "pace-car") { try await API.shared.demo("pace", ["mode": "car"]) }
            }
            Text("Check-ins and alerts").font(Typeface.semi(13)).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                tool("Check in now", "questionmark.bubble.fill", "ci") { try await API.shared.demo("checkin") }
                tool("Stop answering", "hand.raised.slash.fill", "stop") { try await API.shared.demo("stop-answering") }
            }
            HStack(spacing: 8) {
                tool("Go off route", "arrow.triangle.branch", "dev") { try await API.shared.demo("deviate") }
                Button(action: flagHere) { label("Flag this spot", "flag.fill") }.buttonStyle(.plain)
            }
            if let msg { Text(msg).font(Typeface.body(12)).foregroundStyle(Palette.muted) }
            Text("To see what friends get: Settings > Switch role > Friend. Alerts wait there for you.")
                .font(Typeface.body(11.5)).foregroundStyle(Palette.muted)
        }
        .accessibilityIdentifier("test-tools")
    }

    private func tool(_ title: String, _ icon: String, _ key: String, _ run: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                busy = key
                do { try await run(); msg = "\(title): sent." } catch { msg = error.localizedDescription }
                busy = nil
                Haptics.tap()
            }
        } label: { label(title, icon, busy == key) }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func label(_ title: String, _ icon: String, _ spinning: Bool = false) -> some View {
        HStack(spacing: 6) {
            if spinning { ProgressView().scaleEffect(0.7).tint(Palette.gold) } else { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
            Text(title).font(Typeface.bold(13)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card2))
    }
}

let END_REASONS: [(key: String, label: String, icon: String)] = [
    ("ride", "Got a ride", "car.fill"), ("plans", "Changed plans", "arrow.triangle.2.circlepath"),
    ("friends", "With friends now", "person.3.fill"), ("safe", "Somewhere safe", "house.fill"),
    ("help", "I need help", "exclamationmark.triangle.fill"),
]

/// End a walk before arriving: pick why, the circle is told, "I need help" alerts them at once.
struct EndEarlyCard: View {
    let walk: Walk
    let route: RouteInfo?
    let circle: [String]
    let busy: Bool
    let onEnd: (String) -> Void
    let onCancel: () -> Void
    @State private var reason = "ride"

    var body: some View {
        let who = circle.isEmpty ? "your circle" : circle.joined(separator: " and ")
        let left = route.map { routeProgress($0.points, walk.pos).1 }
        VStack(alignment: .leading, spacing: 12) {
            Text("End walk early?").font(Typeface.display(24)).foregroundStyle(Palette.text)
            Text(left.map { "You're \(formatMeters($0)) from \(route?.to ?? "home"). Why are you stopping?" } ?? "Why are you stopping?")
                .font(Typeface.body(14)).foregroundStyle(Palette.muted)
            VStack(spacing: 8) {
                ForEach(END_REASONS, id: \.key) { r in
                    let on = reason == r.key
                    let tint = r.key == "help" ? Palette.alert : Palette.gold
                    Button { reason = r.key } label: {
                        HStack(spacing: 10) {
                            Image(systemName: r.icon).font(.system(size: 14, weight: .bold)).frame(width: 22)
                            Text(r.label).font(Typeface.semi(15))
                            Spacer()
                            if on { Image(systemName: "checkmark.circle.fill") }
                        }
                        .foregroundStyle(on ? tint : Palette.text)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 14).fill(on ? tint.opacity(0.14) : Palette.card2))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? tint : Palette.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(r.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(reason == "help" ? "Ends the walk and alerts \(who) right away with your location."
                                  : "\(who) will see that you ended early and why. Your streak stays as it is.")
                .font(Typeface.body(12.5)).foregroundStyle(reason == "help" ? Palette.alert : Palette.muted)
            HStack(spacing: 10) {
                GameButton(title: "Keep walking", kind: .ghost, action: onCancel)
                GameButton(title: reason == "help" ? "End and alert" : "End walk", kind: reason == "help" ? .danger : .gold, busy: busy) { onEnd(reason) }
                    .disabled(busy)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card2))
        .accessibilityIdentifier("end-early-card")
    }
}
