import SwiftUI

@main
struct PupdateApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @AppStorage("wb.role") private var role = ""
    /// The text size the app was last built with. Changing the setting rebuilds the whole tree (fonts are read
    /// when views are made), so it's applied when Settings closes, not while it's open.
    @State private var appliedScale = UserDefaults.standard.object(forKey: "wb.textScale") as? Double ?? 1.0
    var body: some View {
        Group {
            switch role {
            case "walker": WalkerView(onExit: { role = "" })
            case "friend": FriendView(onExit: { role = "" })
            default: RoleView(pick: { role = $0 })
            }
        }
        .id(appliedScale)
        .onReceive(NotificationCenter.default.publisher(for: .wbApplyTextScale)) { _ in
            let s = UserDefaults.standard.object(forKey: "wb.textScale") as? Double ?? 1.0
            if s != appliedScale { appliedScale = s }
        }
    }
}

extension Notification.Name {
    static let wbApplyTextScale = Notification.Name("wb.applyTextScale")
}

struct RoleView: View {
    let pick: (String) -> Void
    @State private var server = API.shared.base
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        ZStack {
            Sky()
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        HStack(alignment: .bottom, spacing: -18) {
                            BuddyView(form: "strider", species: "dog", mood: .happy, size: 170, pedestal: true)
                        }
                        Text("Pupdate").font(Typeface.display(44)).foregroundStyle(Palette.text)
                        Text("Your pup walks you home and keeps your friends updated. If you stop answering it, they find out.")
                            .font(Typeface.body(16)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .padding(.top, 18)

                    GameCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "Who's holding this phone?")
                            GameButton(title: "I'm walking home (Jordan)") { pick("walker") }
                            GameButton(title: "I'm the friend (Maya)", kind: .ghost) { pick("friend") }
                        }
                    }

                    GameCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(text: "Server", sub: "The tunnel address printed on the laptop.")
                            TextField("https://something.trycloudflare.com", text: $server)
                                .font(Typeface.body(15)).foregroundStyle(Palette.text)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .padding(.horizontal, 14).frame(minHeight: 50)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card2))
                            HStack(spacing: 12) {
                                GameButton(title: "Save and test", kind: .ghost, busy: checking) { Task { await test() } }
                                Text(status ?? "").font(Typeface.bold(15))
                                    .foregroundStyle(status == "Connected" ? Palette.ok : Palette.alert)
                                    .frame(width: 120, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await test(save: false) }
    }

    private func test(save: Bool = true) async {
        if save { API.shared.base = server }
        checking = true
        do { _ = try await API.shared.health(); status = "Connected" } catch { status = "Can't reach it" }
        checking = false
    }
}

/// Back button + optional trailing content.
struct TopBar<Trailing: View>: View {
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.07)))
                    .accessibilityLabel("Back")
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}
