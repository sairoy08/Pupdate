import SwiftUI

private func clock(_ iso: String?) -> String {
    guard let iso else { return "" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let d else { return "" }
    return d.formatted(date: .omitted, time: .shortened)
}

private let KIND: [String: (title: (String) -> String, body: (String) -> String, short: String)] = [
    "no_answer": ({ "\($0) stopped answering" }, { "\($0) didn't pet their buddy through almost two minutes of check-ins. Call them now." }, "No answer"),
    "duress": ({ "\($0) sent a silent alert" }, { _ in "Do not call first. A ringing phone could put them at risk. Text, or go to their location with someone." }, "Silent alert"),
    "lost_contact": ({ "Lost contact with \($0)" }, { "\($0)'s phone stopped checking in 90 seconds ago." }, "Lost contact"),
    "help": ({ "\($0) asked for help" }, { "\($0) ended their walk early and tapped I need help. Call them now." }, "Asked for help"),
]

struct FriendView: View {
    let onExit: () -> Void
    @StateObject private var store = FriendStore()
    @State private var routeId = "library-to-tooker"
    @State private var panel: ScreenPanel?
    @StateObject private var flagStore = FlagStore(me: "maya")

    var body: some View {
        let walk = store.feed?.walks.first
        let route = store.routes.first { $0.id == walk?.routeId }
        ZStack {
            Sky()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TopBar(onBack: onExit) {
                        HStack(spacing: 8) {
                            Button { panel = .flags } label: {
                                Image(systemName: "flag.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.alert)
                                    .frame(width: 40, height: 40).background(Circle().fill(.white.opacity(0.07)))
                            }
                            .accessibilityLabel("Flagged spots")
                            SettingsButton { panel = .settings }
                            StatChip(sprite: .shield, value: "Guardian")
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hi Maya").font(Typeface.display(34)).foregroundStyle(Palette.text)
                        Text("You'll hear from \(walk?.buddy.name ?? "Melvin") if Jordan stops answering.").font(Typeface.body(16)).foregroundStyle(Palette.muted)
                    }
                    if let err = store.error, store.feed == nil { Banner(text: "Can't reach the server: \(err)", alert: true) }

                    GameCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "Walking now")
                            if let w = walk {
                                HStack(spacing: 12) {
                                    BuddyView(form: w.buddy.form, species: w.buddy.species, mood: STATE_COPY[w.engine.state]?.mood ?? .calm, size: 76, pedestal: false)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(w.walkerName).font(Typeface.display(24)).foregroundStyle(Palette.text)
                                        Text(route.map { "To \($0.to)" } ?? "Walking").font(Typeface.body(14)).foregroundStyle(Palette.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    Pill(text: friendState(w.engine.state, w.walkerName), tint: tone(w.engine.state)).fixedSize()
                                }
                                LiveMapView(route: route?.points, trail: w.trail, pos: w.pos, form: w.buddy.form, species: w.buddy.species, offRoute: w.offRoute, alert: w.engine.state == "alert", flags: flagStore.flags, interval: 1.5)
                                    .frame(height: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                EscalationLadder(state: w.engine.state)
                                if let n = w.notices, !n.isEmpty { NoticeList(notices: n, friendView: true) }
                                if let p = w.pace {
                                    let (label, icon, tint) = paceModeText(p.mode)
                                    HStack(spacing: 8) {
                                        Image(systemName: icon).foregroundStyle(tint)
                                        Text(label + (p.kmh.map { String(format: " · %.0f km/h", $0) } ?? "")).font(Typeface.semi(14)).foregroundStyle(Palette.text)
                                        Spacer()
                                        if let t = w.nextTurn { Text("Next: \(t.text)").font(Typeface.body(12)).foregroundStyle(Palette.muted).lineLimit(1) }
                                    }
                                    if let note = p.note, p.pattern != "steady" {
                                        Text(note).font(Typeface.body(13)).foregroundStyle(Palette.muted)
                                    }
                                }
                            } else {
                                HStack(spacing: 12) {
                                    SpriteIcon(.house, size: 40)
                                    Text("Nobody is walking right now.").font(Typeface.body(15)).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }

                    if let ups = store.feed?.updates, !ups.isEmpty {
                        GameCard {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(text: "Updates")
                                ForEach(Array(ups.prefix(4).enumerated()), id: \.offset) { _, u in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: u.reason == "help" ? "exclamationmark.triangle.fill" : "flag.checkered")
                                            .font(.system(size: 14, weight: .bold)).foregroundStyle(u.reason == "help" ? Palette.alert : Palette.sky)
                                            .frame(width: 28, height: 28).background(Circle().fill((u.reason == "help" ? Palette.alert : Palette.sky).opacity(0.15)))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(u.text).font(Typeface.body(14)).foregroundStyle(Palette.text)
                                            Text(clock(u.at)).font(Typeface.body(12)).foregroundStyle(Palette.muted)
                                        }
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("friend-updates")
                    }
                    if let w = walk {
                        GameCard { WalkLog(events: w.events, title: "\(w.walkerName)'s walk log", species: w.buddy.species) }
                    }

                    GameCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(text: "Demo controls", sub: "The sim walks at 2x and escalates at 4x. It never pets Melvin: every pet comes from Jordan's phone.")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(store.routes) { r in
                                        let on = r.id == routeId
                                        Button { routeId = r.id } label: {
                                            Text(r.name).font(Typeface.semi(13))
                                                .foregroundStyle(on ? Palette.gold : Palette.muted)
                                                .padding(.horizontal, 13).padding(.vertical, 8)
                                                .background(Capsule().fill(on ? Palette.gold.opacity(0.14) : .clear))
                                                .overlay(Capsule().strokeBorder(on ? Palette.gold : Palette.line))
                                        }
                                    }
                                }
                            }
                            HStack(spacing: 10) {
                                GameButton(title: "Reset", kind: .ghost, busy: store.busy == "reset") { Task { await store.act("reset") { try await API.shared.demo("reset") } } }
                                GameButton(title: "Start walk", busy: store.busy == "start") { Task { await store.act("start") { try await API.shared.demo("start", ["route_id": routeId]) } } }
                            }
                            HStack(spacing: 10) {
                                GameButton(title: "Check in", kind: .ghost, busy: store.busy == "ci") { Task { await store.act("ci") { try await API.shared.demo("checkin") } } }
                                    .disabled(walk == nil)
                                GameButton(title: "Stop answering", kind: .danger, busy: store.busy == "stop") { Task { await store.act("stop") { try await API.shared.demo("stop-answering") } } }
                                    .disabled(walk == nil)
                            }
                            GameButton(title: "End walk", kind: .ghost, busy: store.busy == "end") {
                                Task { await store.act("end") { if let w = walk { _ = try await API.shared.end(w.id) } } }
                            }
                            .disabled(walk == nil)
                            HStack(spacing: 10) {
                                GameButton(title: "Off route", kind: .ghost, busy: store.busy == "dev") { Task { await store.act("dev") { try await API.shared.demo("deviate") } } }
                                    .disabled(walk == nil)
                                GameButton(title: walk.map { "Speed \(Int($0.speed))x" } ?? "Speed", kind: .ghost) {
                                    let x: Any = (walk?.speed ?? 2) < 4 ? 4 : NSNull()
                                    Task { await store.act("speed") { try await API.shared.demo("speed", ["x": x]) } }
                                }
                                .disabled(walk == nil)
                            }
                            HStack(spacing: 10) {
                                GameButton(title: "Run", kind: .ghost, busy: store.busy == "run") { Task { await store.act("run") { try await API.shared.demo("pace", ["mode": "run"]) } } }
                                    .disabled(walk == nil)
                                GameButton(title: "Car speed", kind: .ghost, busy: store.busy == "car") { Task { await store.act("car") { try await API.shared.demo("pace", ["mode": "car"]) } } }
                                    .disabled(walk == nil)
                            }
                            if let err = store.error, store.feed != nil { Banner(text: err, alert: true) }
                        }
                    }

                    if let recent = store.feed?.recentAlerts, !recent.isEmpty {
                        GameCard {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(text: "Recent alerts")
                                ForEach(recent.prefix(5)) { a in
                                    HStack {
                                        SpriteIcon(.bell, size: 22)
                                        Text(KIND[a.kind]?.short ?? a.kind).font(Typeface.semi(15)).foregroundStyle(Palette.text)
                                        Text(clock(a.openedAt)).font(Typeface.body(14)).foregroundStyle(Palette.muted)
                                        Spacer()
                                        Pill(text: a.status == "closed" ? "Closed by \(a.closedBy?.capitalized ?? "")" : "Open",
                                             tint: a.status == "closed" ? Palette.muted : Palette.alert)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
            if let a = store.alert {
                TakeoverView(alert: a, alertSpecies: store.feed?.walks.first?.buddy.species, closing: store.busy == "close") { Task { await store.close(a) } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: store.alert?.id)
        // The takeover sits under any open panel, so an alert closes Settings or Flags to be seen.
        .onChange(of: store.alert?.id) { _, id in if id != nil, panel != nil { panel = nil } }
        .onAppear {
            store.start()
            #if targetEnvironment(simulator)
            // Simulator-only: -panel settings|flags opens that screen (screenshots).
            if let i = CommandLine.arguments.firstIndex(of: "-panel"), i + 1 < CommandLine.arguments.count {
                panel = CommandLine.arguments[i + 1] == "flags" ? .flags : CommandLine.arguments[i + 1] == "settings" ? .settings : nil
            }
            #endif
        }
        .onDisappear { store.stop() }
        .fullScreenCover(item: $panel) { p in
            if p == .flags { FlagsView(me: "maya", onClose: { panel = nil }) } else { SettingsView(onClose: { panel = nil }) }
        }
        .onAppear { flagStore.start() }
        .onDisappear { flagStore.stop() }
    }

    private func friendState(_ s: String, _ name: String) -> String {
        let first = name.components(separatedBy: " ").first ?? name
        switch s {
        case "calm": return "All good"
        case "checkin": return "Checking in"
        case "nudge", "final": return "No answer yet"
        case "countdown": return "Alerting soon"
        case "alert": return "Alert sent"
        default: return s
        }
    }

    private func tone(_ s: String) -> Color { s == "calm" ? Palette.ok : (s == "alert" || s == "countdown") ? Palette.alert : Palette.warn }
}

struct TakeoverView: View {
    let alert: AlertInfo
    var alertSpecies: String? = "dog"
    let closing: Bool
    let onClose: () -> Void
    @State private var pulse = false

    var body: some View {
        let k = KIND[alert.kind] ?? KIND["no_answer"]!
        let first = alert.walkerName.components(separatedBy: " ").first ?? alert.walkerName
        let duress = alert.kind == "duress"
        let base = duress ? Color(hex: 0x1d0b2e) : Color(hex: 0x2c0a14)
        let soft = duress ? Color(hex: 0xe7c9ff) : Color(hex: 0xffd4da)
        ZStack {
            base.ignoresSafeArea()
            RadialGradient(colors: [(duress ? Color.purple : Palette.alert).opacity(pulse ? 0.45 : 0.2), .clear], center: .top, startRadius: 10, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: duress ? 2 : 0.7).repeatForever(autoreverses: true), value: pulse)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Pill(text: k.short, tint: duress ? Color(hex: 0xd7a6ff) : Palette.alert)
                        Spacer()
                        Text(clock(alert.openedAt)).font(Typeface.semi(14)).foregroundStyle(soft)
                    }
                    HStack {
                        Spacer()
                        // The duress screen stays calmer on purpose: it may be read over a shoulder.
                        BuddyView(form: "strider", species: alertSpecies, mood: duress ? .worried : .alarmed, size: 170, pedestal: !duress)
                        Spacer()
                    }
                    Text(k.title(first)).font(Typeface.display(36)).foregroundStyle(.white)
                    Text(alert.summary ?? k.body(first)).font(Typeface.body(17)).foregroundStyle(soft).lineSpacing(3)
                    if alert.summarySource == "gemini" {
                        Label("Brief written by Gemini from the walk data", systemImage: "sparkles")
                            .font(Typeface.body(12)).foregroundStyle(soft.opacity(0.8))
                    }
                    if let t = alert.pettedAfter {
                        Banner(text: "\(first) petted their buddy at \(clock(t)), after the alert. Still check on them.")
                    }
                    if let t = alert.contactRestored { Banner(text: "\(first)'s phone reconnected at \(clock(t)).") }
                    if let p = alert.pos, p.count == 2 {
                        Link(destination: URL(string: "https://maps.apple.com/?q=\(p[0]),\(p[1])")!) {
                            HStack(spacing: 12) {
                                Image(systemName: "location.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Last known location").font(Typeface.bold(16)).foregroundStyle(.white)
                                    Text(String(format: "%.5f, %.5f", p[0], p[1])).font(Typeface.body(14)).foregroundStyle(soft).monospacedDigit()
                                }
                                Spacer()
                                Text("Open in Maps").font(Typeface.semi(14)).foregroundStyle(.white)
                            }
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.07)))
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
            // The actions are pinned to the bottom so they are always on screen.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if !duress, let url = URL(string: "tel:\(alert.walkerPhone)") {
                        GameButton(title: "Call \(first)", kind: .ok) { UIApplication.shared.open(url) }
                    }
                    GameButton(title: "I've reached \(first), close alert", kind: .ghost, busy: closing, action: onClose)
                }
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 6)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [base.opacity(0), base, base], startPoint: .top, endPoint: .bottom))
            }
        }
        .onAppear { pulse = true }
    }
}
