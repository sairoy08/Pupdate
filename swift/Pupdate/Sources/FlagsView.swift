import MapKit
import SwiftUI

let FLAG_REASONS = ["Poorly lit", "Construction", "Felt unsafe", "Sketchy parking lot", "Other"]

func flagTint(_ status: String) -> Color {
    switch status { case "avoid": return Palette.alert; case "caution": return Palette.warn; default: return Palette.ok }
}

func flagTitle(_ status: String) -> String {
    switch status { case "avoid": return "Avoid"; case "caution": return "Caution"; default: return "OK" }
}

/// Flags your circle can see, refreshed every 15 s.
@MainActor
final class FlagStore: ObservableObject {
    let me: String
    @Published var flags: [FlagInfo] = []
    @Published var error: String?
    private var loop: Task<Void, Never>?

    init(me: String) { self.me = me }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    func load() async {
        if let f = try? await API.shared.flags(viewer: me), f != flags { flags = f }
    }

    func add(_ c: CLLocationCoordinate2D, reason: String, status: String, radius: Double, note: String) async {
        do {
            _ = try await API.shared.addFlag(by: me, lat: c.latitude, lng: c.longitude, reason: reason, status: status, radius: radius, note: note)
            error = nil
            Haptics.success()
        } catch { self.error = error.localizedDescription }
        await load()
    }

    func set(_ f: FlagInfo, _ status: String) async {
        do { _ = try await API.shared.setFlag(f.id, by: me, status: status); error = nil } catch { self.error = error.localizedDescription }
        await load()
    }

    func delete(_ f: FlagInfo) async {
        do { try await API.shared.deleteFlag(f.id, by: me); error = nil } catch { self.error = error.localizedDescription }
        await load()
    }
}

/// Map content for flags: a tinted circle with a flag pin. Use inside any Map { }.
struct FlagMarks: MapContent {
    let flags: [FlagInfo]
    var onTap: ((FlagInfo) -> Void)? = nil
    var body: some MapContent {
        ForEach(flags) { f in
            let c = CLLocationCoordinate2D(latitude: f.lat, longitude: f.lng)
            MapCircle(center: c, radius: f.radiusM)
                .foregroundStyle(flagTint(f.status).opacity(f.status == "ok" ? 0.12 : 0.25))
                .stroke(flagTint(f.status), lineWidth: 2)
            Annotation(f.reason, coordinate: c, anchor: .bottom) {
                Button { onTap?(f) } label: {
                    Image(systemName: f.status == "ok" ? "checkmark.circle.fill" : "flag.fill")
                        .font(.system(size: 14, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Circle().fill(flagTint(f.status)))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                }
                .accessibilityLabel("\(flagTitle(f.status)) flag: \(f.reason), by \(f.byName)")
            }
        }
    }
}

/// Bottom card to drop a new flag at a point.
struct NewFlagCard: View {
    let coordinate: CLLocationCoordinate2D
    let onSave: (String, String, Double, String) -> Void
    let onCancel: () -> Void
    @State private var reason = "Poorly lit"
    @State private var status = "avoid"
    @State private var radius = 60.0
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Flag this spot").font(Typeface.display(22)).foregroundStyle(Palette.text)
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Palette.muted) }
                    .accessibilityLabel("Cancel flag")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FLAG_REASONS, id: \.self) { r in
                        Button { reason = r } label: {
                            Text(r).font(Typeface.semi(13)).foregroundStyle(reason == r ? Palette.gold : Palette.muted)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(reason == r ? Palette.gold.opacity(0.14) : .clear))
                                .overlay(Capsule().strokeBorder(reason == r ? Palette.gold : Palette.line))
                        }
                        .accessibilityAddTraits(reason == r ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(["avoid", "caution"], id: \.self) { s in
                    Button { status = s } label: {
                        Label(flagTitle(s), systemImage: s == "avoid" ? "nosign" : "exclamationmark.triangle.fill")
                            .font(Typeface.bold(14)).foregroundStyle(status == s ? flagTint(s) : Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(RoundedRectangle(cornerRadius: 14).fill(status == s ? flagTint(s).opacity(0.14) : Palette.card2))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(status == s ? flagTint(s) : Palette.line))
                    }
                    .accessibilityAddTraits(status == s ? .isSelected : [])
                }
            }
            Text(status == "avoid" ? "Routes steer around it. Walking into it makes your buddy check in."
                                   : "Routes may pass. Your buddy warns you as you get close.")
                .font(Typeface.body(12.5)).foregroundStyle(Palette.muted)
            HStack {
                Text("Size").font(Typeface.semi(14)).foregroundStyle(Palette.text)
                Picker("Size", selection: $radius) {
                    Text("Small 30 m").tag(30.0); Text("Medium 60 m").tag(60.0); Text("Large 120 m").tag(120.0)
                }
                .pickerStyle(.segmented)
            }
            TextField("Note (optional)", text: $note)
                .font(Typeface.body(15)).foregroundStyle(Palette.text)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card2))
            GameButton(title: "Share with my circle") { onSave(reason, status, radius, note) }
            Text("Your circle sees it. It expires in 7 days.").font(Typeface.body(12)).foregroundStyle(Palette.muted)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card2))
    }
}

/// Bottom card for an existing flag: change status, or delete if it's yours.
struct FlagDetailCard: View {
    let flag: FlagInfo
    let me: String
    let onStatus: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flag.reason).font(Typeface.display(22)).foregroundStyle(Palette.text)
                    Text("Flagged by \(flag.by == me ? "you" : flag.byName) · \(ago(flag.updatedAt))")
                        .font(Typeface.body(13)).foregroundStyle(Palette.muted)
                    if !flag.note.isEmpty { Text(flag.note).font(Typeface.body(14)).foregroundStyle(Palette.text) }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Palette.muted) }
                    .accessibilityLabel("Close flag")
            }
            HStack(spacing: 8) {
                ForEach(["avoid", "caution", "ok"], id: \.self) { s in
                    Button { onStatus(s) } label: {
                        Text(flagTitle(s)).font(Typeface.bold(14)).foregroundStyle(flag.status == s ? flagTint(s) : Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(RoundedRectangle(cornerRadius: 14).fill(flag.status == s ? flagTint(s).opacity(0.14) : Palette.card2))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(flag.status == s ? flagTint(s) : Palette.line))
                    }
                    .accessibilityLabel("Mark \(flagTitle(s))")
                    .accessibilityAddTraits(flag.status == s ? .isSelected : [])
                }
            }
            if flag.by == me {
                Button(role: .destructive, action: onDelete) {
                    Text("Delete flag").font(Typeface.bold(14)).foregroundStyle(Palette.alert)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card2))
    }

    private func ago(_ t: Double) -> String {
        let s = Date().timeIntervalSince1970 - t
        if s < 120 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}

/// Full-screen map of every flag your circle shared. Long-press the map (or tap the button) to add one.
struct FlagsView: View {
    let me: String
    let onClose: () -> Void
    @StateObject private var store: FlagStore
    @State private var camera: MapCameraPosition = .camera(MapCamera(centerCoordinate: .init(latitude: 33.4178, longitude: -111.9318), distance: 2600, heading: 0, pitch: 0))
    @State private var center = CLLocationCoordinate2D(latitude: 33.4178, longitude: -111.9318)
    @State private var drop: CLLocationCoordinate2D?
    @State private var selected: FlagInfo?
    @AppStorage("wb.satellite") private var satellite = true

    init(me: String, onClose: @escaping () -> Void) {
        self.me = me
        self.onClose = onClose
        _store = StateObject(wrappedValue: FlagStore(me: me))
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $camera) {
                    FlagMarks(flags: store.flags) { f in selected = f; drop = nil }
                    if let drop {
                        Annotation("New flag", coordinate: drop, anchor: .bottom) {
                            Image(systemName: "mappin.circle.fill").font(.system(size: 34)).foregroundStyle(Palette.gold)
                                .shadow(color: .black.opacity(0.4), radius: 4)
                        }
                    }
                }
                .mapStyle(satellite ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll) : .standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControlVisibility(.hidden)
                .onMapCameraChange { ctx in center = ctx.region.center }
                .gesture(LongPressGesture(minimumDuration: 0.45).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        if case .second(true, let drag?) = value, let c = proxy.convert(drag.location, from: .local) {
                            Haptics.tap()
                            selected = nil
                            drop = c
                        }
                    })
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .heavy)).foregroundStyle(Palette.text)
                            .frame(width: 46, height: 46).background(Circle().fill(Palette.card))
                    }
                    .accessibilityLabel("Back")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Flagged spots").font(Typeface.display(22)).foregroundStyle(Palette.text)
                        Text("\(store.flags.filter { $0.status != "ok" }.count) active · long-press the map to add").font(Typeface.body(12.5)).foregroundStyle(Palette.muted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
                    Spacer()
                }
                if let e = store.error { Banner(text: e, alert: true) }
            }
            .padding(.horizontal, 16).padding(.top, 8)

            VStack {
                Spacer()
                if let d = drop {
                    NewFlagCard(coordinate: d, onSave: { reason, status, radius, note in
                        Task { await store.add(d, reason: reason, status: status, radius: radius, note: note); drop = nil }
                    }, onCancel: { drop = nil })
                } else if let f = selected, let live = store.flags.first(where: { $0.id == f.id }) {
                    FlagDetailCard(flag: live, me: me, onStatus: { s in Task { await store.set(live, s) } },
                                   onDelete: { Task { await store.delete(live); selected = nil } }, onClose: { selected = nil })
                } else {
                    VStack(spacing: 10) {
                        FlagLegend()
                        GameButton(title: "Flag the map center") { drop = center }
                            .accessibilityHint("Drops a flag where the map is centered. You can also long-press the map.")
                    }
                }
            }
            .padding(16)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: drop?.latitude)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selected?.id)
        }
        .background(Palette.bg)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }
}

struct FlagLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(["avoid", "caution", "ok"], id: \.self) { s in
                HStack(spacing: 6) {
                    Circle().fill(flagTint(s)).frame(width: 10, height: 10)
                    Text(s == "avoid" ? "Avoid: routes go around" : s == "caution" ? "Caution" : "Cleared")
                        .font(Typeface.semi(12)).foregroundStyle(Palette.text)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Capsule().fill(Palette.card))
    }
}
