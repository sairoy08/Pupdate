import AudioToolbox
import CoreLocation
import Foundation
import SwiftUI

/// Polls the walker's active walk once a second.
@MainActor
final class WalkerStore: ObservableObject {
    let me = "jordan"
    @Published var walk: Walk?
    @Published var user: UserInfo?
    @Published var routes: [RouteInfo] = []
    @Published var error: String?
    @Published var evolvedTo: String?
    @Published var happy = false
    @Published var circle: [FriendInfo] = []
    /// Real walks: this phone's own latest GPS fix, so the walker's dot moves the moment they do.
    @Published var localPos: [Double]?
    @Published var ending = false
    private var loop: Task<Void, Never>?
    private var lastState: String?
    private var spokenTurn: String?
    private var announcedTurn: String?
    private var warnedFlags = Set<String>()
    private let location = LocationTicker()

    func start() {
        guard loop == nil else { return }
        Notify.ask()
        loop = Task { [weak self] in
            if let r = try? await API.shared.routes() { self?.routes = r }
            await self?.loadCircle()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    init() {
        location.onFix = { [weak self] l in
            guard l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 50 else { return }
            Task { @MainActor in self?.localPos = [l.coordinate.latitude, l.coordinate.longitude] }
        }
    }

    func stop() { loop?.cancel(); loop = nil; location.stop() }

    func refresh() async {
        do {
            let w = try await API.shared.active(me)
            if w == nil {
                let u = try await API.shared.user(me)
                if u != user { user = u }
            }
            apply(w)
            if error != nil { error = nil }
        } catch {
            let msg = error.localizedDescription
            if self.error != msg { self.error = msg }
        }
    }

    private func apply(_ w: Walk?) {
        // A route planned on a phone appears after launch: fetch routes again when one is unknown.
        if let rid = w?.routeId, !routes.contains(where: { $0.id == rid }) {
            Task { if let r = try? await API.shared.routes() { self.routes = r } }
        }
        let st = w?.engine.state
        if let st, st != lastState, st != "calm" {
            Feedback.checkInChime()
            // Neutral wording: a bystander who sees the Lock Screen learns nothing about safety or alerts.
            Notify.post("wb.checkin", title: "\(w?.buddy.name ?? "Melvin") wants a pet")
            if st == "checkin" || st == "countdown" {
                let name = w?.buddy.name ?? "Melvin"
                Feedback.speak(w?.buddyLine ?? stateCopy(st, name: name).title + " " + stateCopy(st, name: name).sub)
            }
        }
        if st == "calm" || st == nil, lastState != st { Notify.clear("wb.checkin") }
        lastState = st
        announce(w)
        if w != walk { walk = w }
        // Every active walk (demo too) runs location so the app stays alive with the screen locked
        // and keeps the Live Activity current. Only real walks send GPS fixes to the server.
        if let w, w.status == "active" { location.start(walkId: w.id, sendFixes: !w.demo) } else { location.stop(); localPos = nil }
        if w?.demo == true, localPos != nil { localPos = nil }
    }

    /// Turn-by-turn and flag heads-ups: spoken (if on), with a tap of haptics.
    private func announce(_ w: Walk?) {
        guard let w, w.status == "active" else { spokenTurn = nil; announcedTurn = nil; warnedFlags = []; return }
        if let t = w.nextTurn {
            let key = "\(w.id)-\(t.index)"
            if announcedTurn != key && !t.near && t.inM <= 150 && t.inM >= 40 {
                announcedTurn = key
                Feedback.speak("In \(formatMeters(t.inM)), \(t.text)")
            }
            if t.near && spokenTurn != key && (w.engine.state == "calm") {
                spokenTurn = key
                announcedTurn = key
                Haptics.tap()
                Feedback.speak(t.text)
            }
        }
        if let f = w.flagAhead, !warnedFlags.contains(f.id) {
            warnedFlags.insert(f.id)
            Haptics.warning()
            Feedback.speak("Heads up. \(f.byName) flagged \(f.reason.lowercased()) \(f.inside == true ? "here" : "ahead").")
        }
    }

    func loadCircle() async {
        if let c = try? await API.shared.circle(me), c != circle { circle = c }
    }

    func pet() async {
        Haptics.tap()
        guard let w = walk else { Feedback.petted(); beHappy(); return }
        do {
            let r = try await API.shared.pet(w.id)
            apply(r.walk)
            if r.events.contains(where: { $0.type == "pet_ok" }) { Feedback.petted(); beHappy() }
            if let evo = r.events.first(where: { $0.evolved != nil })?.evolved {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { evolvedTo = evo }
            }
        } catch { self.error = error.localizedDescription }
    }

    func duress() async {
        guard let w = walk else { return }
        // Silent: the screen must not change in any visible way.
        if let r = try? await API.shared.duress(w.id) { walk = r.walk }
    }

    func startPlanned(points: [[Double]], from: String, to: String, demo: Bool, steps: [[String: Any]] = []) async {
        guard points.count > 1 else { return }
        do {
            let w = try await API.shared.startPlanned(me, points: points, from: from, to: to, demo: demo, steps: steps)
            routes = (try? await API.shared.routes()) ?? routes
            apply(w)
        } catch { self.error = error.localizedDescription }
    }

    func startReal(_ route: String) async {
        if let w = try? await API.shared.startWalk(me, route: route) { apply(w) }
    }

    func end(early reason: String? = nil) async {
        guard let w = walk, !ending else { return }  // one end at a time, however many taps
        ending = true
        defer { ending = false }
        do {
            let v: Walk
            if let reason { v = try await API.shared.endEarly(w.id, reason: reason) } else { v = try await API.shared.end(w.id) }
            apply(v.status == "active" ? v : nil)
        } catch APIError.http(404, _) {
            apply(nil)  // the server already forgot this walk (e.g. a demo reset): just leave it
        } catch {
            self.error = error.localizedDescription
        }
        if let u = try? await API.shared.user(me) { user = u }
    }

    private var happyToken = 0

    private func beHappy() {
        happyToken += 1
        let token = happyToken
        happy = true
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if token == happyToken { happy = false }   // a second pet keeps it happy longer
        }
    }
}

/// Polls the friend's feed every 1.5 s and drives the alert takeover.
@MainActor
final class FriendStore: ObservableObject {
    let me = "maya"
    @Published var feed: Feed?
    @Published var routes: [RouteInfo] = []
    @Published var error: String?
    @Published var busy: String?
    private var loop: Task<Void, Never>?
    private var buzz: Task<Void, Never>?

    var alert: AlertInfo? { feed?.openAlerts.first }

    func start() {
        guard loop == nil else { return }
        Notify.ask()
        loop = Task { [weak self] in
            if let r = try? await API.shared.routes() { self?.routes = r }
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil; buzz?.cancel(); buzz = nil }

    func refresh() async {
        do {
            let f = try await API.shared.feed(me)
            if let rid = f.walks.first?.routeId, !routes.contains(where: { $0.id == rid }) {
                routes = (try? await API.shared.routes()) ?? routes
            }
            let hadAlert = alert != nil
            let oldNotices = Set((feed?.walks ?? []).flatMap { $0.notices ?? [] }.map(\.text))
            let fresh = f.walks.flatMap { $0.notices ?? [] }.filter { !oldNotices.contains($0.text) }
            if feed != nil, let n = fresh.first {
                Haptics.warning()
                Feedback.speak(n.text)
                Notify.post("wb.notice", title: n.text)
            }
            let oldUpdates = Set((feed?.updates ?? []).map(\.text))
            if feed != nil, let u = (f.updates ?? []).first(where: { !oldUpdates.contains($0.text) }) {
                Haptics.warning()
                Feedback.speak(u.text)
                Notify.post("wb.notice", title: u.text)
            }
            if f != feed { feed = f }
            if error != nil { error = nil }
            if let a = alert, !hadAlert {
                startBuzz()
                Feedback.alertSound()
                Feedback.speak(a.summary ?? "Pupdate alert for \(a.walkerName).")
                Notify.post("wb.alert", title: "Pupdate alert for \(a.walkerName)", body: a.summary ?? "Open Pupdate to see where they are.")
            }
            if alert == nil { buzz?.cancel(); buzz = nil; if hadAlert { Notify.clear("wb.alert") } }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startBuzz() {
        buzz?.cancel()
        buzz = Task {
            while !Task.isCancelled {
                if Feedback.strongVibration { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) } else { Haptics.warning() }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            }
        }
    }

    func act(_ key: String, _ fn: @escaping () async throws -> Void) async {
        busy = key
        do { try await fn(); error = nil } catch { self.error = error.localizedDescription }
        busy = nil
        await refresh()
    }

    func close(_ a: AlertInfo) async {
        await act("close") { _ = try await API.shared.closeAlert(a.id, friend: self.me) }
        Haptics.success()
    }
}

/// Real (non-demo) walks: GPS fixes plus a 20 s heartbeat even without a fix.
final class LocationTicker: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var walkId: String?
    private var sendFixes = true
    private var heartbeat: Timer?
    var onFix: ((CLLocation) -> Void)?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        mgr.distanceFilter = 5
        mgr.pausesLocationUpdatesAutomatically = false
        mgr.activityType = .fitness
    }

    func start(walkId id: String, sendFixes: Bool) {
        guard walkId != id else { return }
        walkId = id
        self.sendFixes = sendFixes
        mgr.requestWhenInUseAuthorization()
        mgr.allowsBackgroundLocationUpdates = true
        mgr.showsBackgroundLocationIndicator = true
        mgr.startUpdatingLocation()
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.sendFixes, let id = self.walkId else { return }
            Task { try? await API.shared.tick(id) }
        }
    }

    func stop() {
        walkId = nil
        mgr.stopUpdatingLocation()
        heartbeat?.invalidate()
        heartbeat = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard sendFixes, let id = walkId, let l = locations.last else { return }
        onFix?(l)
        Task { try? await API.shared.tick(id, lat: l.coordinate.latitude, lng: l.coordinate.longitude, accuracy: l.horizontalAccuracy) }
    }
}
