import MapKit
import SwiftUI

/// Real Apple Map: route, walked trail, flags, the walker's live marker (carrying the buddy) and home.
///
/// Smoothness: positions arrive about once a second (polling). The marker and camera glide to each new
/// point with a linear animation lasting one update interval, so motion is continuous instead of
/// lurching. Tiny GPS jitter is ignored, big jumps (a new walk) snap. Panning the map pauses follow
/// mode until you tap Recenter, and your zoom and angle are kept while following.
struct LiveMapView: View {
    var route: [[Double]]?
    var trail: [[Double]] = []
    var pos: [Double]?
    var form: String = "sprout"
    var species: String? = "dog"
    var offRoute = false
    var alert = false
    var follow = true
    var flags: [FlagInfo] = []
    /// Seconds between position updates (walker polls 1 s, friend 1.5 s, phone GPS about 1 s).
    var interval: Double = 1.0

    @State private var camera: MapCameraPosition = .automatic
    @State private var shown: CLLocationCoordinate2D?
    @State private var following = true
    @State private var lastCam: MapCamera?
    /// When the last position arrived, and the smoothed gap between arrivals. Polls take the interval
    /// plus the network round trip, so gliding for exactly `interval` left the marker parked for a beat
    /// every update (a stutter about once a second). Gliding for the measured gap keeps it moving.
    @State private var lastArrival: Date?
    @State private var gap: Double?
    @AppStorage("wb.satellite") private var satellite = true

    private func c(_ p: [Double]) -> CLLocationCoordinate2D { .init(latitude: p[0], longitude: p[1]) }

    var body: some View {
        let dot = alert ? Palette.alert : offRoute ? Palette.warn : Palette.gold
        Map(position: $camera, interactionModes: [.pan, .zoom, .rotate, .pitch]) {
            FlagMarks(flags: flags)
            if let route, route.count > 1 {
                // Dark outline under a bright line so the route reads on satellite imagery.
                MapPolyline(coordinates: route.map(c))
                    .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: route.map(c))
                    .stroke(Color(hex: 0x9db8ff), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            if trail.count > 1 {
                MapPolyline(coordinates: trail.map(c))
                    .stroke(offRoute ? Palette.warn : Palette.gold, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let last = route?.last {
                Annotation("Home", coordinate: c(last), anchor: .bottom) {
                    SpriteIcon(.house, size: 20, tint: Palette.ink).frame(width: 34, height: 34).background(Circle().fill(Palette.gold))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 3)
                }
            }
            if let s = shown {
                Annotation("", coordinate: s, anchor: .center) {
                    WalkerDot(tint: dot, form: form, species: species)
                }
            }
        }
        .mapStyle(satellite
                  ? .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: false)
                  : .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { ctx in lastCam = ctx.camera }
        // A finger on the map means the person wants to look around: stop following.
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in if following { following = false } })
        .overlay(alignment: .bottomTrailing) {
            if !following && follow {
                Button {
                    following = true
                    recenter(animated: true)
                } label: {
                    Label("Recenter", systemImage: "location.fill").font(Typeface.bold(13)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Palette.gold))
                }
                .padding(10)
                .accessibilityLabel("Recenter on the walker")
            }
        }
        .onAppear {
            shown = pos.flatMap { $0.count == 2 ? c($0) : nil }
            recenter(animated: false)
        }
        .onChange(of: pos) { _, new in move(to: new) }
    }

    private func move(to new: [Double]?) {
        guard let new, new.count == 2 else { return }
        let target = c(new)
        guard let old = shown else {
            shown = target
            recenter(animated: false)
            return
        }
        let d = CLLocation(latitude: old.latitude, longitude: old.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        let now = Date()
        if let t = lastArrival {
            let g = min(max(now.timeIntervalSince(t), interval * 0.8), interval * 2.5)
            gap = gap.map { $0 * 0.7 + g * 0.3 } ?? g
        }
        lastArrival = now
        if d < 1.5 { return }  // GPS jitter: don't wiggle
        if d > 200 {  // a new walk or a reset: jump, don't fly across town
            shown = target
            if following && follow { recenter(animated: false) }
            return
        }
        withAnimation(.linear(duration: gap ?? interval)) {
            shown = target
            if following && follow { camera = .camera(cam(at: target)) }
        }
    }

    private func cam(at p: CLLocationCoordinate2D) -> MapCamera {
        // Keep whatever zoom and angle the person chose; only move the center.
        if let l = lastCam { return MapCamera(centerCoordinate: p, distance: l.distance, heading: l.heading, pitch: l.pitch) }
        return MapCamera(centerCoordinate: p, distance: 700, heading: 20, pitch: 55)
    }

    private func recenter(animated: Bool) {
        guard let p = shown ?? route?.first.map(c) else { return }
        let next = MapCameraPosition.camera(cam(at: p))
        if animated { withAnimation(.easeInOut(duration: 0.6)) { camera = next } } else { camera = next }
    }
}

/// The walker's marker: the buddy in a colored disc with a soft pulse. Its own state, so the pulse
/// animation never mixes with the map's movement animations.
private struct WalkerDot: View {
    let tint: Color
    let form: String
    let species: String?
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.28)).frame(width: 38, height: 38)
                .scaleEffect(pulse ? 1.65 : 1).opacity(pulse ? 0.35 : 1)
            Circle().fill(.white).frame(width: 40, height: 40).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            Circle().fill(tint).frame(width: 34, height: 34)
            PetImage(species: species, form: form, size: 30)
        }
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
