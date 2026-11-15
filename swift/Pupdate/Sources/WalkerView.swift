import CoreLocation
import SwiftUI

struct WalkerView: View {
    let onExit: () -> Void
    @StateObject private var store = WalkerStore()
    /// Home's panels (Plan, Settings, ...) live here, not in HomeView: starting a walk from the Plan screen
    /// swaps Home for the walk screen underneath the open panel, and the panel then slides down onto it.
    /// When the presenter lived in HomeView, the swap tore the panel down mid-presentation.
    @State private var panel: ScreenPanel?

    var body: some View {
        Group {
            if store.walk != nil {
                WalkScreen(store: store, onExit: onExit).transition(.opacity)
            } else {
                HomeView(store: store, panel: $panel, onExit: onExit).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: store.walk?.id)
        .fullScreenCover(item: $panel) { p in
            Group {
                switch p {
                case .settings: SettingsView(onClose: { panel = nil; Task { await store.loadCircle() } })
                case .customize:
                    CustomizeView { saved in
                        panel = nil
                        if saved != nil { Task { await store.refresh() } }
                    }
                case .plan(let preset):
                    PlanView(store: store, onClose: { panel = nil }, preset: preset)
                case .flags:
                    FlagsView(me: "jordan", onClose: { panel = nil })
                case .trips:
                    TripsView(me: store.me, onClose: { panel = nil })
                }
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: store.walk) { _, w in
            LiveActivityManager.shared.sync(walk: w, route: store.routes.first { $0.id == w?.routeId }, happy: store.happy)
        }
        .onChange(of: store.happy) { _, h in   // the Lock Screen pet smiles when you pet it, then goes back
            let w = store.walk
            LiveActivityManager.shared.sync(walk: w, route: store.routes.first { $0.id == w?.routeId }, happy: h)
        }
    }
}

struct WalkScreen: View {
    @ObservedObject var store: WalkerStore
    let onExit: () -> Void
    @StateObject private var flagStore = FlagStore(me: "jordan")
    @State private var newFlagAt: CLLocationCoordinate2D?
    @State private var endingEarly = false
    /// The walk as last seen. When a walk ends this screen fades out while store.walk is already nil;
    /// rendering from the last walk keeps it intact during the fade instead of collapsing to "Hi Jordan".
    @State private var lastWalk: Walk?

    var body: some View {
        let walk = store.walk ?? lastWalk
        let state = walk?.engine.state ?? "calm"
        let buddy = walk?.buddy ?? store.user?.buddy
        let copy = stateCopy(state, name: buddy?.name ?? "Melvin")
        let mood: Mood = store.happy ? .happy : (walk == nil ? .calm : copy.mood)
        let urgent = ["final", "countdown", "alert"].contains(state)
        let route = store.routes.first { $0.id == walk?.routeId }
        let secs: Int? = {
            guard let w = walk, state != "calm", state != "alert", let left = w.engine.secondsLeft else { return nil }
            return Int((left / max(w.speed, 1)).rounded(.up))
        }()
        let streak = walk?.streak ?? store.user?.streak ?? 0

        ZStack {
            Sky()
            if urgent {
                Palette.alert.opacity(0.12).ignoresSafeArea().transition(.opacity)
            }
            ScrollView {
                VStack(spacing: 18) {
                    TopBar(onBack: onExit) {
                        HStack(spacing: 8) {
                            StatChip(sprite: .fire, value: "\(streak)")
                            StatChip(sprite: .gem, value: "\(buddy?.xp ?? 0)", tint: Palette.gold)
                            if let b = buddy { StatChip(sprite: .star, value: "Lv \(level(b.xp))") }
                        }
                    }
                    if store.error != nil && walk == nil {
                        Banner(text: "Can't reach the server. Go back and check the address.", alert: true)
                    }
                    if let t = walk?.nextTurn, state == "calm" || state == "checkin" {
                        NextTurnCard(turn: t, buddyName: buddy?.name ?? "Melvin", species: buddy?.species, form: buddy?.form ?? "sprout")
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let f = walk?.flagAhead { FlagAheadBanner(flag: f).transition(.move(edge: .top).combined(with: .opacity)) }

                    // Speech bubble from the buddy.
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(walk.map { _ in route.map { "\($0.from) to \($0.to)" } ?? "Walking" } ?? "Ready when you are")
                                    .font(Typeface.semi(13)).foregroundStyle(Palette.muted)
                                Text(walk == nil ? "Hi Jordan" : copy.title)
                                    .font(Typeface.display(30)).foregroundStyle(urgent ? Palette.alert : Palette.text)
                                    .contentTransition(.opacity)
                                if let line = walk?.buddyLine, state != "calm" {
                                    HStack(alignment: .top, spacing: 5) {
                                        if walk?.buddyLineSource == "gemini" {
                                            Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.gold)
                                                .accessibilityHidden(true)
                                        }
                                        Text("\u{201C}\(line)\u{201D}").font(Typeface.semi(15)).foregroundStyle(Palette.text)
                                    }
                                    Text(copy.sub).font(Typeface.body(13)).foregroundStyle(Palette.muted)
                                        .contentTransition(.opacity)
                                } else {
                                    Text(walk == nil ? "Start a walk and \(buddy?.name ?? "Melvin") comes with you." : copy.sub)
                                        .font(Typeface.body(15)).foregroundStyle(Palette.muted)
                                }
                            }
                            Spacer(minLength: 0)
                            if let secs {
                                ZStack {
                                    Circle().stroke(Palette.card2, lineWidth: 7)
                                    Circle().trim(from: 0, to: min(1, Double(secs) / 15))
                                        .stroke(urgent ? Palette.alert : Palette.gold, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .animation(.linear(duration: 1), value: secs)
                                    Text("\(secs)").font(Typeface.display(26)).foregroundStyle(Palette.text).monospacedDigit()
                                        .contentTransition(.numericText(countsDown: true))
                                        .animation(.snappy, value: secs)
                                }
                                .frame(width: 70, height: 70)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card2))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(urgent ? Palette.alert.opacity(0.6) : Palette.lineTop, lineWidth: 1.5))
                        BubbleTail().fill(Palette.card2).frame(width: 26, height: 14)
                            .overlay(BubbleTail().stroke(urgent ? Palette.alert.opacity(0.6) : Palette.lineTop, lineWidth: 1.5).mask(Rectangle().padding(.top, 2)))
                            .offset(y: -1.5)
                    }

                    if let b = buddy {
                        BuddyView(form: b.form, species: b.species, mood: mood, size: 260,
                                  onPet: { Task { await store.pet() } },
                                  onDuress: { Task { await store.duress() } })
                            .padding(.top, -10)
                            .animation(.spring(response: 0.6, dampingFraction: 0.6), value: b.form)
                        XPBar(buddy: b, next: walk?.nextFormAt ?? (b.xp < 100 ? 100 : b.xp < 250 ? 250 : nil))
                    }

                    if let w = walk {
                        GameCard {
                            VStack(alignment: .leading, spacing: 12) {
                                EscalationLadder(state: state)
                                HStack(spacing: 8) {
                                    Image(systemName: "hand.tap.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.muted)
                                    Text("Pet \(w.buddy.name) by rubbing your finger across. Hold still for 2 seconds to send a silent alert.")
                                        .font(Typeface.body(12.5)).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        SafetyStatusRow(walk: w, watching: store.circle.count)
                        if let n = w.notices, !n.isEmpty { GameCard { NoticeList(notices: n) }.transition(.opacity) }
                        GameCard(padding: 0) {
                            VStack(spacing: 0) {
                                LiveMapView(route: route?.points, trail: w.trail, pos: (w.demo ? nil : store.localPos) ?? w.pos, form: w.buddy.form, species: w.buddy.species, offRoute: w.offRoute, alert: state == "alert", flags: flagStore.flags)
                                    .frame(height: 280)
                                    .overlay(alignment: .topTrailing) {
                                        Button { flagHere(w) } label: {
                                            Label("Flag spot", systemImage: "flag.fill").font(Typeface.bold(13)).foregroundStyle(.white)
                                                .padding(.horizontal, 12).padding(.vertical, 8)
                                                .background(Capsule().fill(Palette.alert.opacity(0.9)))
                                        }
                                        .padding(10)
                                        .accessibilityLabel("Flag this spot for your circle")
                                    }
                                HStack {
                                    SpriteIcon(.pin, size: 22)
                                    Text(route.map { r in
                                        let left = routeProgress(r.points, w.pos).1
                                        return left >= 1000 ? String(format: "%.1f km to home", Double(left) / 1000) : "\(left) m to home"
                                    } ?? "Live location")
                                        .font(Typeface.semi(14)).foregroundStyle(Palette.muted)
                                    Spacer()
                                    Pill(text: w.offRoute ? "Off route" : "On route", tint: w.offRoute ? Palette.warn : Palette.ok)
                                    if w.demo { Pill(text: "Demo \(Int(w.speed))x") }
                                }
                                .padding(14)
                            }
                        }
                        if let p = w.pace { GameCard { PaceCard(pace: p) } }
                        if w.demo { GameCard { TestToolsCard(walk: w) { flagHere(w) } } }
                        HStack(spacing: 10) {
                            GameButton(title: "End walk early", kind: .ghost) { endingEarly = true }
                                .disabled(store.ending)
                            GameButton(title: w.demo ? "End demo walk" : "I'm home", kind: .ghost, busy: store.ending) { Task { await store.end() } }
                                .disabled(store.ending)
                        }
                        GameCard { WalkLog(events: w.events, species: w.buddy.species) }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
                // Stage changes (calm -> check-in -> nudge ...) and Gemini's line arriving a moment later
                // add and remove cards; animate that instead of letting the page jump.
                .animation(Motion.reduced ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: state)
                .animation(Motion.reduced ? nil : .easeInOut(duration: 0.3), value: walk?.buddyLine)
                .animation(Motion.reduced ? nil : .easeInOut(duration: 0.3), value: walk?.flagAhead?.id)
            }
            if let c = newFlagAt {
                VStack {
                    Spacer()
                    NewFlagCard(coordinate: c, onSave: { reason, status, radius, note in
                        Task { await flagStore.add(c, reason: reason, status: status, radius: radius, note: note); newFlagAt = nil }
                    }, onCancel: { newFlagAt = nil })
                    .padding(16)
                }
                .background(Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { newFlagAt = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if endingEarly, let w = walk {
                VStack {
                    Spacer()
                    EndEarlyCard(walk: w, route: route, circle: store.circle.map(\.name), busy: store.ending,
                                 onEnd: { reason in Task { await store.end(early: reason); endingEarly = false } },
                                 onCancel: { endingEarly = false })
                        .padding(16)
                }
                .background(Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { endingEarly = false })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let evo = store.evolvedTo, let b = buddy {
                EvolutionOverlay(name: b.name, form: evo, species: b.species) { withAnimation { store.evolvedTo = nil } }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: urgent)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: newFlagAt?.latitude)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: endingEarly)
        .onAppear { flagStore.start(); if let w = store.walk { lastWalk = w } }
        .onDisappear { flagStore.stop() }
        .onChange(of: store.walk) { _, w in if let w { lastWalk = w } }
    }

    private func flagHere(_ w: Walk) {
        guard let p = w.pos, p.count == 2 else { return }
        Haptics.tap()
        newFlagAt = CLLocationCoordinate2D(latitude: p[0], longitude: p[1])
    }
}

struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.midX - 2, y: r.minY + 4))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX + 2, y: r.minY + 4))
        return p
    }
}

/// Full-screen celebration when the buddy evolves.
struct EvolutionOverlay: View {
    let name: String
    let form: String
    var species: String? = "dog"
    let done: () -> Void
    @State private var show = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            // Light rays behind the new form.
            ForEach(0..<12) { i in
                Capsule().fill(Palette.gold.opacity(0.18)).frame(width: 18, height: 420)
                    .rotationEffect(.degrees(Double(i) * 15 + (spin ? 30 : 0)))
            }
            .animation(.linear(duration: 8).repeatForever(autoreverses: false), value: spin)
            VStack(spacing: 18) {
                Text("Evolution!").font(Typeface.display(20)).foregroundStyle(Palette.gold).textCase(nil)
                ZStack {
                    SpriteIcon(.sparkles, size: 260).opacity(show ? 0.35 : 0)
                    PetImage(species: species, form: form, mood: .happy, size: 200, animated: true)
                        .scaleEffect(show ? 1 : 0.2)
                }
                Text("\(name) became a \(formName(form, species: species))").font(Typeface.display(32)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Every walk you answer makes \(name) stronger.").font(Typeface.body(16)).foregroundStyle(Palette.muted)
                GameButton(title: "Awesome", action: done).frame(width: 220).padding(.top, 8)
            }
            .padding(24)
            .opacity(show ? 1 : 0)
        }
        .onAppear {
            Haptics.success()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { show = true }
            spin = true
        }
    }
}
