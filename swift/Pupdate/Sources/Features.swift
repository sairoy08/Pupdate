import SwiftUI

// MARK: - Escalation ladder

private let LADDER: [(key: String, name: String, secs: String)] = [
    ("checkin", "Check-in", "30s"), ("nudge", "Nudge", "30s"), ("final", "Last chance", "30s"),
    ("countdown", "Countdown", "20s"), ("alert", "Friends", "alert"),
]

/// The five steps between "Still good?" and your friends' phones, with the current one lit.
struct EscalationLadder: View {
    let state: String
    var body: some View {
        let idx = LADDER.firstIndex { $0.key == state }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("If you don't answer").font(Typeface.displayBold(16)).foregroundStyle(Palette.text)
                Spacer()
                Text(idx == nil ? "Calm" : "Step \(idx! + 1) of 5").font(Typeface.bold(13))
                    .foregroundStyle(idx == nil ? Palette.ok : (idx! >= 2 ? Palette.alert : Palette.gold))
            }
            HStack(spacing: 4) {
                ForEach(Array(LADDER.enumerated()), id: \.offset) { i, step in
                    let done = idx.map { i < $0 } ?? false
                    let now = idx == i
                    let color: Color = i >= 2 ? Palette.alert : Palette.gold
                    VStack(spacing: 6) {
                        Capsule()
                            .fill(now ? color : done ? color.opacity(0.55) : Palette.card2)
                            .frame(height: 8)
                            .overlay(Capsule().strokeBorder(now ? .white.opacity(0.5) : .clear, lineWidth: 1))
                            .shadow(color: now ? color.opacity(0.7) : .clear, radius: 6)
                        Text(step.name).font(Typeface.bold(10)).foregroundStyle(now ? Palette.text : Palette.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(step.secs).font(Typeface.body(10)).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
        }
    }
}

// MARK: - Safety status

struct SafetyStatusRow: View {
    let walk: Walk
    var watching: Int = 2
    var body: some View {
        HStack(spacing: 8) {
            status("location.fill", walk.demo ? "Demo GPS" : "Live GPS", Palette.ok)
            status("person.2.fill", "\(watching) watching", watching == 0 ? Palette.alert : Palette.sky)
            status("lock.iphone", "Lock Screen", Palette.gold)
        }
    }

    private func status(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            Text(text).font(Typeface.bold(12)).foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Trip history

/// Past walks, newest first. Silent alerts never appear here: the server leaves them out.
struct TripsView: View {
    let me: String
    let onClose: () -> Void
    @State private var trips: [TripInfo]?
    @State private var failed = false

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var body: some View {
        ZStack {
            Sky()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TopBar(onBack: onClose) { EmptyView() }
                    Text("Past walks").font(Typeface.display(32)).foregroundStyle(Palette.text)
                    if failed {
                        Banner(text: "Can't load your walks. Check the connection and try again.", alert: true)
                    } else if let trips, trips.isEmpty {
                        Text("No walks yet. Your first one will show up here.").font(Typeface.body(16)).foregroundStyle(Palette.muted)
                    } else if trips == nil {
                        ProgressView().tint(Palette.gold).frame(maxWidth: .infinity)
                    }
                    ForEach(trips ?? []) { t in
                        GameCard { row(t) }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("trip-\(t.id)")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
        }
        .task {
            do { trips = try await API.shared.trips(me) } catch { failed = true }
        }
    }

    private func row(_ t: TripInfo) -> some View {
        let ok = t.alerts == 0
        let when = Self.iso.date(from: t.startedAt)?.formatted(date: .abbreviated, time: .shortened) ?? ""
        var facts = ["\(t.minutes) min"]
        if let d = t.distanceM { facts.append(formatMeters(d)) }
        facts.append(t.checkins == 1 ? "1 check-in answered" : "\(t.checkins) check-ins answered")
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark" : "exclamationmark").font(.system(size: 13, weight: .bold))
                .foregroundStyle(ok ? Palette.ok : Palette.alert)
                .frame(width: 30, height: 30).background(Circle().fill((ok ? Palette.ok : Palette.alert).opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(t.to.map { "\(t.from ?? "Start") to \($0)" } ?? "Walk").font(Typeface.semi(16)).foregroundStyle(Palette.text)
                Text(when + (t.demo ? " · demo" : "")).font(Typeface.body(13)).foregroundStyle(Palette.muted)
                Text(facts.joined(separator: " · ")).font(Typeface.body(13)).foregroundStyle(Palette.muted)
                if let why = t.endedEarly {
                    Text("Ended early: \(why)").font(Typeface.body(13)).foregroundStyle(Palette.gold)
                }
                if !ok {
                    Text(t.alerts == 1 ? "Your circle was alerted once" : "Your circle was alerted \(t.alerts) times")
                        .font(Typeface.body(13)).foregroundStyle(Palette.alert)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Walk log

/// Everything Melvin noticed on this walk, newest first.
struct WalkLog: View {
    let events: [WalkEvent]
    var title = "Walk log"
    var species: String? = "dog"
    var body: some View {
        let rows = events.compactMap(describe).reversed().prefix(6)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: title)
            if rows.isEmpty {
                Text("Quiet so far. Melvin will note every check-in here.").font(Typeface.body(14)).foregroundStyle(Palette.muted)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: r.icon).font(.system(size: 13, weight: .bold)).foregroundStyle(r.tint)
                        .frame(width: 30, height: 30).background(Circle().fill(r.tint.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(Typeface.semi(15)).foregroundStyle(Palette.text)
                        if let sub = r.sub { Text(sub).font(Typeface.body(13)).foregroundStyle(Palette.muted) }
                    }
                    Spacer(minLength: 0)
                    Text(r.time).font(Typeface.body(12)).foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
        }
    }

    private struct Row { let icon: String; let tint: Color; let title: String; let sub: String?; let time: String }

    private func describe(_ e: WalkEvent) -> Row? {
        let t = time(e.realAt)
        switch e.type {
        case "checkin_started":
            let why: String? = switch e.reason {
            case "off_route": "You left your usual route"
            case "moving_fast": "You started moving at car speed"
            case "stopped": "You stopped for a while"
            case "stop_answering": "Demo: walker stopped answering"
            case "irregular_pace": "Your pace looked irregular"
            case "flagged_area": "You walked into a flagged spot"
            case "demo": "Demo check-in"
            default: "Scheduled check-in"
            }
            return Row(icon: "questionmark", tint: Palette.sky, title: "Melvin checked in", sub: why, time: t)
        case "pet_ok":
            if let evo = e.evolved {
                return Row(icon: "sparkles", tint: Palette.gold, title: "Evolved into \(formName(evo, species: species))", sub: "+\(e.xp ?? 0) XP for answering", time: t)
            }
            if e.afterAlert == true { return Row(icon: "hand.tap.fill", tint: Palette.warn, title: "Petted after the alert", sub: "Friends still check in", time: t) }
            if (e.xp ?? 0) > 0 { return Row(icon: "hand.tap.fill", tint: Palette.ok, title: "Answered on time", sub: "+\(e.xp!) XP", time: t) }
            if e.late == true { return Row(icon: "hand.tap.fill", tint: Palette.warn, title: "Answered late", sub: "No XP this time", time: t) }
            return nil
        case "pace_irregular":
            let p: String = switch e.pattern {
            case "running": "Started running"; case "stop_and_go": "Stop-and-go pace"; case "backtracking": "Turned back"
            case "sudden_stop": "Stopped suddenly"; case "vehicle": "Moving at car speed"; default: "Pace changed"
            }
            return Row(icon: e.pattern == "vehicle" ? "car.fill" : "figure.run", tint: Palette.warn, title: p, sub: "Pace watch noticed", time: t)
        case "pace_judged":
            return Row(icon: "sparkles", tint: Palette.gold, title: e.checkIn == true ? "Gemini: worth a check-in" : "Gemini: looks normal",
                       sub: e.why?.isEmpty == false ? e.why : (e.source == "gemini" ? nil : "Gemini didn't answer, checked in to be safe"), time: t)
        case "flag_entered":
            return Row(icon: "nosign", tint: Palette.alert, title: "Entered a flagged spot", sub: e.flag.map { "\($0.byName): \($0.reason)" }, time: t)
        case "flag_nearby":
            return Row(icon: "flag.fill", tint: Palette.warn, title: "Passed near a flag", sub: e.flag.map { "\($0.byName): \($0.reason)" }, time: t)
        case "notice":
            return Row(icon: "exclamationmark.circle.fill", tint: Palette.warn, title: "Friends notified", sub: e.text, time: t)
        case "pet_ignored":
            return Row(icon: "hand.raised.slash.fill", tint: Palette.muted, title: "Pet ignored", sub: "Demo: not answering", time: t)
        case "escalated":
            let name = LADDER.first { $0.key == e.state }?.name ?? (e.state ?? "")
            return Row(icon: "arrow.up.right", tint: Palette.alert, title: "Escalated: \(name)", sub: nil, time: t)
        case "alert_raised":
            let k: String = switch e.kind { case "duress": "Silent alert sent"; case "lost_contact": "Lost contact alert"; default: "Friends alerted" }
            return Row(icon: "bell.badge.fill", tint: Palette.alert, title: k, sub: "Your circle was notified", time: t)
        case "contact_restored":
            return Row(icon: "antenna.radiowaves.left.and.right", tint: Palette.ok, title: "Back in contact", sub: nil, time: t)
        case "arrived":
            return Row(icon: "house.fill", tint: Palette.ok, title: "Arrived home", sub: "Walk ended safely", time: t)
        default:
            return nil
        }
    }

    private func time(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Home: safety powers and circle

struct SafetyPowers: View {
    let buddyName: String
    private var items: [(Sprite, String, String)] {
        [
            (.question, "Check-ins", "\(buddyName) asks \"Still good?\" when something looks off, or on a schedule you pick. Pet it to answer and earn XP."),
            (.bell, "Escalation", "No answer? A nudge, a last chance, a countdown, then your friends get an alert. About 2 minutes."),
            (.shield, "Silent alert", "Hold \(buddyName) for 2 seconds. Your screen stays calm while friends get a quiet alert."),
            (.compass, "Route and speed", "Leaving your route, stopping a long time, or moving at car speed triggers a check-in."),
            (.exclaim, "Lost contact", "If your phone goes quiet for 90 seconds, your friends know."),
            (.pin, "Lock Screen", "Your walk, countdown and \(buddyName) live on your Lock Screen and Dynamic Island."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "\(buddyName)'s safety powers", sub: "Everything that happens on a walk.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    VStack(alignment: .leading, spacing: 8) {
                        SpriteIcon(it.0, size: 26)
                        Text(it.1).font(Typeface.displayBold(16)).foregroundStyle(Palette.text)
                        Text(it.2).font(Typeface.body(12.5)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
                }
            }
        }
    }
}

struct CircleCard: View {
    let friends: [FriendInfo]
    private let colors: [Color] = [Color(hex: 0xff8fb1), Color(hex: 0x7ad7ff), Color(hex: 0xb4f08a), Color(hex: 0xffd27a), Color(hex: 0xc9a7ff)]
    var body: some View {
        GameCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Your circle", sub: friends.isEmpty ? "Add friends in Settings so someone gets your alerts."
                                                                    : "They get your alerts. Only they can close one.")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(friends.enumerated()), id: \.element.id) { i, p in
                            HStack(spacing: 10) {
                                Text(String(p.name.prefix(1))).font(Typeface.display(18)).foregroundStyle(Palette.ink)
                                    .frame(width: 42, height: 42).background(Circle().fill(colors[i % colors.count]))
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle().fill(Palette.ok).frame(width: 12, height: 12).overlay(Circle().stroke(Palette.card, lineWidth: 2))
                                    }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(Typeface.semi(15)).foregroundStyle(Palette.text)
                                    Text("Watching").font(Typeface.body(12)).foregroundStyle(Palette.ok)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.muted)
                    Text("Your location is only shared during a walk.").font(Typeface.body(12.5)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
