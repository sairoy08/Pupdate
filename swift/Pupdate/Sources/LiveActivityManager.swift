import ActivityKit
import CoreLocation
import Foundation

/// Mirrors the active walk onto a Live Activity (Lock Screen + Dynamic Island).
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<WalkActivityAttributes>?
    private var walkId: String?
    private var last: WalkActivityAttributes.ContentState?

    func sync(walk: Walk?, route: RouteInfo?, happy: Bool = false) {
        let enabled = UserDefaults.standard.object(forKey: "wb.liveActivity") as? Bool ?? true
        guard enabled, let w = walk, w.status == "active" else { end(); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = makeState(w, route, happy: happy)
        if activity == nil || walkId != w.id {
            end()
            let attrs = WalkActivityAttributes(walkId: w.id, walkerName: w.walkerName, buddyName: w.buddy.name,
                                               from: route?.from ?? "Here", to: route?.to ?? "home")
            do {
                activity = try Activity.request(attributes: attrs, content: .init(state: content, staleDate: nil))
                walkId = w.id
                last = content
            } catch {
                print("Live Activity request failed: \(error)")
            }
            return
        }
        guard changed(content) else { return }
        // Compare with the previous state before overwriting it, so urgent changes really play a sound.
        let alerting = WalkStateStyle.isUrgent(content.state) && content.state != last?.state
        last = content
        Task {
            await activity?.update(.init(state: content, staleDate: nil),
                                   alertConfiguration: alerting ? AlertConfiguration(title: "\(content.title)", body: "\(content.subtitle)", sound: .default) : nil)
        }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        walkId = nil
        last = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    private func changed(_ c: WalkActivityAttributes.ContentState) -> Bool {
        guard let l = last else { return true }
        if l.state != c.state || l.form != c.form || l.xp != c.xp || l.happy != c.happy { return true }
        if abs(l.progress - c.progress) > 0.01 { return true }
        if l.turnText != c.turnText { return true }
        if let a = l.turnMeters, let b = c.turnMeters, abs(a - b) >= 10 { return true }
        if let a = l.deadline, let b = c.deadline, abs(a.timeIntervalSince(b)) > 2 { return true }
        return (l.deadline == nil) != (c.deadline == nil)
    }

    private func makeState(_ w: Walk, _ route: RouteInfo?, happy: Bool) -> WalkActivityAttributes.ContentState {
        let st = w.engine.state
        let copy = stateCopy(st, name: w.buddy.name)
        var deadline: Date?
        if let left = w.engine.secondsLeft, st != "calm", st != "alert" {
            deadline = Date().addingTimeInterval(left / max(w.speed, 1))
        }
        let (progress, left) = routeProgress(route?.points, w.pos)
        let petted = happy && st != "alert"   // a late pet never looks like "all good"
        return .init(state: st, title: petted ? "Good \(w.buddy.name)!" : copy.title,
                     subtitle: petted ? "Thanks for checking in." : copy.sub, deadline: petted ? nil : deadline, form: w.buddy.form,
                     species: w.buddy.species ?? "dog",
                     xp: w.buddy.xp, progress: progress, metersLeft: left,
                     turnText: w.nextTurn?.text, turnSymbol: w.nextTurn.map { turnSymbol($0.maneuver) }, turnMeters: w.nextTurn?.inM, happy: petted)
    }
}

/// Fraction of the route walked and meters left, by snapping the position to the nearest route vertex segment.
func routeProgress(_ pts: [[Double]]?, _ pos: [Double]?) -> (Double, Int) {
    guard let pts, pts.count > 1, let pos, pos.count == 2 else { return (0, 0) }
    let loc = { (p: [Double]) in CLLocation(latitude: p[0], longitude: p[1]) }
    var cum = [0.0]
    for i in 1..<pts.count { cum.append(cum[i - 1] + loc(pts[i - 1]).distance(from: loc(pts[i]))) }
    let total = cum.last ?? 1
    let here = loc(pos)
    var best = (d: Double.infinity, along: 0.0)
    for i in 0..<(pts.count - 1) {
        let a = loc(pts[i]), b = loc(pts[i + 1])
        let seg = a.distance(from: b)
        let t = seg > 0 ? max(0, min(1, (here.distance(from: a) - here.distance(from: b) + seg) / (2 * seg))) : 0
        let along = cum[i] + t * seg
        let pt = [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t]
        let d = here.distance(from: loc(pt))
        if d < best.d { best = (d, along) }
    }
    return (max(0, min(1, best.along / max(total, 1))), Int(max(0, total - best.along)))
}
