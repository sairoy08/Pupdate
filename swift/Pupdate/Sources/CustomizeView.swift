import SwiftUI

/// Pick your pet and name it. Saved on the server, so your friends see it too.
struct CustomizeView: View {
    let onClose: (BuddyInfo?) -> Void
    @State private var buddy: BuddyInfo?
    @State private var name = ""
    @State private var species = "dog"
    @State private var saving = false
    @State private var error: String?
    @FocusState private var naming: Bool

    var body: some View {
        ZStack {
            Sky()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Your buddy").font(Typeface.display(34)).foregroundStyle(Palette.text)
                        Spacer()
                        Button { onClose(nil) } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(Palette.muted)
                                .frame(width: 40, height: 40).background(Circle().fill(.white.opacity(0.07)))
                        }
                        .accessibilityLabel("Close")
                    }
                    .padding(.top, 8)

                    // Live preview.
                    VStack(spacing: 4) {
                        BuddyView(form: buddy?.form ?? "sprout", species: species, mood: .happy, size: 230)
                            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: species)
                        Text(name.isEmpty ? "Name your buddy" : name).font(Typeface.display(28)).foregroundStyle(Palette.text)
                        Text("\(formName(buddy?.form ?? "sprout", species: species)) \(SPECIES.first { $0.id == species }?.name ?? "")")
                            .font(Typeface.semi(15)).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.card)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name").font(Typeface.displayBold(17)).foregroundStyle(Palette.text)
                        TextField("Melvin", text: $name)
                            .font(Typeface.semi(18)).foregroundStyle(Palette.text)
                            .focused($naming).submitLabel(.done)
                            .padding(.horizontal, 16).frame(minHeight: 52)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card2))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(naming ? Palette.gold : Palette.line, lineWidth: naming ? 1.5 : 1))
                            .onChange(of: name) { _, v in if v.count > 16 { name = String(v.prefix(16)) } }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pick a pet").font(Typeface.displayBold(17)).foregroundStyle(Palette.text)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            ForEach(SPECIES) { sp in
                                let on = sp.id == species
                                Button {
                                    Haptics.tap()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { species = sp.id }
                                } label: {
                                    VStack(spacing: 4) {
                                        PetImage(species: sp.id, form: "sprout", mood: on ? .happy : .calm, size: 46)
                                            .scaleEffect(on ? 1.12 : 1)
                                        Text(sp.name).font(Typeface.bold(12)).foregroundStyle(on ? Palette.gold : Palette.muted)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 84)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Palette.gold.opacity(0.14) : Palette.card))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(on ? Palette.gold : Palette.line, lineWidth: on ? 2 : 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(sp.name)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        Text(species == "dog"
                             ? "Your pup earns a bandana at 100 XP (Scout Pup) and a vest, tag and headlamp at 250 XP (Guardian Dog)."
                             : "Your \(SPECIES.first { $0.id == species }?.name.lowercased() ?? "pet") earns a star at 100 XP and a crown at 250 XP.")
                            .font(Typeface.body(13)).foregroundStyle(Palette.muted)
                    }

                    if let error { Banner(text: error, alert: true) }
                    GameButton(title: "Save", busy: saving) { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
        }
        .task {
            if let u = try? await API.shared.user("jordan") {
                buddy = u.buddy
                name = u.buddy.name
                species = u.buddy.species ?? "dog"
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let b = try await API.shared.customize("jordan", name: name.trimmingCharacters(in: .whitespaces), species: species)
            Haptics.success()
            onClose(b)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
