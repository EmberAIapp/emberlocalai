import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showingCreate = false
    @State private var settingsModel: PersonalModelInfo?
    @State private var deleteTarget: PersonalModelInfo?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                Color.emberBg.ignoresSafeArea()
                if state.selected != nil {
                    ModelView()
                } else {
                    WelcomeView(showingCreate: $showingCreate)
                }
                if state.booting {
                    VStack(spacing: 16) {
                        EmberOrb(size: 60, active: true).frame(height: 130)
                        Text("Ember se réveille…").foregroundStyle(.emberMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.emberBg.opacity(0.96))
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.ember2)
        .sheet(isPresented: $showingCreate) { CreateSheet() }
        .sheet(item: $settingsModel) { SettingsSheet(model: $0) }
        .alert("Oups", isPresented: .constant(state.errorText != nil)) {
            Button("OK") { state.errorText = nil }
        } message: { Text(state.errorText ?? "") }
        .alert("Supprimer cette IA ?", isPresented: .constant(deleteTarget != nil)) {
            Button("Annuler", role: .cancel) { deleteTarget = nil }
            Button("Supprimer", role: .destructive) {
                if let t = deleteTarget { Task { await state.deleteModel(t.name) } }
                deleteTarget = nil
            }
        } message: {
            Text("« \(deleteTarget?.name ?? "") » et tout ce qu'elle a appris seront effacés. Irréversible.")
        }
    }

    private var sidebar: some View {
        ZStack {
            Color.emberBg2.ignoresSafeArea()
            List(selection: $state.selected) {
                Section {
                    ForEach(state.models) { m in
                        HStack(spacing: 10) {
                            EmberOrb(size: 12, active: state.isBusy && state.selected?.name == m.name)
                                .frame(width: 14, height: 14)
                            Text(m.name).foregroundStyle(.emberInk)
                            Spacer()
                            Text("v\(m.version)").font(.caption).foregroundStyle(.emberFaint)
                        }
                        .tag(m)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button { settingsModel = m } label: { Label("Réglages…", systemImage: "slider.horizontal.3") }
                            Button(role: .destructive) { deleteTarget = m } label: { Label("Supprimer", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Mes IA").foregroundStyle(.emberMuted)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Ember")
        .toolbar {
            ToolbarItem {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .help("Créer une nouvelle IA")
            }
        }
        .frame(minWidth: 230)
    }
}

struct WelcomeView: View {
    @Binding var showingCreate: Bool
    var body: some View {
        VStack(spacing: 26) {
            EmberOrb(size: 96)
                .frame(height: 200)
            Text("Votre IA personnelle, sur votre Mac")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(.emberInk)
                .multilineTextAlignment(.center)
            Text("Elle apprend de vos données. Rien ne quitte votre machine.")
                .foregroundStyle(.emberMuted)
            Button { showingCreate = true } label: {
                Text("Créer mon IA")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(hexv: 0x1a0d05))
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .background(LinearGradient(colors: [.ember1, .ember2], startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                    .shadow(color: .ember2.opacity(0.5), radius: 20, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(40)
    }
}

struct SettingsSheet: View {
    let model: PersonalModelInfo
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var persona = ""
    @State private var maxTokens: Double = 64

    var body: some View {
        ZStack {
            Color.emberBg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    EmberOrb(size: 24).frame(width: 28, height: 28)
                    Text("Réglages — \(model.name)")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(.emberInk)
                }
                Text("Modèle de base : \(model.base)")
                    .font(.caption).foregroundStyle(.emberMuted)

                Text("Comment elle doit se comporter").font(.subheadline).foregroundStyle(.emberInk)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.emberBg2)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ember2.opacity(0.25)))
                    if persona.isEmpty {
                        Text("Ex : Réponds toujours en français, de façon courte et chaleureuse.")
                            .foregroundStyle(.emberFaint).padding(10)
                    }
                    TextEditor(text: $persona)
                        .scrollContentBackground(.hidden)
                        .padding(6).foregroundStyle(.emberInk)
                }
                .frame(height: 90)

                Text("Longueur des réponses : \(Int(maxTokens)) mots").font(.subheadline).foregroundStyle(.emberInk)
                Slider(value: $maxTokens, in: 16...256, step: 8).tint(.ember2)

                Divider().overlay(Color.ember2.opacity(0.15))
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(.emberFaint)
                    VStack(alignment: .leading) {
                        Text("Mode plein-ordinateur (voix + agent)").foregroundStyle(.emberMuted)
                        Text("Bientôt").font(.caption2).foregroundStyle(.emberFaint)
                    }
                    Spacer()
                    Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                }

                HStack {
                    Spacer()
                    Button("Fermer") { dismiss() }.buttonStyle(.plain).foregroundStyle(.emberMuted)
                    Button {
                        Task { await state.saveSettings(model.name, persona: persona, maxTokens: Int(maxTokens)); dismiss() }
                    } label: {
                        Text("Enregistrer").foregroundStyle(Color(hexv: 0x1a0d05))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(LinearGradient(colors: [.ember1, .ember2], startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .frame(width: 460, height: 480)
        .task {
            let s = await state.loadSettings(model.name)
            persona = s.persona
            maxTokens = Double(max(16, s.maxTokens))
        }
    }
}

struct CreateSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var base = "smollm2-360m-instruct"

    private let bases = [
        ("smollm2-360m-instruct", "Équilibré (recommandé)"),
        ("smollm2-135m-instruct", "Léger et rapide"),
    ]

    var body: some View {
        ZStack {
            Color.emberBg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    EmberOrb(size: 26).frame(width: 30, height: 30)
                    Text("Créer mon IA").font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(.emberInk)
                }
                TextField("Nom (ex: mon-assistant)", text: $name)
                    .textFieldStyle(.plain)
                    .padding(11)
                    .background(Color.emberBg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ember2.opacity(0.25)))
                    .foregroundStyle(.emberInk)
                Text("Modèle de base").font(.caption).foregroundStyle(.emberMuted)
                Picker("", selection: $base) {
                    ForEach(bases, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                HStack {
                    Spacer()
                    Button("Annuler") { dismiss() }.buttonStyle(.plain).foregroundStyle(.emberMuted)
                    Button {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        Task { await state.create(name: n, base: base); dismiss() }
                    } label: {
                        Text("Créer").foregroundStyle(Color(hexv: 0x1a0d05))
                            .padding(.horizontal, 20).padding(.vertical, 9)
                            .background(LinearGradient(colors: [.ember1, .ember2], startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(26)
        }
        .frame(width: 400)
    }
}
